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

describe("solution_edit on solution files written by hand", function()
  -- Folders "a", "b" and "c" each listing a file; "c" nested in "b"; GUIDs in
  -- lowercase; no line break after EndGlobal
  local function three_folders()
    return table.concat({
      ('Project("{%s}") = "a", "a", "{aaaaaaaa-0000-4000-8000-000000000001}"'):format(FOLDER:lower()),
      "\tProjectSection(SolutionItems) = preProject",
      "\t\ta.txt = a.txt",
      "\tEndProjectSection",
      "EndProject",
      ('Project("{%s}") = "b", "b", "{bbbbbbbb-0000-4000-8000-000000000002}"'):format(FOLDER:lower()),
      "\tProjectSection(SolutionItems) = preProject",
      "\t\tb.txt = b.txt",
      "\tEndProjectSection",
      "EndProject",
      ('Project("{%s}") = "c", "c", "{cccccccc-0000-4000-8000-000000000003}"'):format(FOLDER:lower()),
      "\tProjectSection(SolutionItems) = preProject",
      "\t\tc.txt = c.txt",
      "\tEndProjectSection",
      "EndProject",
      "Global",
      "\tGlobalSection(NestedProjects) = preSolution",
      "\t\t{cccccccc-0000-4000-8000-000000000003} = {bbbbbbbb-0000-4000-8000-000000000002}",
      "\tEndGlobalSection",
      "EndGlobal",
    }, "\n")
  end

  it("adds to the folder asked for, between others, whatever the case of its GUID", function()
    local dir, path = solution_file("All.sln", three_folders())
    local file = touch(dir .. "/b2.txt")
    assert.is_true(edit.add_file(path, folder_named(parse(path), "b"), file))
    local sln = parse(path)
    assert.are.same({ dir .. "/a.txt" }, items_of(folder_named(sln, "a")))
    assert.are.same({ dir .. "/b.txt", file }, items_of(folder_named(sln, "b")))
    assert.are.same({ dir .. "/c.txt" }, items_of(folder_named(sln, "c")))
    assert.are.equal(folder_named(sln, "b").guid, folder_named(sln, "c").parent_guid)
    local _, _, d = edit.add_folder(path, folder_named(sln, "b"), "d", { "c" })
    assert.are.equal(folder_named(parse(path), "b").guid, parse(path).by_guid[d].parent_guid)
    assert.matches("EndGlobal$", bytes(path), "no line break added at the end")
  end)

  it("adds to a folder whose Project line is the last of the file", function()
    local dir, path = solution_file(
      "All.sln",
      ('Project("{%s}") = "z", "z", "{AB000000-0000-4000-8000-000000000001}"\nEndProject'):format(FOLDER)
    )
    local text = bytes(path):gsub("\nEndProject$", "")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
    local ok, err = edit.add_file(
      path,
      folder_named(parse(path), "z") or { guid = "AB000000-0000-4000-8000-000000000001", name = "z" },
      touch(dir .. "/z.txt")
    )
    -- With no EndProject the block cannot be found: refused, not written into the wrong place
    assert.is_nil(ok)
    assert.matches("EndProject", err, 1, true)
    assert.are.equal(text, bytes(path))
  end)

  it("refuses to nest a folder in a solution with no Global section, and writes nothing", function()
    local _, path = solution_file(
      "All.sln",
      ('Project("{%s}") = "a", "a", "{AB000000-0000-4000-8000-000000000001}"\nEndProject\n'):format(FOLDER)
    )
    local before = bytes(path)
    local ok, err = edit.add_folder(path, folder_named(parse(path), "a"), "b", {})
    assert.is_nil(ok)
    assert.matches("no Global section", err, 1, true)
    assert.are.equal(before, bytes(path))
    assert.is_true(edit.add_folder(path, nil, "root", { "a" }))
    assert.truthy(folder_named(parse(path), "root"))
  end)

  it("writes into the file a symlink points to, keeping the link", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local link = dir .. "/Link.sln"
    assert(vim.uv.fs_symlink(path, link))
    assert.is_true(edit.add_folder(link, nil, "tools", { "build", "docs" }))
    assert.are.equal("link", vim.uv.fs_lstat(link).type)
    assert.truthy(folder_named(parse(path), "tools"))
  end)

  it("refuses a read-only solution file and leaves it as it was", function()
    local _, path = solution_file("All.sln", vs_sln("\n"))
    local before = bytes(path)
    vim.uv.fs_chmod(path, tonumber("444", 8))
    local ok, err = edit.add_folder(path, nil, "tools", {})
    vim.uv.fs_chmod(path, tonumber("644", 8))
    assert.is_nil(ok)
    assert.matches("read-only", err, 1, true)
    assert.are.equal(before, bytes(path))
  end)

  it("refuses a file already listed under another spelling of its path", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    touch(dir .. "/build/build.cake")
    local alias = dir .. "/alias"
    assert(vim.uv.fs_symlink(dir .. "/build", alias))
    local ok, err = edit.add_file(path, folder_named(parse(path), "build"), alias .. "/build.cake")
    assert.is_nil(ok)
    assert.matches("already in build", err, 1, true)
  end)
end)

describe("solution_edit on .slnx written by hand", function()
  local function count(text, pattern)
    local _, n = text:gsub(pattern, "")
    return n
  end

  it("keeps a solution on one line valid", function()
    local dir, path = solution_file("All.slnx", '<Solution><Folder Name="/a/"></Folder></Solution>')
    assert.is_true(edit.add_folder(path, nil, "bb", { "a" }))
    assert.is_true(edit.add_file(path, folder_named(parse(path), "a"), touch(dir .. "/a.txt")))
    local text = bytes(path)
    assert.matches("^<Solution>", text)
    assert.matches("</Solution>$", text)
    local sln = parse(path)
    assert.is_nil(folder_named(sln, "bb").parent_guid)
    assert.are.same({ dir .. "/a.txt" }, items_of(folder_named(sln, "a")))
    assert.truthy(text:find('<Folder Name="/a/">.-<File Path="a.txt" />.-</Folder>'))
  end)

  it("puts a new folder at the root after a folder that closed itself on the same line", function()
    local _, path = solution_file("All.slnx", '<Solution><Folder Name="/a/" /></Solution>')
    assert.is_true(edit.add_folder(path, nil, "bb", { "a" }))
    assert.is_nil(folder_named(parse(path), "bb").parent_guid)
  end)

  it("finds a folder named relative to the one it sits in, instead of writing it twice", function()
    local dir, path = solution_file(
      "All.slnx",
      '<Solution>\n  <Folder Name="/a/">\n    <Folder Name="b">\n    </Folder>\n  </Folder>\n</Solution>\n'
    )
    local b = folder_named(parse(path), "b")
    assert.are.equal("/a/b/", b._folderpath)
    assert.is_true(edit.add_file(path, b, touch(dir .. "/x.txt")))
    local text = bytes(path)
    assert.are.equal(2, count(text, "<Folder "))
    assert.truthy(text:find('<Folder Name="b">\n      <File Path="x.txt" />\n    </Folder>', 1, true))
  end)

  it("adds to the outer of two nested folders after the inner one closes", function()
    local dir, path = solution_file(
      "All.slnx",
      '<Solution>\n  <Folder Name="/build/">\n    <Folder Name="/build/ci/">\n      <File Path="ci.yml" />\n    </Folder>\n  </Folder>\n</Solution>\n'
    )
    assert.is_true(edit.add_file(path, folder_named(parse(path), "build"), touch(dir .. "/b.props")))
    assert.truthy(bytes(path):find('    </Folder>\n    <File Path="b.props" />\n  </Folder>', 1, true))
    assert.are.same({ dir .. "/b.props" }, items_of(folder_named(parse(path), "build")))
    assert.are.same({ dir .. "/ci.yml" }, items_of(folder_named(parse(path), "ci")))
  end)

  it("finds a folder whose name it escaped", function()
    local dir, path = solution_file("All.slnx", "<Solution>\n</Solution>\n")
    assert.is_true(edit.add_folder(path, nil, "R&D", {}))
    assert.is_true(edit.add_file(path, folder_named(parse(path), "R&D"), touch(dir .. "/plan.md")))
    local text = bytes(path)
    assert.are.equal(1, count(text, "<Folder "))
    assert.are.same({ dir .. "/plan.md" }, items_of(folder_named(parse(path), "R&D")))
  end)
end)

describe("tree nodes of solution folders", function()
  local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures"

  -- The commands find their target through these fields, and the ids they put
  -- the cursor on are built the same way
  for _, name in ipairs({ "Sample.sln", "Sample.slnx" }) do
    it("tags folders and their items in " .. name, function()
      local tree = assert(require("dotnet-tree.tree").build(FIXTURES .. "/" .. name))
      local sln = parse(FIXTURES .. "/" .. name)
      local checked = 0
      local function walk(node)
        if node.extra.kind == "sln_folder" then
          local folder = sln.by_guid[node.extra.guid]
          assert.truthy(folder, node.id)
          assert.are.equal("dotnet:slnfolder:" .. folder.guid, node.id)
          for _, item in ipairs(folder.solution_items) do
            local child
            for _, c in ipairs(node.children) do
              if c.path == item.path then
                child = c
              end
            end
            assert.are.equal(folder.guid, child.extra.sln_folder)
            assert.are.equal("dotnet:slnitem:" .. folder.guid .. ":" .. item.path, child.id)
            checked = checked + 1
          end
        end
        for _, c in ipairs(node.children or {}) do
          walk(c)
        end
      end
      walk(tree[1])
      assert.are.equal(1, checked)
    end)
  end
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

  local function said(text)
    for _, m in ipairs(messages) do
      if m:find(text, 1, true) then
        return true
      end
    end
    return false
  end

  it("says what it did", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    touch(dir .. "/build/tools.json")
    inputs = { dir .. "/build/tools.json", "tools" }
    commands.add(state_on(path, { kind = "sln_folder", guid = build.guid }))
    commands.new_file(state_on(path, { kind = "solution" }))
    assert.is_true(said("tools.json to build"), vim.inspect(messages))
    assert.is_true(said("created solution folder tools"), vim.inspect(messages))
  end)

  it("points n on a file that is already there to a", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    local before = bytes(path)
    touch(dir .. "/build/build.cake")
    selects = { "file" }
    inputs = { dir .. "/build/build.cake" }
    commands.new_file(state_on(path, { kind = "sln_folder", guid = build.guid }))
    assert.are.equal(before, bytes(path))
    assert.is_true(said("press `a` to add it"))
  end)

  -- The default answer is the folder's directory: accepting it names no file
  it("creates nothing when the answer is a directory", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local docs = folder_named(parse(path), "docs")
    local before = bytes(path)
    selects = { "file" }
    inputs = {
      function(opts)
        return opts.default
      end,
    }
    commands.new_file(state_on(path, { kind = "sln_folder", guid = docs.guid }))
    assert.are.equal(before, bytes(path))
    assert.is_nil(vim.uv.fs_stat(dir .. "/docs"))
    assert.is_true(said("give the file a name"))
  end)

  it("removes the file and the directories it made when the add fails", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# edited" })
    selects = { "file" }
    inputs = { dir .. "/build/deep/er/new.props" }
    commands.new_file(state_on(path, { kind = "sln_folder", guid = build.guid }))
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(vim.uv.fs_stat(dir .. "/build/deep"))
    assert.is_true(said("unsaved changes"))
    assert.are.same({}, opened)
  end)

  it("refuses a with a path that is not a file", function()
    local dir, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    local before = bytes(path)
    inputs = { dir .. "/build/missing.txt" }
    commands.add(state_on(path, { kind = "sln_folder", guid = build.guid }))
    vim.fn.mkdir(dir .. "/build/sub", "p")
    inputs = { dir .. "/build/sub" }
    commands.add(state_on(path, { kind = "sln_folder", guid = build.guid }))
    assert.are.equal(before, bytes(path))
    assert.is_true(said("no file at"))
    assert.is_true(said("is a directory"))
  end)

  it("explains a on the solution, and a folder that is gone", function()
    local _, path = solution_file("All.sln", vs_sln("\n"))
    commands.add(state_on(path, { kind = "solution" }))
    commands.add(state_on(path, { kind = "sln_folder", guid = "00000000-0000-0000-0000-000000000000" }))
    assert.is_true(said("`n` on the solution creates one"))
    assert.is_true(said("no longer in the solution file; press R"))
  end)

  it("acts on the folder of a solution item with n too", function()
    local _, path = solution_file("All.sln", vs_sln("\n"))
    local build = folder_named(parse(path), "build")
    selects = { "solution folder" }
    inputs = { "ci" }
    commands.new_file(state_on(path, { kind = "file", sln_folder = build.guid }))
    assert.are.equal(build.guid, folder_named(parse(path), "ci").parent_guid)
  end)

  -- A project, or a file in one, is not a solution target: the old `a` and `n`
  it("leaves a and n on a project to packages, references and templates", function()
    local _, path = solution_file("All.sln", vs_sln("\n"))
    local before = bytes(path)
    local offered
    vim.ui.select = function(items)
      offered = items
    end
    local project = state_on(path, { kind = "project", project = { path = "/src/Api/Api.csproj" } })
    project.tree:get_node().name = "Api"
    commands.add(project)
    assert.are.same({ "package", "reference" }, offered)
    commands.new_file(project)
    assert.are.same({ "class", "interface", "record", "struct", "enum" }, offered)
    assert.are.equal(before, bytes(path))
  end)
end)
