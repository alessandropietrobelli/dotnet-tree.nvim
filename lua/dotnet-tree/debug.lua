-- `d` on a project: build it, then start netcoredbg on what it built.
--
-- The debugger is the usual reason to leave Neovim for Rider, and the gesture
-- this plugin is built around is "cursor on a project, press a key". So the
-- target is the project under the cursor, not a prompt asking which one.
--
-- Both dependencies are optional: nvim-dap and netcoredbg are checked before
-- anything else happens, and their absence is a message plus a `:checkhealth`
-- entry, never an error raised inside the tree.
--
-- What this deliberately does not do: attach to a running process, read
-- launchSettings.json, or debug a single test. The first two are separate
-- features; the third belongs to neotest-dotnet.

local csproj = require("dotnet-tree.parser.csproj")

local M = {}

-- netcoredbg speaks DAP over stdio with this argument and no other.
local ADAPTER_ARGS = { "--interpreter=vscode" }

-- What `dotnet build` produces with no -c flag. Kept as a constant rather than
-- a prompt: `d` is meant to be one keypress, and debugging a Release build with
-- optimisations on is not what anyone means by it.
M.configuration = "Debug"

--- Path to the netcoredbg executable, or nil.
---
--- PATH first; then mason's bin directory, which is where it usually is and
--- which is not on PATH unless mason.nvim has been loaded.
---@return string|nil
function M.debugger_path()
  local on_path = vim.fn.exepath("netcoredbg")
  if on_path ~= "" then
    return on_path
  end
  local mason = vim.fs.normalize(vim.fn.stdpath("data") .. "/mason/bin/netcoredbg")
  if vim.fn.executable(mason) == 1 then
    return mason
  end
  return nil
end

---@return boolean has_dap
---@return table|nil dap the module, when present
function M.has_dap()
  local ok, dap = pcall(require, "dap")
  if not ok then
    return false, nil
  end
  return true, dap
end

-- An OutputType we cannot evaluate is not a licence to guess. `$(Something)`
-- comes out of the parser verbatim by design, and launching on the assumption
-- that it means "Exe" produces exactly the opaque runtime error this feature
-- exists to avoid.
local function is_unevaluated(value)
  return value ~= nil and value:find("$(", 1, true) ~= nil
end

-- MSBuild's default when a project says nothing is Library, and Library is the
-- one answer that means "do not launch this".
local RUNNABLE = { exe = true, winexe = true }

--- Everything needed to launch a project, or a reason why it cannot be.
---
--- Resolution is deliberately separate from launching so the refusals are
--- testable without nvim-dap or a debugger present, and so `d` can refuse a
--- library *before* spending a build on it.
---
---@param project_path string path to a .csproj/.fsproj/.vbproj
---@return table|nil target { path, dir, assembly_name, frameworks, dll_for }
---@return string|nil reason why the project cannot be launched
function M.resolve(project_path)
  local project = csproj.parse(project_path)
  if not project then
    return nil, ("cannot read %s"):format(vim.fn.fnamemodify(project_path, ":t"))
  end

  local name = vim.fn.fnamemodify(project_path, ":t")
  local output_type = project.output_type

  if is_unevaluated(output_type) then
    return nil,
      ("%s declares OutputType as %s, which only MSBuild can resolve; not launching on a guess"):format(
        name,
        output_type
      )
  end

  local kind = (output_type or "Library"):lower()
  if not RUNNABLE[kind] then
    return nil,
      ("%s is a library (OutputType %s) and has no entry point"):format(name, output_type or "Library, by default")
  end

  local assembly_name = project.assembly_name
  if is_unevaluated(assembly_name) then
    return nil,
      ("%s declares AssemblyName as %s, which only MSBuild can resolve; no output path can be built"):format(
        name,
        assembly_name
      )
  end
  -- MSBuild's default: the project file's own name.
  assembly_name = assembly_name or vim.fn.fnamemodify(project_path, ":t:r")

  local dir = project.dir
  return {
    path = project_path,
    dir = dir,
    assembly_name = assembly_name,
    frameworks = vim.deepcopy(project.target_frameworks),
    dll_for = function(tfm)
      return ("%s/bin/%s/%s/%s.dll"):format(dir, M.configuration, tfm, assembly_name)
    end,
  }
end

--- Target frameworks to choose from, declared ones first.
---
--- A project that declares nothing is not unusual: 15 of the 42 .csproj files
--- in the jellyfin checkout this was measured against inherit their
--- TargetFramework from Directory.Build.props, which this parser does not
--- follow. Rather than refuse, fall back to what is actually on disk under
--- bin/<configuration>/ -- after a build that directory is the truth anyway.
---@param target table from M.resolve
---@return string[] frameworks
function M.frameworks(target)
  if #target.frameworks > 0 then
    return target.frameworks
  end

  local found = {}
  local bin = ("%s/bin/%s"):format(target.dir, M.configuration)
  for name, kind in vim.fs.dir(bin) do
    if kind == "directory" and vim.fn.filereadable(("%s/%s/%s.dll"):format(bin, name, target.assembly_name)) == 1 then
      table.insert(found, name)
    end
  end
  table.sort(found)
  return found
end

local function notify(message, level)
  vim.notify("[dotnet-tree] " .. message, level or vim.log.levels.WARN)
end

--- Register `coreclr` with nvim-dap unless the user already configured it.
---
--- Their configuration wins: someone who has set up an adapter (a different
--- netcoredbg build, a wrapper, vsdbg) means it.
---@param dap table
---@param debugger string path to netcoredbg
local function ensure_adapter(dap, debugger)
  if dap.adapters.coreclr then
    return
  end
  dap.adapters.coreclr = {
    type = "executable",
    command = debugger,
    args = ADAPTER_ARGS,
  }
end

local function launch(dap, target, tfm, opts)
  local program = target.dll_for(tfm)
  if vim.fn.filereadable(program) == 0 then
    notify(
      ("built, but %s is not there; check the assembly name and target framework"):format(
        vim.fn.fnamemodify(program, ":~:.")
      ),
      vim.log.levels.ERROR
    )
    return
  end

  ensure_adapter(dap, opts.debugger)
  dap.run({
    type = "coreclr",
    name = ("dotnet-tree: %s"):format(vim.fn.fnamemodify(target.path, ":t:r")),
    request = "launch",
    program = program,
    cwd = target.dir,
    -- netcoredbg writes the debuggee's stdout into the dap-repl buffer; without
    -- this a Console.WriteLine goes nowhere the user can see.
    console = "integratedTerminal",
    stopAtEntry = false,
  })
  if opts.on_launch then
    opts.on_launch(program)
  end
end

--- Build the project, then launch the debugger on what it built.
---
--- Building first is not politeness: without it the debugger attaches to
--- whatever the last build left behind, which is the worst possible failure --
--- breakpoints in code that is not the code running. A failed build stops the
--- launch and leaves the quickfix list on screen (see dotnet-tree/build.lua),
--- so what the user sees is the compiler error, not an error from the debugger.
---
---@param project_path string
---@param opts table|nil
---   build      boolean, default true: build before launching
---   on_launch  fun(program) called with the dll actually launched
function M.debug(project_path, opts)
  opts = opts or {}

  local has_dap, dap = M.has_dap()
  if not has_dap then
    notify("nvim-dap is not installed; `d` needs it. See :checkhealth dotnet-tree")
    return
  end

  local debugger = M.debugger_path()
  if not debugger then
    notify("netcoredbg not found on PATH or in mason. See :checkhealth dotnet-tree")
    return
  end
  opts.debugger = debugger

  local target, reason = M.resolve(project_path)
  if not target then
    notify(reason)
    return
  end

  -- One framework: use it. Several: ask, because bin/Debug then holds several
  -- different assemblies and none of them is the obvious one.
  local function choose(frameworks, fn)
    if #frameworks == 1 then
      fn(frameworks[1])
      return
    end
    vim.ui.select(frameworks, { prompt = "Debug which target framework?" }, function(choice)
      if choice then
        fn(choice)
      end
    end)
  end

  local function launch_tfm(tfm)
    launch(dap, target, tfm, opts)
  end

  local function after_build(tfm)
    if tfm then
      launch_tfm(tfm)
      return
    end
    -- Nothing was known before the build. bin/ now says what the project file
    -- did not.
    local built = M.frameworks(target)
    if #built == 0 then
      notify(
        ("cannot tell what %s builds: no TargetFramework in the project, nothing under bin/%s"):format(
          vim.fn.fnamemodify(target.path, ":t"),
          M.configuration
        ),
        vim.log.levels.ERROR
      )
      return
    end
    choose(built, launch_tfm)
  end

  local function proceed(tfm)
    if opts.build == false then
      after_build(tfm)
      return
    end
    require("dotnet-tree.build").build(project_path, {
      on_complete = function(result)
        if result.code ~= 0 then
          -- The quickfix list is already open with the compiler errors in it.
          return
        end
        after_build(tfm)
      end,
    })
  end

  -- A project that has never been built and declares nothing gets `nil` here:
  -- build first, then ask bin/ what came out.
  local declared = M.frameworks(target)
  if #declared == 0 then
    proceed(nil)
  else
    choose(declared, proceed)
  end
end

return M
