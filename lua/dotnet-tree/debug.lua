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
--
-- Where the assembly *is* is asked of MSBuild rather than composed. See
-- M.get_property.

local csproj = require("dotnet-tree.parser.csproj")

local M = {}

-- netcoredbg speaks DAP over stdio with this argument and no other.
local ADAPTER_ARGS = { "--interpreter=vscode" }

-- What `dotnet build` produces with no -c flag. Kept as a constant rather than
-- a prompt: `d` is meant to be one keypress, and debugging a Release build with
-- optimisations on is not what anyone means by it.
M.configuration = "Debug"

--- Run a command, and hand its exit code and stdout+stderr lines to `cb`.
---
--- The one place this module starts a process, which is what makes the rest of
--- it testable: the specs replace this.
---@param cmd string[]
---@param cb fun(code: integer, lines: string[])
function M.query(cmd, cb)
  local lines = {}
  local function collect(_, data)
    if not data then
      return
    end
    for _, line in ipairs(data) do
      table.insert(lines, (line:gsub("\r$", "")))
    end
  end
  local ok, job = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = collect,
    on_stderr = collect,
    on_exit = function(_, code)
      cb(code, lines)
    end,
  })
  if not ok or job <= 0 then
    cb(-1, {})
  end
end

--- The single value in `dotnet msbuild -getProperty:<name>` output, or nil.
---
--- Three shapes, all measured rather than assumed:
---
---   a value    one line, the evaluated property
---   nothing    exit 0 and no output: the property is empty for this build.
---              `TargetPath` is empty on the outer build of a multi-targeted
---              project, because there is no single output then
---   an error   exit 1. An SDK older than 8 does not know the switch at all and
---              answers MSB1001 (verified on 6.0.420, where MSBuild exits 1);
---              so does a project that fails to evaluate
---
--- Anything that is not exactly one non-empty line reads as "no answer", and
--- the caller falls back rather than guessing at the output.
---@param code integer
---@param lines string[]
---@return string|nil value
function M.parse_property(code, lines)
  if code ~= 0 then
    return nil
  end
  local value = nil
  for _, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      if value ~= nil then
        return nil
      end
      value = trimmed
    end
  end
  return value
end

--- Ask MSBuild to evaluate one property of a project.
---
--- `bin/<Configuration>/<tfm>/<AssemblyName>.dll` is the *default* layout, not
--- the only one, and composing it was wrong on every repository that moves the
--- output (#31). A repository that sets `<ArtifactsPath>` -- or
--- `<UseArtifactsOutput>`, the .NET 8 opt-in -- puts every project under one
--- tree instead, and `<project>/bin` does not exist at all:
---
---   artifacts/bin/Api/debug/Api.dll              single target: no tfm segment
---   artifacts/bin/Multi/debug_net9.0/Multi.dll   multi target: configuration_tfm
---   artifacts/bin/Named/debug/Renamed.dll        directory is the *project*
---                                                name, file is the assembly name
---
--- Composing that path means reimplementing `ArtifactsPivots` (the lowercased
--- configuration, the `_tfm` segment that only the inner build of a
--- multi-targeted project gets, the `_rid` one), plus
--- `IncludeProjectNameInArtifactsPaths`, `ArtifactsProjectName` and
--- `ArtifactsBinOutputName` -- see Microsoft.NET.DefaultOutputPaths.targets --
--- and it would still leave `<OutputPath>`, `<BaseOutputPath>` and
--- `<AppendTargetFrameworkToOutputPath>` breaking the same path in the same
--- way. One process gives the exact answer for all of them, measured at 0.6s
--- against the 2s+ the build before it already costs.
---
--- `-getProperty` needs MSBuild 17.8, so an SDK older than 8 cannot answer;
--- that is why the composed path stays as the fallback rather than being
--- deleted. It costs nothing there, because the artifacts layout is itself
--- .NET 8 and later.
---
---@param project_path string
---@param name string the MSBuild property to evaluate
---@param tfm string|nil pass it for a multi-targeted project: the outer build
---   has no single TargetPath
---@param cb fun(value: string|nil)
function M.get_property(project_path, name, tfm, cb)
  local cmd = {
    "dotnet",
    "msbuild",
    project_path,
    "-getProperty:" .. name,
    "-p:Configuration=" .. M.configuration,
  }
  if tfm then
    table.insert(cmd, "-p:TargetFramework=" .. tfm)
  end
  -- No cwd is set, deliberately: dotnet-tree/build.lua does not set one either,
  -- so the query inherits the same working directory the build ran in and
  -- therefore resolves the same SDK through the same `global.json`. Pointing
  -- the query at the project directory instead would let it answer for one SDK
  -- while the build used another.
  M.query(cmd, function(code, lines)
    cb(M.parse_property(code, lines))
  end)
end

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

-- The two OutputType values that mean "there is a process to start". Library is
-- the one answer that means "do not launch this".
local RUNNABLE = { exe = true, winexe = true }

-- Blazor WebAssembly builds an Exe -- MSBuild says so -- but the assembly runs
-- in the browser's runtime, not as a process: `dotnet App.dll` on one fails in
-- the host with "the library 'libhostpolicy' required to execute the
-- application was not found", which tells the reader nothing. netcoredbg cannot
-- launch it either; debugging it is the browser's job.
local function is_blazor_wasm(sdk)
  return sdk ~= nil and sdk:lower():find("microsoft.net.sdk.blazorwebassembly", 1, true) ~= nil
end

--- Everything needed to launch a project, or a reason why it cannot be.
---
--- Resolution is deliberately separate from launching so the refusals are
--- testable without nvim-dap or a debugger present, and so `d` can refuse a
--- library *before* spending a build on it.
---
---@param project_path string path to a .csproj/.fsproj/.vbproj
---@return table|nil target { path, dir, assembly_name, is_test_project, frameworks, dll_for }
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

  -- What the project does not declare, its SDK decides: an ASP.NET Core project
  -- carries no `<OutputType>` and is still an application, and refusing it as a
  -- library was wrong about the only thing this function is for.
  local default_type = csproj.default_output_type(project.sdk)
  local kind = (output_type or default_type):lower()
  if not RUNNABLE[kind] then
    -- A test project that is not runnable is not the same story as a library,
    -- and saying "this is a library" sends the reader looking for a bug that is
    -- not there. Only xunit v3 test projects are executables; xunit v2, NUnit
    -- and MSTest ones build a library that the test host loads, so there is
    -- nothing for a debugger to launch and `t` is the answer.
    if project.is_test_project then
      return nil,
        ("%s is a test project that builds a library: nothing to launch, use `t` or neotest-dotnet"):format(name)
    end
    return nil,
      ("%s is a library (OutputType %s) and has no entry point"):format(
        name,
        -- Naming where an undeclared default came from saves the reader from
        -- hunting for an OutputType nobody wrote -- but only an SDK-style
        -- project has an SDK to name, and a project without one gets MSBuild's
        -- own default instead of an SDK it never imported.
        output_type
          or (
            project.sdk and ("%s, the %s default"):format(default_type, project.sdk) or (default_type .. ", by default")
          )
      )
  end

  if is_blazor_wasm(project.sdk) then
    return nil, ("%s is a Blazor WebAssembly app: it runs in the browser, and netcoredbg cannot launch it"):format(name)
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
    is_test_project = project.is_test_project,
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
--- TargetFramework from Directory.Build.props. The parser now reads the
--- nearest one (#23), and the file that one chains to with GetPathOfFileAbove
--- (#30), so those 15 arrive here with a framework; what is left is what
--- MSBuild alone can resolve, such as `$(DefaultTfm)`. Rather than
--- refuse, fall back to what is actually on disk under bin/<configuration>/ --
--- after a build that directory is the truth anyway.
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

--- Start the debugger on `program`.
---
--- The path is resolved by the caller rather than composed here: after #31
--- there is more than one place it can come from, and only one of them is a
--- guess.
---@param program string the assembly to launch
local function launch(dap, target, program, opts)
  if vim.fn.filereadable(program) == 0 then
    notify(
      ("built, but %s is not there; check the assembly name and target framework"):format(
        vim.fn.fnamemodify(program, ":~:.")
      ),
      vim.log.levels.ERROR
    )
    return
  end

  -- A test project is a runnable assembly and debugging it is legitimate --
  -- launching it runs the whole suite under the debugger, which is a real thing
  -- to want. It is not refused; it is named, so nobody presses `d` expecting an
  -- application and gets a test run.
  if target.is_test_project then
    notify(
      ("%s is a test project: debugging the whole test assembly. For a single test, see neotest-dotnet."):format(
        vim.fn.fnamemodify(target.path, ":t")
      ),
      vim.log.levels.INFO
    )
  end

  ensure_adapter(dap, opts.debugger)
  dap.run({
    type = "coreclr",
    name = ("dotnet-tree: %s%s"):format(
      vim.fn.fnamemodify(target.path, ":t:r"),
      target.is_test_project and " (tests)" or ""
    ),
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

  -- Ask MSBuild where the build put the assembly, and fall back to the default
  -- layout when it cannot answer -- an SDK older than 8 does not know
  -- `-getProperty`. The composed path is a guess about the layout; the answer
  -- is not, so the answer is preferred whenever there is one and it is on disk.
  local function launch_tfm(tfm)
    M.get_property(target.path, "TargetPath", tfm, function(from_msbuild)
      -- MSBuild's answer is preferred even when the file is not there: it is
      -- the path the build was configured to produce, so it is also the right
      -- path to name in the message if it is missing. The composed one is only
      -- for an SDK that cannot answer.
      launch(dap, target, from_msbuild or target.dll_for(tfm), opts)
    end)
  end

  local function after_build(tfm)
    if tfm then
      launch_tfm(tfm)
      return
    end
    -- Nothing was known before the build, so there is no framework to ask
    -- with. `TargetPath` still answers for a single-target project whatever
    -- its layout -- including one whose framework is written as
    -- `$(DefaultTfm)`, which the parser cannot expand -- and comes back empty
    -- for the outer build of a multi-targeted one, which is the case that
    -- needs a choice.
    M.get_property(target.path, "TargetPath", nil, function(from_msbuild)
      if from_msbuild then
        launch(dap, target, from_msbuild, opts)
        return
      end
      M.get_property(target.path, "TargetFrameworks", nil, function(declared)
        local built = {}
        if declared then
          for tf in declared:gmatch("[^;%s]+") do
            table.insert(built, tf)
          end
        end
        -- Last resort, and the only one available before SDK 8: read what the
        -- build left under bin/<configuration>/.
        if #built == 0 then
          built = M.frameworks(target)
        end
        if #built == 0 then
          notify(
            ("cannot tell what %s builds: no TargetFramework in the project, and MSBuild named no output"):format(
              vim.fn.fnamemodify(target.path, ":t")
            ),
            vim.log.levels.ERROR
          )
          return
        end
        choose(built, launch_tfm)
      end)
    end)
  end

  local function proceed(tfm)
    if opts.build == false then
      after_build(tfm)
      return
    end
    require("dotnet-tree.build").build(project_path, {
      -- The same Configuration the query below pins. Without it the build takes
      -- whatever project, props and SDK resolve to while
      -- `-getProperty:TargetPath` is asked about Debug: a `<Configuration>`
      -- written without a `Condition` in Directory.Build.props is enough to
      -- make them disagree, and then either the debugger is handed a path the
      -- build never wrote, or -- when the layout pins `<OutputPath>` and the two
      -- collide -- it silently loads the optimised assembly. `Optimize` follows
      -- `Configuration`, and netcoredbg says what that costs: "Using Just My
      -- Code with Release builds using compiler optimizations results in a
      -- degraded debugging experience (e.g. breakpoints will not be hit)".
      --
      -- It goes here rather than in dotnet-tree/build.lua because `b` has the
      -- other contract: a project that declares Release means it for the build.
      -- `d` is the key that means Debug (see M.configuration).
      args = { "-c", M.configuration },
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
