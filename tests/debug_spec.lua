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

-- A stand-in for `dotnet msbuild -getProperty:<name>`, which #31 made `d`
-- depend on. Real MSBuild is not run in the suite: 0.6s per query, and CI has
-- no SDK. What matters is what the module does with each answer shape, and the
-- shapes are the ones measured on SDK 10.0.302:
--
--   TargetPath with a -p:TargetFramework   the assembly, wherever it lives
--   TargetPath on an outer multi-target    exit 0 and no output
--   any -getProperty on an SDK before 8    exit 1 (MSB1001)
--
-- The default answers for a project that has *not* moved its output, so it
-- names the same path the composed fallback would. That is deliberate: the
-- tests that have to tell the two apart are the ones that move the output.
local function default_msbuild(cmd)
  local project, property, tfm
  for _, arg in ipairs(cmd) do
    if arg:match("%.%a-proj$") then
      project = arg
    end
    property = arg:match("^%-getProperty:(.+)$") or property
    tfm = arg:match("^%-p:TargetFramework=(.+)$") or tfm
  end
  if property == "TargetPath" and project and tfm then
    return 0,
      {
        ("%s/bin/Debug/%s/%s.dll"):format(vim.fn.fnamemodify(project, ":h"), tfm, vim.fn.fnamemodify(project, ":t:r")),
      }
  end
  return 0, {}
end

-- An SDK older than 8 does not know `-getProperty` and MSBuild exits non-zero,
-- which is the case the composed fallback exists for.
local function msbuild_too_old()
  return 1, { "MSBUILD : error MSB1001: Unknown switch." }
end

-- Replaces the modules M.debug reaches for. Returns a table recording what the
-- stub dap was asked to run, and every command the MSBuild query was asked to
-- run.
local function with_stubs(opts, fn)
  local recorded = { runs = {}, queries = {} }

  local previous_dap = package.loaded["dap"]
  local previous_build = package.loaded["dotnet-tree.build"]
  local previous_path = dbg.debugger_path
  local previous_query = dbg.query

  -- M.query is the module's one process boundary, which is what makes the rest
  -- of it testable synchronously: the real one is a jobstart whose callback
  -- would never run inside a test.
  dbg.query = function(cmd, cb)
    table.insert(recorded.queries, cmd)
    local code, lines = (opts.msbuild or default_msbuild)(cmd)
    cb(code, lines)
  end

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
  dbg.query = previous_query

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

-- A file at `path`, parent directories included. `d` checks the assembly is
-- readable before handing it to the debugger, so a layout only exists for the
-- test once something is actually there.
local function write_assembly(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local handle = assert(io.open(path, "w"))
  handle:write("not really an assembly")
  handle:close()
  return path
end

-- Answers one `-getProperty` query from a table of properties, keyed by name --
-- or by `name:tfm` when the answer depends on which framework the query named,
-- which is how a multi-targeted project behaves. A property with no entry reads
-- as empty, which is exit 0 and no output.
local function answer(cmd, properties)
  local property, tfm
  for _, arg in ipairs(cmd) do
    property = arg:match("^%-getProperty:(.+)$") or property
    tfm = arg:match("^%-p:TargetFramework=(.+)$") or tfm
  end
  local value = tfm and properties[property .. ":" .. tfm] or properties[property]
  if not value then
    return 0, {}
  end
  return 0, { value }
end

describe("debug.resolve", function()
  before_each(function()
    csproj.invalidate()
  end)

  -- The bug this pins: an ASP.NET Core project carries no `<OutputType>`,
  -- because `Microsoft.NET.Sdk.Web` sets it. Read as a plain Library, `d`
  -- refused to debug the single most common kind of .NET application there is.
  it("launches a Web SDK project that declares no OutputType", function()
    local target, reason = dbg.resolve(FIXTURES .. "/WebApi.csproj")
    assert.is_nil(reason)
    assert.is_truthy(target)
    assert.are.equal("WebApi", target.assembly_name)
  end)

  it("launches a Worker SDK project named with an <Sdk> element", function()
    local target = assert(dbg.resolve(FIXTURES .. "/WorkerSdkElement.csproj"))
    assert.are.equal("WorkerSdkElement", target.assembly_name)
  end)

  it("still refuses a Razor class library, whose SDK defaults to Library", function()
    local target, reason = dbg.resolve(FIXTURES .. "/RazorClassLib.csproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("library", 1, true), reason)
    -- The message has to name where the default came from, or the reader goes
    -- looking for an OutputType that was never written.
    assert.is_truthy(reason:find("Microsoft.NET.Sdk.Razor", 1, true), reason)
  end)

  -- Every <OutputType> assignment in the SDKs on disk, not just the two that
  -- mean "runnable": the Docker SDK sets DockerCompose. Refusing it is right;
  -- telling its author it is a Library would not be.
  it("does not call a DockerCompose project a library", function()
    local target, reason = dbg.resolve(FIXTURES .. "/DockerCompose.dcproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("DockerCompose", 1, true), reason)
    assert.is_nil(reason:find("Library", 1, true), reason)
  end)

  -- A project with no Sdk attribute has no SDK whose default could be named,
  -- and naming one it never imported would be an invented fact.
  it("does not attribute a default to an SDK a legacy project never imported", function()
    local target, reason = dbg.resolve(FIXTURES .. "/LegacyNoSdk.csproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("library", 1, true), reason)
    assert.is_nil(reason:find("Microsoft.NET.Sdk", 1, true), reason)
  end)

  -- MSBuild reports Exe for this SDK, so OutputType alone would launch it --
  -- and `dotnet App.dll` on a Blazor WebAssembly build dies in the host with a
  -- libhostpolicy error that says nothing about the browser.
  it("refuses a Blazor WebAssembly app, which is an Exe it cannot start", function()
    local target, reason = dbg.resolve(FIXTURES .. "/BlazorWasm.csproj")
    assert.is_nil(target)
    assert.is_truthy(reason:find("browser", 1, true), reason)
    assert.is_nil(reason:find("library", 1, true), reason)
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

-- The three answer shapes of `dotnet msbuild -getProperty:<name>`, measured
-- rather than assumed. The two behavioural cases below are covered by the `d`
-- tests as well; the multi-line one is not reachable through them, and it is
-- the one where guessing would put the debugger on an arbitrary path.
describe("debug.parse_property", function()
  it("reads the value out of a one-line answer, trimmed", function()
    assert.are.equal("/tmp/Api.dll", dbg.parse_property(0, { "  /tmp/Api.dll  ", "" }))
  end)

  it("reads nothing from an empty answer, which is a property with no value", function()
    assert.is_nil(dbg.parse_property(0, {}))
    assert.is_nil(dbg.parse_property(0, { "", "  " }))
  end)

  it("reads nothing from a non-zero exit, which is an SDK before 8", function()
    assert.is_nil(dbg.parse_property(1, { "MSBUILD : error MSB1001: Unknown switch." }))
  end)

  -- More than one value is not an answer to prefer over the fallback: picking
  -- one of them would be a guess dressed up as a measurement.
  it("refuses to choose between several lines", function()
    assert.is_nil(dbg.parse_property(0, { "/tmp/one.dll", "/tmp/two.dll" }))
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

  -- #31. `bin/<Configuration>/<tfm>/<AssemblyName>.dll` is the default layout,
  -- not the only one. A repository that sets `<ArtifactsPath>` has no
  -- `<project>/bin` at all, so composing that path did not just miss -- it
  -- named a directory that does not exist, and `d` was unusable on the whole
  -- repository. Answered by asking MSBuild where the output went.
  it("launches the assembly MSBuild names when the output is not under bin/", function()
    local root, project = scratch_project("Api", {}, { declare = false })
    local dll = write_assembly(root .. "/artifacts/bin/Api/debug/Api.dll")
    assert.are.equal(0, vim.fn.isdirectory(root .. "/bin"))

    local recorded = with_stubs({
      msbuild = function(cmd)
        return answer(cmd, { TargetPath = dll })
      end,
    }, function()
      dbg.debug(project)
    end)

    assert.are.equal(project, recorded.built)
    assert.are.equal(1, #recorded.runs)
    assert.are.equal(dll, recorded.runs[1].program)
    vim.fn.delete(root, "rf")
  end)

  -- Under the artifacts layout the directory is the *project* name and the file
  -- is the assembly name, so a renamed assembly breaks composition even where
  -- the directory is guessed right. MSBuild is told both.
  it("follows an assembly name that differs from the project name", function()
    local root, project = scratch_project("Named", {}, { declare = false })
    local dll = write_assembly(root .. "/artifacts/bin/Named/debug/Renamed.dll")

    local recorded = with_stubs({
      msbuild = function(cmd)
        return answer(cmd, { TargetPath = dll })
      end,
    }, function()
      dbg.debug(project)
    end)

    assert.are.equal(1, #recorded.runs)
    assert.are.equal(dll, recorded.runs[1].program)
    vim.fn.delete(root, "rf")
  end)

  -- Not a regression test, and counted as what it is: `-getProperty` needs
  -- MSBuild 17.8, so on an SDK before 8 there is no answer to prefer and the
  -- old composed path is all there is. It passes against the code before #31
  -- too -- that code did nothing else. It is here so removing the fallback
  -- fails something.
  it("falls back to the default layout when the SDK cannot answer", function()
    local root, project = scratch_project("OldSdk", { "net9.0" })

    local recorded = with_stubs({ msbuild = msbuild_too_old }, function()
      dbg.debug(project)
    end)

    assert.are.equal(1, #recorded.runs)
    assert.are.equal(root .. "/bin/Debug/net9.0/OldSdk.dll", recorded.runs[1].program)
    vim.fn.delete(root, "rf")
  end)

  -- When the assembly really is missing, the path in the message has to be the
  -- one the build was configured to produce. Naming a composed `bin/` path
  -- under an artifacts layout sends the reader to a directory that never
  -- existed, which is the shape of the original #31 report.
  it("names the path MSBuild gave when the assembly is not there", function()
    local root, project = scratch_project("Gone", {}, { declare = false })
    local dll = root .. "/artifacts/bin/Gone/debug/Gone.dll"

    local messages
    local recorded = with_stubs({
      msbuild = function(cmd)
        return answer(cmd, { TargetPath = dll })
      end,
    }, function()
      messages = capture_notifications(function()
        dbg.debug(project)
      end)
    end)

    assert.are.equal(0, #recorded.runs)
    local text = joined(messages)
    assert.is_truthy(text:find("artifacts", 1, true), text)
    assert.is_nil(text:find("/bin/Debug/", 1, true), text)
    vim.fn.delete(root, "rf")
  end)

  -- A framework written as `$(DefaultTfm)` is not a framework the parser can
  -- expand. Before #31 the only way out was to read the frameworks back off
  -- `bin/`, which a repository that moves its output does not have -- so `d`
  -- ended in "cannot tell what this builds" with a perfectly good build on
  -- disk. MSBuild evaluates the property, and for a single-target project
  -- `TargetPath` answers without being told a framework, so there is nothing to
  -- ask the user either. Both halves of the guess are gone at once, which is
  -- why the two central properties are tested together here.
  it("launches a project whose framework the parser cannot expand", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local project = root .. "/Indirect.csproj"
    local handle = assert(io.open(project, "w"))
    handle:write([[
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$(DefaultTfm)</TargetFramework>
  </PropertyGroup>
</Project>
]])
    handle:close()
    local dll = write_assembly(root .. "/artifacts/bin/Indirect/debug/Indirect.dll")

    local target = assert(dbg.resolve(project))
    assert.are.same({}, target.frameworks)
    assert.are.same({}, dbg.frameworks(target))

    local messages
    local recorded = with_stubs({
      msbuild = function(cmd)
        return answer(cmd, { TargetPath = dll })
      end,
    }, function()
      messages = capture_notifications(function()
        dbg.debug(project)
      end)
    end)

    assert.are.equal(1, #recorded.runs)
    assert.are.equal(dll, recorded.runs[1].program)
    assert.is_nil(joined(messages):find("cannot tell", 1, true), joined(messages))
    vim.fn.delete(root, "rf")
  end)

  -- The outer build of a multi-targeted project has no single TargetPath, so
  -- MSBuild answers with nothing. That empty answer is the signal that a choice
  -- is needed -- and the frameworks to choose from come from MSBuild too, not
  -- from whatever a previous build left under bin/.
  it("asks which framework when the outer build names no output", function()
    local root, project = scratch_project("Multi", {}, { declare = false })
    local net8 = write_assembly(root .. "/artifacts/bin/Multi/debug_net8.0/Multi.dll")
    local net9 = write_assembly(root .. "/artifacts/bin/Multi/debug_net9.0/Multi.dll")

    local offered
    local previous_select = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      offered = items
      on_choice("net9.0")
    end

    local recorded = with_stubs({
      msbuild = function(cmd)
        return answer(cmd, {
          TargetFrameworks = "net8.0;net9.0",
          -- Only the inner build, the one told a framework, has an output.
          ["TargetPath:net8.0"] = net8,
          ["TargetPath:net9.0"] = net9,
        })
      end,
    }, function()
      dbg.debug(project)
    end)

    vim.ui.select = previous_select

    assert.are.same({ "net8.0", "net9.0" }, offered)
    assert.are.equal(1, #recorded.runs)
    assert.are.equal(net9, recorded.runs[1].program)
    vim.fn.delete(root, "rf")
  end)
end)
