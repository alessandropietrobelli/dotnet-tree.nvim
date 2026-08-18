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

  -- Known defect in csproj.lua only, present since the parser was written and
  -- not addressed here. cpm.lua reads the same form correctly, because its
  -- first loop requires both Include and Version and so records nothing here.
  -- The single-line loop matches the opening tag of the child-element form and
  -- records the package with an empty version, so the multi-line loop that
  -- would read <Version> skips it as already seen. Independently, the
  -- multi-line pattern spans across any preceding self-closing tag, so it
  -- attributes the child <Version> to the wrong package and consumes the real
  -- one. Enable this once the tag scanner handles both forms in one pass.
  pending("reads the version from a <Version> child element", function()
    local result = csproj.parse(FIXTURES .. "/PathStyles.csproj")
    local by_name = {}
    for _, pkg in ipairs(result.packages) do
      by_name[pkg.name] = pkg.version
    end
    assert.are.equal("2.0.0", by_name["Multi.Line.Package"])
  end)

  it("reads both TargetFramework and TargetFrameworks", function()
    assert.are.same({ "net9.0" }, csproj.parse(FIXTURES .. "/PathStyles.csproj").target_frameworks)
    assert.are.same({ "net8.0", "net9.0" }, csproj.parse(FIXTURES .. "/MultiTarget.csproj").target_frameworks)
  end)

  it("returns nil for a file that does not exist", function()
    assert.is_nil(csproj.parse(FIXTURES .. "/DoesNotExist.csproj"))
  end)

  -- The tag scanner reads up to the first '>' regardless of quoting, so a
  -- literal '>' inside an attribute value truncates the tag. That '>' is valid
  -- XML -- XML 1.0 section 2.4 forbids '<' and '&' in attribute values, not
  -- '>' -- and MSBuild builds such a project without a warning, so this is a
  -- defect rather than graceful degradation on malformed input: the reference
  -- is dropped silently and the two attribute orderings differ. slnx.lua
  -- handles the same construct correctly (find_tag_end). Pinned as current
  -- behaviour, not as desired behaviour; tracked in issue #10.
  it("degrades predictably on a literal > inside an attribute", function()
    local result = csproj.parse(FIXTURES .. "/EdgeCases.csproj")
    local seen = {}
    for _, ref in ipairs(result.project_references) do
      seen[vim.fn.fnamemodify(ref.path, ":t")] = true
    end

    -- Escaped as &gt;: read, whatever the attribute order.
    assert.is_true(seen["Escaped.csproj"] == true)
    -- Literal '>', but the Include comes first, so it has already been read.
    assert.is_true(seen["GtAfter.csproj"] == true)
    -- Literal '>' and the Include comes after it: the reference is lost.
    assert.is_nil(seen["GtBefore.csproj"])
    -- A later, well-formed entry is unaffected: one bad tag does not
    -- desynchronise the rest of the file.
    assert.is_true(seen["Live.csproj"] == true)
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

  -- Same known defect as the csproj side: the multi-line pattern starts at the
  -- first <PackageVersion in the file and runs to the first </PackageVersion>,
  -- so it swallows the preceding self-closing entries and never sees the tag
  -- that actually carries the child <Version>.
  pending("reads versions declared as a <Version> child element", function()
    local versions = cpm.parse(FIXTURES .. "/Directory.Packages.props")
    assert.are.equal("7.7.7", versions["Multi.Line.Cpm"])
  end)

  it("returns an empty table for a missing props file", function()
    assert.are.same({}, cpm.parse(FIXTURES .. "/Nope.props"))
  end)

  it("finds the props file by walking up from a directory", function()
    assert.are.equal(FIXTURES .. "/Directory.Packages.props", cpm.find_props(FIXTURES))
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
