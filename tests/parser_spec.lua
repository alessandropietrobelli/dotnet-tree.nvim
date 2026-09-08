-- Parser tests. The two solution parsers and the csproj/props readers are
-- pattern matching against third-party formats, and when they mis-read
-- something the symptom is an empty or truncated tree with no error, which is
-- very hard to diagnose from a bug report. These cover the shapes that real
-- repositories actually contain.
--
-- Run with plenary:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures"

local csproj = require("dotnet-tree.parser.csproj")
local cpm = require("dotnet-tree.parser.cpm")
local props = require("dotnet-tree.parser.props")
local solution = require("dotnet-tree.parser.solution")

local function names_of(list, key)
  local out = {}
  for _, item in ipairs(list) do
    table.insert(out, item[key])
  end
  table.sort(out)
  return out
end

describe("parser.csproj", function()
  before_each(function()
    csproj.invalidate()
    props.invalidate()
  end)

  it("reads project references written with either path separator", function()
    local result = csproj.parse(FIXTURES .. "/PathStyles.csproj")
    assert.is_not_nil(result)

    -- Regression: `[^/>]` in the tag pattern stopped at the first slash, so
    -- every POSIX-style Include was silently dropped. Six of the seven
    -- references below use forward slashes somewhere.
    assert.are.equal(7, #result.project_references)

    local basenames = {}
    for _, ref in ipairs(result.project_references) do
      basenames[vim.fn.fnamemodify(ref.path, ":t")] = true
    end
    for _, expected in ipairs({
      "Core.csproj",
      "Utils.csproj",
      "Deep.csproj",
      "Sibling.csproj",
      "Aliased.csproj",
      "MultiLine.csproj",
      "Paired.csproj",
    }) do
      assert.is_true(basenames[expected] == true, "missing project reference: " .. expected)
    end
  end)

  it("resolves project reference paths to absolute, separator-normalised paths", function()
    local result = csproj.parse(FIXTURES .. "/PathStyles.csproj")
    for _, ref in ipairs(result.project_references) do
      assert.is_nil(ref.path:find("\\", 1, true), "path kept a backslash: " .. ref.path)
      assert.are.equal("/", ref.path:sub(1, 1), "path is not absolute: " .. ref.path)
    end
  end)

  it("reads packages with an inline version and with no version at all", function()
    local result = csproj.parse(FIXTURES .. "/PathStyles.csproj")
    assert.are.same(
      { "Multi.Line.Package", "NoVersion.FromCpm", "Polly", "Serilog" },
      names_of(result.packages, "name")
    )
    local by_name = {}
    for _, pkg in ipairs(result.packages) do
      by_name[pkg.name] = pkg.version
    end
    assert.are.equal("3.1.1", by_name["Serilog"])
    assert.are.equal("8.4.1", by_name["Polly"])
    assert.are.equal("", by_name["NoVersion.FromCpm"])
  end)

  -- Regression for #9. The version can be written as a `<Version>` child
  -- element instead of an attribute, and MSBuild accepts both. csproj.lua had a
  -- branch for exactly this form and could never reach it: the single-line loop
  -- matched the opening tag, recorded the package with an empty version and
  -- marked it seen, so the child-element loop skipped it. Independently, that
  -- second pattern ran from the first <PackageReference in the file to the
  -- first </PackageReference>, so it spanned the three self-closing entries
  -- above Multi.Line.Package and would have attributed 2.0.0 to Serilog. Both
  -- disappear when the two forms are read from one element tree.
  it("reads the version from a <Version> child element", function()
    local result = csproj.parse(FIXTURES .. "/PathStyles.csproj")
    local by_name = {}
    for _, pkg in ipairs(result.packages) do
      by_name[pkg.name] = pkg.version
    end
    assert.are.equal("2.0.0", by_name["Multi.Line.Package"])
    -- The self-closing entries the old pattern spanned keep their own versions.
    assert.are.equal("3.1.1", by_name["Serilog"])
    assert.are.equal("8.4.1", by_name["Polly"])
    assert.are.equal("", by_name["NoVersion.FromCpm"])
  end)

  it("reads both TargetFramework and TargetFrameworks", function()
    assert.are.same({ "net9.0" }, csproj.parse(FIXTURES .. "/PathStyles.csproj").target_frameworks)
    assert.are.same({ "net8.0", "net9.0" }, csproj.parse(FIXTURES .. "/MultiTarget.csproj").target_frameworks)
  end)

  -- #23, first cause. The framework was read with a pattern that required the
  -- literal `<TargetFramework>` open tag, so an element carrying a `Condition`
  -- -- the default-guard idiom, and the per-OS branch -- read as no framework
  -- at all, with the value sitting in the file we were already parsing. Same
  -- class of defect as #10: a text pattern assuming a shape MSBuild does not
  -- promise. Frameworks are a list the tree displays, so a branch we cannot
  -- evaluate is kept as a candidate rather than dropped.
  it("reads a framework declared behind a Condition, on the element or on its group", function()
    local result = csproj.parse(FIXTURES .. "/ConditionalFramework.csproj")
    assert.are.same({ "net9.0", "net9.0-windows" }, result.target_frameworks)
  end)

  -- The other half of that rule: a conditional assignment is a candidate only
  -- when nothing unconditional answers. A project that says net9.0 plainly is
  -- not widened to net472 by a branch nobody asked for.
  it("does not widen a plainly declared framework with a conditional branch", function()
    local result = csproj.parse(FIXTURES .. "/ConditionalExtra.csproj")
    assert.are.same({ "net9.0" }, result.target_frameworks)
  end)

  -- #23, second cause, and the measured one: 15 of jellyfin's 42 projects
  -- declare no framework of their own and inherit it from the
  -- Directory.Build.props that MSBuild imports implicitly. The parser read one
  -- file and stopped, so a third of a real solution rendered with no framework
  -- and no path to its build output.
  it("inherits the framework from the nearest Directory.Build.props", function()
    local result = csproj.parse(FIXTURES .. "/props/Inheriting.csproj")
    assert.are.same({ "net10.0" }, result.target_frameworks)
  end)

  -- Import order: Directory.Build.props is imported above the project body, so
  -- the project's own assignment is the one in force.
  it("prefers the project's own framework over the inherited one", function()
    local result = csproj.parse(FIXTURES .. "/props/OwnFramework.csproj")
    assert.are.same({ "net8.0", "net9.0" }, result.target_frameworks)
  end)

  -- Nearest wins, which is also the stopping rule: the props file in the
  -- project's own directory hides the one above it.
  it("stops at the nearest props file rather than the topmost one", function()
    local result = csproj.parse(FIXTURES .. "/props/nested/Nested.csproj")
    assert.are.same({ "net8.0" }, result.target_frameworks)
  end)

  -- The scope boundary. This is a narrow walk, not MSBuild evaluation: a
  -- framework written as a property reference stays unknown, and a props file
  -- that says nothing about frameworks does not send us further up the tree
  -- looking for one.
  it("reports no framework when neither the project nor the props file names one", function()
    local result = csproj.parse(FIXTURES .. "/props/silent/Unknown.csproj")
    assert.are.same({}, result.target_frameworks)
  end)

  -- #16. An action that launches a project needs two things the parser did not
  -- read: whether the project produces something runnable, and what the output
  -- file is called. Without OutputType a launcher happily targets a library,
  -- which has no entry point and fails with an opaque runtime error instead of
  -- "this project is not runnable"; without AssemblyName the path
  -- bin/<config>/<tfm>/<name>.dll is a guess that is silently wrong whenever a
  -- project overrides the name.
  it("reads OutputType and AssemblyName, last unconditional assignment winning", function()
    local result = csproj.parse(FIXTURES .. "/Executable.csproj")
    assert.are.equal("Exe", result.output_type)
    assert.are.equal("dotnet-tool-probe", result.assembly_name)
  end)

  it("reports OutputType and AssemblyName as nil when the project does not say", function()
    local result = csproj.parse(FIXTURES .. "/MultiTarget.csproj")
    assert.is_nil(result.output_type)
    assert.is_nil(result.assembly_name)
  end)

  -- The scope boundary, pinned: reading XML is not evaluating MSBuild. A value
  -- written as a property reference comes back as written, and it is the
  -- caller's job to treat what it cannot use as unknown rather than to build a
  -- path out of it.
  it("returns property references verbatim rather than pretending to evaluate them", function()
    local result = csproj.parse(FIXTURES .. "/Unevaluated.csproj")
    assert.are.equal("$(DefaultOutputType)", result.output_type)
    assert.are.equal("$(MSBuildProjectName).Tool", result.assembly_name)
  end)

  -- #24. `OutputType` answers "is there an entry point", which is not the same
  -- question as "is this an application someone wants to launch": an xunit v3
  -- test project declares Exe, because v3 runs each test assembly as its own
  -- process. All 16 test projects in a jellyfin checkout do. Without a second
  -- signal, anything keyed on OutputType alone offers every test project in a
  -- solution as if it were an app.
  it("recognises a test project by its Microsoft.NET.Test.Sdk reference", function()
    local result = csproj.parse(FIXTURES .. "/TestProject.csproj")
    assert.is_true(result.is_test_project)
    -- The thing that made this necessary: it looks exactly like an app.
    assert.are.equal("Exe", result.output_type)
  end)

  it("recognises a test project that declares IsTestProject itself", function()
    assert.is_true(csproj.parse(FIXTURES .. "/TestProjectDeclared.csproj").is_test_project)
  end)

  -- MSBuild lets a project carrying the test SDK opt out, and shared test
  -- infrastructure does exactly that. The explicit property wins.
  it("believes an explicit IsTestProject false over the package reference", function()
    assert.is_false(csproj.parse(FIXTURES .. "/TestProjectOptOut.csproj").is_test_project)
  end)

  it("does not call an ordinary application or a library a test project", function()
    assert.is_false(csproj.parse(FIXTURES .. "/PlainExe.csproj").is_test_project)
    assert.is_false(csproj.parse(FIXTURES .. "/MultiTarget.csproj").is_test_project)
  end)

  it("returns nil for a file that does not exist", function()
    assert.is_nil(csproj.parse(FIXTURES .. "/DoesNotExist.csproj"))
  end)

  -- Regression for #10. A literal '>' inside an attribute value is valid XML
  -- -- XML 1.0 section 2.4 forbids '<' and '&' there, not '>' -- and MSBuild
  -- builds such a project without a warning. The old tag scanner read up to the
  -- first '>' regardless of quoting, so it truncated the tag: when the Include
  -- followed the offending attribute the reference was dropped with no error.
  -- Tag boundaries now come from parser/xml.lua, which tracks quoting.
  it("reads references whose Include sits behind a literal > in an attribute", function()
    local result = csproj.parse(FIXTURES .. "/EdgeCases.csproj")
    local seen = {}
    for _, ref in ipairs(result.project_references) do
      seen[vim.fn.fnamemodify(ref.path, ":t")] = true
    end

    -- Escaped as &gt;, and literal '>' in either attribute order: all read.
    assert.is_true(seen["Escaped.csproj"] == true)
    assert.is_true(seen["GtAfter.csproj"] == true)
    assert.is_true(seen["GtBefore.csproj"] == true, "reference behind a literal > was dropped")
    -- A later, well-formed entry is unaffected: one such tag does not
    -- desynchronise the rest of the file.
    assert.is_true(seen["Live.csproj"] == true)
  end)

  it("reads a package whose Include and Version both sit behind a literal >", function()
    local result = csproj.parse(FIXTURES .. "/EdgeCases.csproj")
    local by_name = {}
    for _, pkg in ipairs(result.packages) do
      by_name[pkg.name] = pkg.version
    end
    assert.are.equal("1.2.3", by_name["GtBefore.Package"])
    assert.are.equal("2.0.0", by_name["Live.Package"])
  end)

  -- Regression: comments used to be scanned like any other markup, so a
  -- commented-out entry was reported as a real dependency. Observed in the
  -- wild before the fix: jellyfin's Emby.Server.Implementations.csproj carries
  -- a commented-out IDisposableAnalyzers reference, and the tree listed it
  -- with a version resolved from central package management.
  it("ignores references and packages inside XML comments", function()
    local result = csproj.parse(FIXTURES .. "/EdgeCases.csproj")

    for _, ref in ipairs(result.project_references) do
      assert.are_not.equal("Commented.csproj", vim.fn.fnamemodify(ref.path, ":t"))
    end
    local names = {}
    for _, pkg in ipairs(result.packages) do
      names[pkg.name] = true
    end
    assert.is_nil(names["Commented.Package"])

    -- The live entries either side of the comments must survive it.
    local live_ref = false
    for _, ref in ipairs(result.project_references) do
      if vim.fn.fnamemodify(ref.path, ":t") == "Live.csproj" then
        live_ref = true
      end
    end
    assert.is_true(live_ref)
    assert.is_true(names["Live.Package"] == true)
  end)
end)

describe("parser.cpm", function()
  before_each(function()
    cpm.invalidate()
  end)

  it("reads versions declared as attributes", function()
    local versions = cpm.parse(FIXTURES .. "/Directory.Packages.props")
    assert.are.equal("9.9.9", versions["NoVersion.FromCpm"])
    assert.are.equal("4.0.0", versions["Serilog"])
  end)

  -- Same regression as the csproj side. A commented-out PackageVersion used to
  -- be treated as the effective version, which in a central-package-management
  -- repository means the tree quotes a version that is not in force.
  it("ignores versions inside XML comments", function()
    local versions = cpm.parse(FIXTURES .. "/Directory.Packages.props")
    assert.is_nil(versions["Commented.Cpm"])
    assert.are.equal("4.0.0", versions["Serilog"])
  end)

  -- Same regression as the csproj side (#10): the props reader used the same
  -- truncating tag scanner, so a centrally pinned version behind a literal '>'
  -- was invisible and the tree showed no version for that package.
  it("reads a version whose Include sits behind a literal > in an attribute", function()
    local versions = cpm.parse(FIXTURES .. "/Directory.Packages.props")
    assert.are.equal("5.5.5", versions["GtBefore.Cpm"])
  end)

  -- Same form on the props side (#9). cpm.lua read it correctly only by
  -- accident of ordering, and lost it as soon as a self-closing entry came
  -- first: the multi-line pattern started at the first <PackageVersion in the
  -- file and ran to the first </PackageVersion>, swallowing the entries in
  -- between and never seeing the tag that carries the child <Version>.
  it("reads versions declared as a <Version> child element", function()
    local versions = cpm.parse(FIXTURES .. "/Directory.Packages.props")
    assert.are.equal("7.7.7", versions["Multi.Line.Cpm"])
    -- The self-closing entries above it are unaffected.
    assert.are.equal("9.9.9", versions["NoVersion.FromCpm"])
    assert.are.equal("4.0.0", versions["Serilog"])
  end)

  it("returns an empty table for a missing props file", function()
    assert.are.same({}, cpm.parse(FIXTURES .. "/Nope.props"))
  end)

  it("finds the props file by walking up from a directory", function()
    assert.are.equal(FIXTURES .. "/Directory.Packages.props", cpm.find_props(FIXTURES))
  end)
end)

describe("parser.props", function()
  before_each(function()
    props.invalidate()
  end)

  -- The walk both implicitly imported MSBuild files share. `stop_dir` is what
  -- keeps a lookup inside the solution instead of climbing out of it.
  it("finds the nearest file, not the topmost one", function()
    assert.are.equal(
      FIXTURES .. "/props/nested/Directory.Build.props",
      props.find_up(FIXTURES .. "/props/nested", "Directory.Build.props")
    )
  end)

  it("keeps looking upward when the file is not in the starting directory", function()
    assert.are.equal(
      FIXTURES .. "/Directory.Packages.props",
      props.find_up(FIXTURES .. "/props/nested", "Directory.Packages.props")
    )
  end)

  it("stops at stop_dir instead of climbing out of the solution", function()
    assert.is_nil(props.find_up(FIXTURES .. "/props/nested", "Nope.props", FIXTURES .. "/props"))
  end)
end)

describe("parser.solution", function()
  before_each(function()
    solution.invalidate()
  end)

  it("keeps the .sln fixture CRLF, which is what the format really uses", function()
    -- Guards the fixture itself: the parser matches `\r?\n` around EndProject,
    -- and a fixture normalised to LF on checkout would stop covering that.
    local handle = assert(io.open(FIXTURES .. "/Sample.sln", "rb"))
    local content = handle:read("*a")
    handle:close()
    assert.is_truthy(content:find("\r\n", 1, true), "fixture lost its CRLF line endings")
  end)

  it("reads a classic .sln with a solution folder and nesting", function()
    local sln = solution.parse(FIXTURES .. "/Sample.sln")
    assert.is_not_nil(sln)

    local by_name = {}
    for _, entry in ipairs(sln.projects) do
      by_name[entry.name] = entry
    end

    assert.are.equal("folder", by_name["src"].kind)
    assert.are.equal("csharp", by_name["Alpha"].kind)
    assert.are.equal("csharp", by_name["Beta"].kind)

    -- Alpha is nested under src, Beta is not.
    assert.are.equal(by_name["src"].guid, by_name["Alpha"].parent_guid)
    assert.is_nil(by_name["Beta"].parent_guid)

    assert.are.equal(1, #by_name["src"].solution_items)
    assert.are.equal("Directory.Packages.props", by_name["src"].solution_items[1].rel)
  end)

  it("reads a .slnx and reconstructs the folder hierarchy from Name paths", function()
    local sln = solution.parse(FIXTURES .. "/Sample.slnx")
    assert.is_not_nil(sln)

    local by_name = {}
    for _, entry in ipairs(sln.projects) do
      by_name[entry.name] = entry
    end

    local project_names = {}
    for _, entry in ipairs(sln.projects) do
      if entry.kind ~= "folder" then
        table.insert(project_names, entry.name)
      end
    end
    table.sort(project_names)
    assert.are.same({ "Alpha", "Beta", "Gamma" }, project_names)

    -- "/src/nested/" is declared, so it must exist and hang off "/src/".
    assert.is_not_nil(by_name["nested"])
    assert.are.equal(by_name["src"].guid, by_name["nested"].parent_guid)
    assert.are.equal(by_name["nested"].guid, by_name["Gamma"].parent_guid)
    assert.are.equal(by_name["src"].guid, by_name["Alpha"].parent_guid)
  end)

  it("gives both formats the same contract", function()
    for _, file in ipairs({ "/Sample.sln", "/Sample.slnx" }) do
      local sln = solution.parse(FIXTURES .. file)
      assert.is_string(sln.path)
      assert.is_string(sln.name)
      assert.is_string(sln.dir)
      assert.is_table(sln.projects)
      assert.is_table(sln.by_guid)
      for _, entry in ipairs(sln.projects) do
        assert.is_string(entry.guid, file .. ": entry without guid")
        assert.is_string(entry.name, file .. ": entry without name")
        assert.is_table(entry.children_guids, file .. ": entry without children_guids")
        assert.is_table(entry.solution_items, file .. ": entry without solution_items")
        if entry.kind ~= "folder" then
          assert.are.equal("/", entry.path:sub(1, 1), file .. ": project path is not absolute")
        end
      end
    end
  end)

  it("lists .slnx before .sln when a directory holds both", function()
    local found = solution.find(FIXTURES)
    assert.are.equal(2, #found)
    assert.is_truthy(found[1]:match("%.slnx$"))
    assert.is_truthy(found[2]:match("%.sln$"))
  end)
end)
