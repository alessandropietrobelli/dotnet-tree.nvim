-- Solution folders and their files, written into .sln and .slnx (#66).

local edit = require("dotnet-tree.solution_edit")
local solution = require("dotnet-tree.parser.solution")

local BOM = "\239\187\191"
local FOLDER = "2150E333-8FDC-42A3-9474-1A3956D46DE8"
local CSHARP = "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC"

-- A temporary directory holding a solution file with `content`
local function solution_file(name, content)
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return dir, path
end

local function bytes(path)
  local f = assert(io.open(path, "rb"))
  local content = f:read("*a")
  f:close()
  return content
end

local function touch(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({}, path)
  return path
end

local function parse(path)
  solution.invalidate(path)
  return assert(solution.parse(path))
end

local function folder_named(sln, name)
  for _, entry in ipairs(sln.projects) do
    if entry.kind == "folder" and entry.name == name then
      return entry
    end
  end
end

local function items_of(folder)
  return vim.tbl_map(function(item)
    return item.path
  end, folder.solution_items)
end

-- The shape Visual Studio writes: BOM, CRLF, tabs, the issue's `build` folder
local function vs_sln(eol)
  return BOM
    .. table.concat({
      "",
      "Microsoft Visual Studio Solution File, Format Version 12.00",
      "# Visual Studio Version 17",
      ('Project("{%s}") = "build", "build", "{C8AD7A75-9928-4BAD-BD6E-305447D64F04}"'):format(FOLDER),
      "\tProjectSection(SolutionItems) = preProject",
      "\t\tbuild\\build.cake = build\\build.cake",
      "\tEndProjectSection",
      "EndProject",
      ('Project("{%s}") = "docs", "docs", "{0E1F7B33-5D2A-4C5E-9E0B-2B6B6C3E0A11}"'):format(FOLDER),
      "EndProject",
      ('Project("{%s}") = "Api", "src\\Api\\Api.csproj", "{6D3E2A90-8E2B-4B7A-9C55-8E2E1F0A2B3C}"'):format(CSHARP),
      "EndProject",
      "Global",
      "\tGlobalSection(SolutionConfigurationPlatforms) = preSolution",
      "\t\tDebug|Any CPU = Debug|Any CPU",
      "\tEndGlobalSection",
      "EndGlobal",
      "",
    }, eol)
end

describe("solution_edit on .sln", function()
  it("adds a file to a folder's SolutionItems, keeping BOM and CRLF", function()
    local dir, path = solution_file("All.sln", vs_sln("\r\n"))
    local file = touch(dir .. "/build/version.props")
    local before = bytes(path)

    assert.is_true(edit.add_file(path, folder_named(parse(path), "build"), file))

    local after = bytes(path)
    assert.are.equal(BOM, after:sub(1, 3))
    assert.is_nil(after:gsub("\r\n", ""):find("\n"), "every line still ends in CRLF")
    assert.truthy(
      after:find(
        "\t\tbuild\\build.cake = build\\build.cake\r\n\t\tbuild\\version.props = build\\version.props\r\n\tEndProjectSection",
        1,
        true
      )
    )
    assert.are.equal(#before + #"\t\tbuild\\version.props = build\\version.props\r\n", #after, "nothing else changed")
    assert.are.same({ dir .. "/build/build.cake", file }, items_of(folder_named(parse(path), "build")))
  end)

  it("creates the SolutionItems section of a folder that has none", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local file = touch(dir .. "/docs/README.md")
    assert.is_true(edit.add_file(path, folder_named(parse(path), "docs"), file))
    assert.truthy(
      bytes(path):find(
        '"{0E1F7B33-5D2A-4C5E-9E0B-2B6B6C3E0A11}"\n\tProjectSection(SolutionItems) = preProject\n'
          .. "\t\tdocs\\README.md = docs\\README.md\n\tEndProjectSection\nEndProject",
        1,
        true
      )
    )
    assert.are.same({ file }, items_of(folder_named(parse(path), "docs")))
  end)

  it("writes a file outside the solution's directory with ..", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local outside = touch(vim.fn.fnamemodify(dir, ":h") .. "/shared-" .. vim.fn.fnamemodify(dir, ":t") .. ".props")
    assert.is_true(edit.add_file(path, folder_named(parse(path), "docs"), outside))
    assert.truthy(bytes(path):find("..\\shared-", 1, true))
    assert.are.same({ outside }, items_of(folder_named(parse(path), "docs")))
    os.remove(outside)
  end)

  it("creates a folder at the root, before Global", function()
    local _, path = solution_file("All.sln", vs_sln("\r\n"))
    local ok, err, guid = edit.add_folder(path, nil, "tools", { "build", "docs" })
    assert.is_true(ok, err)
    assert.matches("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89AB]%x%x%x%-%x+$", guid)
    local text = bytes(path)
    assert.truthy(
      text:find(
        ('Project("{%s}") = "tools", "tools", "{%s}"\r\nEndProject\r\nGlobal\r\n'):format(FOLDER, guid),
        1,
        true
      )
    )
    local folder = folder_named(parse(path), "tools")
    assert.are.equal(guid, folder.guid)
    assert.is_nil(folder.parent_guid)
  end)

  it("nests a new folder, creating NestedProjects when there is none and adding to it after", function()
    local _, path = solution_file("All.sln", vs_sln("\r\n"))
    local build = folder_named(parse(path), "build")
    local _, _, ci = edit.add_folder(path, build, "ci", {})
    local _, _, release = edit.add_folder(path, build, "release", { "ci" })
    local text = bytes(path)
    local _, count = text:gsub("GlobalSection%(NestedProjects%)", "")
    assert.are.equal(1, count)
    local sln = parse(path)
    assert.are.equal(build.guid, sln.by_guid[ci].parent_guid)
    assert.are.equal(build.guid, sln.by_guid[release].parent_guid)
    assert.are.same({ ci, release }, sln.by_guid[build.guid].children_guids)
  end)

  it("refuses a duplicate file, a duplicate folder and a name it cannot write", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local before = bytes(path)
    local build = folder_named(parse(path), "build")
    local ok, err = edit.add_file(path, build, dir .. "/build/build.cake")
    assert.is_nil(ok)
    assert.matches("already in build", err, 1, true)
    ok, err = edit.add_folder(path, nil, "Docs", { "build", "docs" })
    assert.is_nil(ok)
    assert.matches("already a docs", err, 1, true)
    for _, bad in ipairs({ "", "  ", 'a"b', "a/b" }) do
      assert.is_nil((edit.add_folder(path, nil, bad, {})))
    end
    assert.are.equal(before, bytes(path), "the file is untouched")
  end)

  it("does not write over unsaved changes to the solution file", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# edited" })
    local ok, err = edit.add_file(path, folder_named(parse(path), "docs"), touch(dir .. "/docs/a.md"))
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(ok)
    assert.matches("unsaved changes", err, 1, true)
  end)
end)

describe("solution_edit on .slnx", function()
  local function slnx(eol, indent)
    return table.concat({
      "<Solution>",
      indent .. '<Folder Name="/build/">',
      indent .. indent .. '<File Path="build/build.cake" />',
      indent .. "</Folder>",
      indent .. '<Folder Name="/docs/" />',
      indent .. '<Folder Name="/src/libs/">',
      indent .. indent .. '<Project Path="src/libs/Core/Core.csproj" />',
      indent .. "</Folder>",
      indent .. '<Project Path="src/Api/Api.csproj" />',
      "</Solution>",
      "",
    }, eol)
  end

  it("adds a file inside a folder, at the folder's indentation", function()
    local dir, path = solution_file("All.slnx", slnx("\r\n", "  "))
    local file = touch(dir .. "/build/version.props")
    assert.is_true(edit.add_file(path, folder_named(parse(path), "build"), file))
    assert.truthy(
      bytes(path):find(
        '    <File Path="build/build.cake" />\r\n    <File Path="build/version.props" />\r\n  </Folder>\r\n',
        1,
        true
      )
    )
    assert.are.same({ dir .. "/build/build.cake", file }, items_of(folder_named(parse(path), "build")))
  end)

  it("opens a folder that closed itself, with tabs", function()
    local dir, path = solution_file("All.slnx", slnx("\n", "\t"))
    local file = touch(dir .. "/docs/a & b.md")
    assert.is_true(edit.add_file(path, folder_named(parse(path), "docs"), file))
    assert.truthy(
      bytes(path):find('\t<Folder Name="/docs/">\n\t\t<File Path="docs/a &amp; b.md" />\n\t</Folder>\n', 1, true)
    )
    assert.are.same({ file }, items_of(folder_named(parse(path), "docs")))
  end)

  -- `/src/` exists only because `/src/libs/` names it
  it("writes a folder that was only implied before adding a file to it", function()
    local dir, path = solution_file("All.slnx", slnx("\n", "  "))
    local src = folder_named(parse(path), "src")
    assert.truthy(src)
    local file = touch(dir .. "/src/Directory.Build.props")
    assert.is_true(edit.add_file(path, src, file))
    assert.are.same({ file }, items_of(folder_named(parse(path), "src")))
  end)

  it("creates folders at the root and nested, which the parser places", function()
    local _, path = solution_file("All.slnx", slnx("\n", "  "))
    assert.is_true(edit.add_folder(path, nil, "tools", {}))
    local ok, _, id = edit.add_folder(path, folder_named(parse(path), "build"), "ci", {})
    assert.is_true(ok)
    assert.are.equal("/build/ci/", id)
    assert.truthy(bytes(path):find('  <Folder Name="/build/ci/" />\n</Solution>', 1, true))
    local sln = parse(path)
    assert.is_nil(folder_named(sln, "tools").parent_guid)
    assert.are.equal(folder_named(sln, "build").guid, folder_named(sln, "ci").parent_guid)
  end)
end)

describe("solution_edit helpers", function()
  it("writes paths relative to the solution, with .. when outside", function()
    assert.are.equal("build/a.cake", edit.relative("/r/sln", "/r/sln/build/a.cake"))
    assert.are.equal("../shared/x.props", edit.relative("/r/sln", "/r/shared/x.props"))
  end)

  it("guesses a folder's directory from its files, or from its name", function()
    local sln = {
      dir = "/r",
      by_guid = { P = { name = "build", guid = "P" } },
    }
    local with_files = { name = "x", solution_items = { { path = "/r/eng/a.props" }, { path = "/r/eng/ci/b.yml" } } }
    assert.are.equal("/r/eng", edit.directory(sln, with_files))
    local nested = { name = "ci", parent_guid = "P", solution_items = {} }
    assert.are.equal("/r/build/ci", edit.directory(sln, nested))
  end)
end)

-- `n` and `a` through commands.lua, with neo-tree standing in
describe("n and a on the solution and its folders", function()
  local commands, saved, inputs, selects, messages, opened, focused

  local function stub(tbl, key, value)
    table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
    tbl[key] = value
  end

  local function state_on(sln_path, extra)
    local node = { extra = extra, get_parent_id = function() end }
    return {
      dotnet_sln = sln_path,
      path = vim.fn.fnamemodify(sln_path, ":h"),
      tree = {
        get_node = function()
          return node
        end,
      },
    }
  end

  before_each(function()
    saved, inputs, selects, messages, opened, focused = {}, {}, {}, {}, {}, {}
    package.loaded["neo-tree.sources.common.commands"] = {}
    package.loaded["neo-tree.sources.manager"] = {
      navigate = function(_, _, _, callback)
        callback()
      end,
    }
    package.loaded["neo-tree.utils"] = {
      open_file = function(_, path)
        table.insert(opened, path)
      end,
    }
    package.loaded["dotnet-tree.commands"] = nil
    stub(require("dotnet-tree.reveal"), "focus", function(_, id)
      table.insert(focused, id)
    end)
    stub(vim.ui, "input", function(opts, on_confirm)
      local answer = table.remove(inputs, 1)
      if type(answer) == "function" then
        answer = answer(opts)
      end
      on_confirm(answer)
    end)
    stub(vim.ui, "select", function(_, _, on_choice)
      on_choice(table.remove(selects, 1))
    end)
    stub(vim, "notify", function(msg)
      table.insert(messages, msg)
    end)
    commands = require("dotnet-tree.commands")
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i].tbl[saved[i].key] = saved[i].value
    end
    for _, name in ipairs({
      "neo-tree.sources.common.commands",
      "neo-tree.sources.manager",
      "neo-tree.utils",
      "dotnet-tree.commands",
    }) do
      package.loaded[name] = nil
    end
  end)

  it("creates a solution folder with n on the solution, and puts the cursor on it", function()
    local _, path = solution_file("All.slnx", "<Solution>\n</Solution>\n")
    inputs = { "tools" }
    commands.new_file(state_on(path, { kind = "solution" }))
    assert.truthy(folder_named(parse(path), "tools"))
    assert.are.same({ "dotnet:slnfolder:slnxfolder:/tools/" }, focused)
  end)

  it("creates a file in a folder's directory with n, adds it and opens it", function()
    local dir, path = solution_file("All.sln", vs_sln("\r\n"))
    local build = folder_named(parse(path), "build")
    local offered
    selects = { "file" }
    inputs = {
      function(opts)
        offered = opts.default
        return dir .. "/build/version.props"
      end,
    }
    commands.new_file(state_on(path, { kind = "sln_folder", guid = build.guid }))
    assert.matches("build/$", offered)
    assert.are.equal(1, vim.fn.filereadable(dir .. "/build/version.props"))
    assert.are.same(
      { dir .. "/build/build.cake", dir .. "/build/version.props" },
      items_of(folder_named(parse(path), "build"))
    )
    assert.are.same({ dir .. "/build/version.props" }, opened)
    assert.are.same({ "dotnet:slnitem:" .. build.guid .. ":" .. dir .. "/build/version.props" }, focused)
  end)

  it("creates a subfolder with n on a folder", function()
    local _, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    selects = { "solution folder" }
    inputs = { "ci" }
    commands.new_file(state_on(path, { kind = "sln_folder", guid = build.guid }))
    assert.are.equal(build.guid, folder_named(parse(path), "ci").parent_guid)
  end)

  it("acts on the folder of a solution item under the cursor", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    touch(dir .. "/build/tools.json")
    inputs = { dir .. "/build/tools.json" }
    commands.add(state_on(path, { kind = "file", sln_folder = build.guid }))
    assert.are.same(
      { dir .. "/build/build.cake", dir .. "/build/tools.json" },
      items_of(folder_named(parse(path), "build"))
    )
  end)

  it("refuses with a reason, and leaves nothing behind", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    local before = bytes(path)
    -- n on a file that is already there points to a
    selects = { "file" }
    inputs = { dir .. "/build/build.cake" }
    touch(dir .. "/build/build.cake")
    commands.new_file(state_on(path, { kind = "sln_folder", guid = build.guid }))
    -- a on a file that is not there
    inputs = { dir .. "/build/missing.txt" }
    commands.add(state_on(path, { kind = "sln_folder", guid = build.guid }))
    -- a on the solution itself
    commands.add(state_on(path, { kind = "solution" }))
    assert.are.equal(before, bytes(path))
    assert.matches("press `a` to add it", messages[1], 1, true)
    assert.matches("no file at", messages[2], 1, true)
    assert.matches("`n` on the solution creates one", messages[3], 1, true)
  end)
end)
