local M = {}

local function report_start(name)
  (vim.health.start or vim.health.report_start)(name)
end

local function ok(msg)
  (vim.health.ok or vim.health.report_ok)(msg)
end

local function warn(msg, advice)
  (vim.health.warn or vim.health.report_warn)(msg, advice)
end

local function err(msg, advice)
  (vim.health.error or vim.health.report_error)(msg, advice)
end

function M.check()
  report_start("dotnet-tree")

  if vim.fn.has("nvim-0.9") == 1 then
    ok("Neovim >= 0.9")
  else
    err("Neovim 0.9 or newer is required")
  end

  local has_neotree, neotree = pcall(require, "neo-tree")
  if has_neotree then
    ok("neo-tree.nvim is installed")
  else
    err("neo-tree.nvim not found", {
      "dotnet-tree is a neo-tree source, not a standalone tree.",
      "Install nvim-neo-tree/neo-tree.nvim.",
    })
    return
  end

  -- neo-tree stores the resolved source list on its merged config
  -- (neo-tree/setup/init.lua sets `M.config.sources = all_source_names`).
  local sources = type(neotree.config) == "table" and neotree.config.sources or nil
  if sources == nil then
    warn("neo-tree has not been set up yet, cannot verify the source list", {
      "neo-tree is probably lazy-loaded. Open it once (:Neotree) and re-run this check.",
    })
  elseif vim.tbl_contains(sources, "dotnet-tree") then
    ok('"dotnet-tree" is registered in neo-tree sources')
  else
    err('"dotnet-tree" is not in neo-tree\'s sources', {
      'Add it to your neo-tree opts: sources = { "filesystem", "dotnet-tree" }',
      "Installing the plugin alone is not enough.",
      "Sources currently configured: " .. table.concat(sources, ", "),
    })
  end

  if vim.fn.executable("dotnet") == 1 then
    local out = vim.fn.systemlist({ "dotnet", "--version" })[1]
    ok("dotnet CLI found (" .. tostring(out) .. ")")
  else
    warn("dotnet CLI not found on PATH", {
      "The tree still renders, but build/run/test/watch/add actions will fail.",
    })
  end

  -- Optional integrations. `d` is the only thing that needs them, and it says
  -- so on the keypress too; neither absence is an error for the tree itself.
  local debug_mod = require("dotnet-tree.debug")
  local has_dap = debug_mod.has_dap()
  local debugger = debug_mod.debugger_path()

  if has_dap and debugger then
    ok("debugging available (nvim-dap + " .. debugger .. ")")
  else
    local advice = {}
    if not has_dap then
      table.insert(advice, "Install mfussenegger/nvim-dap.")
    end
    if not debugger then
      table.insert(advice, "Install netcoredbg (`:MasonInstall netcoredbg`, or put it on PATH).")
    end
    table.insert(advice, "Everything else works without them; only `d` (debug project) needs both.")
    warn("debugging not available: " .. (has_dap and "netcoredbg not found" or "nvim-dap not installed"), advice)
  end

  local cwd = vim.fn.getcwd()
  local solutions = require("dotnet-tree.parser.solution").find(cwd)
  if #solutions > 0 then
    ok(("%d solution(s) found under %s"):format(#solutions, cwd))
    for _, sln in ipairs(solutions) do
      M.check_solution(sln)
    end
  else
    warn("no .sln/.slnx found under " .. cwd, {
      "Open Neovim at the repository root, or press `s` in the tree to pick one.",
    })
  end

  M.check_functions(solutions)

  local persisted = require("dotnet-tree.store").get(cwd)
  if persisted then
    if vim.fn.filereadable(persisted) == 1 then
      ok("remembered solution for this cwd: " .. persisted)
    else
      warn("remembered solution no longer exists: " .. persisted, {
        "Press `s` in the tree to select a different one.",
      })
    end
  end
end

--- One solution found: whether it can be read, and whether the projects it
--- lists are on disk. `r`, `t` and `w` start in a project's folder, so a
--- project that is gone cannot be run, and this is where to find out why.
---@param sln_path string
function M.check_solution(sln_path)
  local sln, parse_err = require("dotnet-tree.parser.solution").parse(sln_path)
  if not sln then
    warn("  " .. sln_path .. " could not be read: " .. tostring(parse_err), {
      "The tree cannot show it; open the file to check that it is a valid solution.",
    })
    return
  end
  ok("  " .. sln_path)
  for _, proj in ipairs(sln.projects) do
    if proj.kind ~= "folder" and proj.path and vim.fn.filereadable(proj.path) == 0 then
      warn("    listed but not on disk: " .. proj.path, {
        "The solution still lists this project; `r`, `t` and `w` cannot run it.",
      })
    end
  end
end

-- The function apps of `solutions`, by project path. A solution that cannot
-- be read was reported by check_solution.
local function function_apps(solutions)
  local functions = require("dotnet-tree.functions")
  local apps = {}
  for _, sln_path in ipairs(solutions) do
    local sln = require("dotnet-tree.parser.solution").parse(sln_path)
    for _, proj in ipairs(sln and sln.projects or {}) do
      if proj.kind ~= "folder" and proj.path and not apps[proj.path] then
        local app = functions.detect(proj.path)
        if app then
          apps[proj.path] = app
        end
      end
    end
  end
  return apps
end

--- What `r` and `w` need for the Azure Functions apps of `solutions` (#57): `func`,
--- and Azurite for an app that keeps its storage there. Says nothing when no
--- solution has a function app.
---@param solutions string[]
function M.check_functions(solutions)
  local apps = function_apps(solutions)
  if next(apps) == nil then
    return
  end
  local functions = require("dotnet-tree.functions")
  report_start("dotnet-tree: Azure Functions")

  if vim.fn.executable("func") == 1 then
    ok("Azure Functions Core Tools found (func)")
  else
    warn("func not found on PATH", {
      "`r` on a function app needs Azure Functions Core Tools.",
      "Install it: https://learn.microsoft.com/azure/azure-functions/functions-run-local",
    })
  end

  local needs_azurite = false
  for _, app in pairs(apps) do
    needs_azurite = needs_azurite or functions.uses_azurite(app.dir)
  end
  if not needs_azurite then
    return
  end

  local listening, problem
  functions.azurite_listening(function(result, why)
    listening, problem = result, why
  end)
  vim.wait(functions.connect_timeout_ms + 500, function()
    return listening ~= nil
  end, 20)
  local where = ("%s:%d"):format(functions.azurite_host, functions.azurite_port)
  if problem then
    warn("could not check whether Azurite is listening on " .. where .. ": " .. problem)
  elseif listening then
    ok("Azurite is listening on " .. where)
  elseif vim.fn.executable("azurite") == 1 then
    warn("Azurite is installed but not listening on " .. where, {
      "A function app here uses UseDevelopmentStorage=true. Start it with `azurite`.",
    })
  else
    warn("Azurite not found on PATH and nothing is listening on " .. where, {
      "A function app here uses UseDevelopmentStorage=true.",
      "Install it with `npm install -g azurite`, or run it in Docker or from VS Code.",
    })
  end
end

return M
