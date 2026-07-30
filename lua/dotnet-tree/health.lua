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

  local cwd = vim.fn.getcwd()
  local solutions = require("dotnet-tree.parser.solution").find(cwd)
  if #solutions > 0 then
    ok(("%d solution(s) found under %s"):format(#solutions, cwd))
    for _, sln in ipairs(solutions) do
      ok("  " .. sln)
    end
  else
    warn("no .sln/.slnx found under " .. cwd, {
      "Open Neovim at the repository root, or press `s` in the tree to pick one.",
    })
  end

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

return M
