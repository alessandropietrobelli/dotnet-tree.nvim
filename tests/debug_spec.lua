-- Tests for `d` -- build the project under the cursor, then debug what it
-- built.
--
-- The failure this guards against is not an exception: it is launching the
-- wrong thing quietly. A library has no entry point, a stale dll runs code that
-- is not the code on screen, and an MSBuild property we cannot evaluate is not
-- a name we can build a path from. Each of those has to end in a message, and
-- none of them may end in a debug session.
--
-- nvim-dap and netcoredbg are not installed in CI, so the launch path is
-- exercised with a stub dap module: what matters is *whether* and *with what*
-- dap.run is called, which is exactly what a stub can answer.
--
-- Run with plenary:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures"

local csproj = require("dotnet-tree.parser.csproj")
local dbg = require("dotnet-tree.debug")

-- Collects vim.notify for the duration of fn, and restores it afterwards even
-- if fn throws.
local function capture_notifications(fn)
  local messages = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    table.insert(messages, { message = msg, level = level })
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err)
  end
  return messages
end

local function joined(messages)
  local parts = {}
  for _, entry in ipairs(messages) do
    table.insert(parts, entry.message)
  end
  return table.concat(parts, "\n")
end

-- Replaces the modules M.debug reaches for. Returns a table recording what the
-- stub dap was asked to run.
local function with_stubs(opts, fn)
  local recorded = { runs = {} }

  local previous_dap = package.loaded["dap"]
  local previous_build = package.loaded["dotnet-tree.build"]
  local previous_path = dbg.debugger_path

  package.loaded["dap"] = {
    adapters = {},
    run = function(config)
      table.insert(recorded.runs, config)
    end,
  }
  package.loaded["dotnet-tree.build"] = {
    build = function(path, build_opts)
      recorded.built = path
      build_opts.on_complete({ action = "build", path = path, code = opts.build_code or 0, items = {}, output = {} })
    end,
  }
  dbg.debugger_path = function()
    return opts.debugger or "/usr/bin/true"
  end

  local ok, err = pcall(fn, recorded)

  package.loaded["dap"] = previous_dap
  package.loaded["dotnet-tree.build"] = previous_build
  dbg.debugger_path = previous_path

  if not ok then
    error(err)
  end
  return recorded
end

-- A project directory on disk with a pre-built assembly under bin/, which is
-- what the launcher checks before handing a path to the debugger.
local function scratch_project(name, tfms, opts)
  opts = opts or {}
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local project = root .. "/" .. name .. ".csproj"
  local declared = ""
  if opts.declare ~= false and tfms and #tfms > 0 then
    declared = ("    <TargetFrameworks>%s</TargetFrameworks>\n"):format(table.concat(tfms, ";"))
  end
  local items = ""
  if opts.test_project then
    items = "  <ItemGroup>\n"
      .. '    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />\n'
      .. "  </ItemGroup>\n"
  end
  local handle = assert(io.open(project, "w"))
  handle:write(([[
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
%s  </PropertyGroup>
%s</Project>
]]):format(declared, items))
  handle:close()

  for _, tfm in ipairs(tfms or {}) do
    local out = ("%s/bin/Debug/%s"):format(root, tfm)
    vim.fn.mkdir(out, "p")
    local dll = assert(io.open(("%s/%s.dll"):format(out, opts.assembly or name), "w"))
    dll:write("not really an assembly")
    dll:close()
  end

  return root, project
end

describe("debug.resolve", function()
  before_each(function()
    csproj.invalidate()
  end)

  it("refuses a project that produces a library", function()
    -- MultiTarget.csproj declares no OutputType at all, which in MSBuild means
    -- Library. Attaching a debugger to it fails inside the runtime with an
    -- error that says nothing about the real problem.
    local target, reason = dbg.resolve(FIXTURES .. "/MultiTarget.csproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("library", 1, true), reason)
    assert.is_truthy(reason:find("MultiTarget.csproj", 1, true), reason)
  end)

  -- Only xunit v3 test projects are executables. `dotnet new xunit` on SDK
  -- 10.0.302 still produces xunit v2, which builds a library the test host
  -- loads -- so `d` genuinely cannot launch it. Saying "this is a library"
  -- would be true and useless: it sends the reader looking for a missing
  -- OutputType instead of to `t`.
  it("tells a test project that builds a library apart from a plain library", function()
    local target, reason = dbg.resolve(FIXTURES .. "/TestProjectLibrary.csproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("test project", 1, true), reason)
    assert.is_truthy(reason:find("`t`", 1, true), reason)
  end)

  it("refuses an OutputType it cannot evaluate rather than assuming Exe", function()
    local target, reason = dbg.resolve(FIXTURES .. "/Unevaluated.csproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("$(DefaultOutputType)", 1, true), reason)
    -- Not "this is a library": we do not know what it is, and saying the wrong
    -- reason sends the reader to change the wrong line.
    assert.is_nil(reason:find("library", 1, true), reason)
    assert.is_truthy(reason:find("only MSBuild can resolve", 1, true), reason)
  end)

  it("refuses an AssemblyName it cannot evaluate rather than guessing the file name", function()
    local target, reason = dbg.resolve(FIXTURES .. "/UnevaluatedName.csproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("$(ToolName)", 1, true), reason)
    assert.is_truthy(reason:find("only MSBuild can resolve", 1, true), reason)
  end)

  it("uses the declared AssemblyName for the output path, not the file name", function()
    local target = assert(dbg.resolve(FIXTURES .. "/Executable.csproj"))
    assert.are.equal("dotnet-tool-probe", target.assembly_name)
    assert.are.equal(FIXTURES .. "/bin/Debug/net9.0/dotnet-tool-probe.dll", target.dll_for("net9.0"))
  end)

  it("falls back to the project file name when no AssemblyName is declared", function()
    local target = assert(dbg.resolve(FIXTURES .. "/PlainExe.csproj"))
    assert.are.equal("PlainExe", target.assembly_name)
    assert.are.equal(FIXTURES .. "/bin/Debug/net9.0/PlainExe.dll", target.dll_for("net9.0"))
  end)

  it("returns every declared target framework", function()
    local target = assert(dbg.resolve(FIXTURES .. "/MultiTargetExe.csproj"))
    assert.are.same({ "net8.0", "net9.0" }, dbg.frameworks(target))
  end)
end)

describe("debug.frameworks", function()
  before_each(function()
    csproj.invalidate()
  end)

  -- 15 of the 42 .csproj files in a jellyfin checkout declare no
  -- TargetFramework: it comes from Directory.Build.props, which this parser
  -- does not follow. Refusing them would refuse a third of a real solution.
  it("discovers the framework from bin/ when the project file declares none", function()
    local root, project = scratch_project("Discovered", { "net9.0" }, { declare = false })
    local target = assert(dbg.resolve(project))
    assert.are.same({}, target.frameworks)
    assert.are.same({ "net9.0" }, dbg.frameworks(target))
    vim.fn.delete(root, "rf")
  end)

  it("returns nothing when the project declares none and has never been built", function()
    local root, project = scratch_project("NeverBuilt", {})
    local target = assert(dbg.resolve(project))
    assert.are.same({}, dbg.frameworks(target))
    vim.fn.delete(root, "rf")
  end)
end)

describe("debug.debug", function()
  before_each(function()
    csproj.invalidate()
  end)

  it("says so and launches nothing when nvim-dap is missing", function()
    local previous = package.loaded["dap"]
    package.loaded["dap"] = nil
    package.preload["dap"] = function()
      error("module 'dap' not found")
    end

    local messages = capture_notifications(function()
      dbg.debug(FIXTURES .. "/PlainExe.csproj")
    end)

    package.preload["dap"] = nil
    package.loaded["dap"] = previous

    assert.is_truthy(joined(messages):find("nvim%-dap"), joined(messages))
  end)

  it("refuses a library without building it", function()
    local messages
    local recorded = with_stubs({}, function()
      messages = capture_notifications(function()
        dbg.debug(FIXTURES .. "/MultiTarget.csproj")
      end)
    end)
    assert.are.equal(0, #recorded.runs)
    assert.is_nil(recorded.built)
    assert.is_truthy(joined(messages):find("library", 1, true), joined(messages))
  end)

  -- The reason #18 waited for #17. A launch that does not build first attaches
  -- to whatever the previous build left behind; a launch that ignores a failed
  -- build starts the debugger on a stale assembly and the user debugs code that
  -- is not the code on screen.
  it("does not launch when the build fails", function()
    local root, project = scratch_project("Failing", { "net9.0" })
    local recorded = with_stubs({ build_code = 1 }, function()
      dbg.debug(project)
    end)
    assert.are.equal(project, recorded.built)
    assert.are.equal(0, #recorded.runs)
    vim.fn.delete(root, "rf")
  end)

  it("builds first, then launches the assembly the resolver named", function()
    local root, project = scratch_project("Launchable", { "net9.0" })
    local recorded = with_stubs({}, function()
      dbg.debug(project)
    end)

    assert.are.equal(project, recorded.built)
    assert.are.equal(1, #recorded.runs)
    local config = recorded.runs[1]
    assert.are.equal("coreclr", config.type)
    assert.are.equal("launch", config.request)
    assert.are.equal(root .. "/bin/Debug/net9.0/Launchable.dll", config.program)
    assert.are.equal(root, config.cwd)
    vim.fn.delete(root, "rf")
  end)

  it("registers the adapter with the netcoredbg it found", function()
    local root, project = scratch_project("Adapter", { "net9.0" })
    with_stubs({ debugger = "/opt/netcoredbg/netcoredbg" }, function()
      dbg.debug(project)
      local adapter = package.loaded["dap"].adapters.coreclr
      assert.is_not_nil(adapter)
      assert.are.equal("/opt/netcoredbg/netcoredbg", adapter.command)
      assert.are.same({ "--interpreter=vscode" }, adapter.args)
    end)
    vim.fn.delete(root, "rf")
  end)

  -- Someone who has configured a coreclr adapter -- a different netcoredbg, a
  -- wrapper, vsdbg -- means it. Overwriting it would break a working setup to
  -- install our guess.
  it("leaves an adapter the user already configured alone", function()
    local root, project = scratch_project("Existing", { "net9.0" })
    with_stubs({}, function()
      package.loaded["dap"].adapters.coreclr = { type = "executable", command = "/custom/dbg" }
      dbg.debug(project)
      assert.are.equal("/custom/dbg", package.loaded["dap"].adapters.coreclr.command)
    end)
    vim.fn.delete(root, "rf")
  end)

  -- #24. A test project is a runnable assembly -- an xunit v3 one declares
  -- OutputType Exe -- so debugging it is legitimate and is not refused. What it
  -- must not do is present it as an application: pressing `d` and getting a
  -- whole test suite under the debugger, with no word about it, is a surprise.
  it("launches a test project, and says that is what it is", function()
    local root, project = scratch_project("Suite", { "net9.0" }, { test_project = true })

    local messages
    local recorded = with_stubs({}, function()
      messages = capture_notifications(function()
        dbg.debug(project)
      end)
    end)

    assert.are.equal(1, #recorded.runs)
    assert.are.equal(root .. "/bin/Debug/net9.0/Suite.dll", recorded.runs[1].program)
    -- Named in the session too, so the dap UI does not call it an application.
    assert.are.equal("dotnet-tree: Suite (tests)", recorded.runs[1].name)
    assert.is_truthy(joined(messages):find("is a test project", 1, true), joined(messages))
    assert.is_truthy(joined(messages):find("neotest-dotnet", 1, true), joined(messages))
    vim.fn.delete(root, "rf")
  end)

  it("says nothing about tests for an ordinary application", function()
    local root, project = scratch_project("PlainApp", { "net9.0" })

    local messages
    local recorded = with_stubs({}, function()
      messages = capture_notifications(function()
        dbg.debug(project)
      end)
    end)

    assert.are.equal(1, #recorded.runs)
    assert.are.equal("dotnet-tree: PlainApp", recorded.runs[1].name)
    assert.is_nil(joined(messages):find("test project", 1, true), joined(messages))
    vim.fn.delete(root, "rf")
  end)

  it("does not hand the debugger a path that is not there", function()
    local root, project = scratch_project("Missing", { "net9.0" })
    vim.fn.delete(root .. "/bin/Debug/net9.0/Missing.dll")

    local messages
    local recorded = with_stubs({}, function()
      messages = capture_notifications(function()
        dbg.debug(project)
      end)
    end)

    assert.are.equal(0, #recorded.runs)
    assert.is_truthy(joined(messages):find("not there", 1, true), joined(messages))
    vim.fn.delete(root, "rf")
  end)
end)
