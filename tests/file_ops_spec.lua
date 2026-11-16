-- Renaming, moving, copying and deleting from the tree (#50).

local edit = require("dotnet-tree.solution_edit")
local solution = require("dotnet-tree.parser.solution")

local FOLDER = "2150E333-8FDC-42A3-9474-1A3956D46DE8"

local function tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
  return path
end

local function bytes(path)
  local f = assert(io.open(path, "rb"))
  local content = f:read("*a")
  f:close()
  return content
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

local function sln_text(eol)
  return table.concat({
    ('Project("{%s}") = "build", "build", "{C8AD7A75-9928-4BAD-BD6E-305447D64F04}"'):format(FOLDER),
    "\tProjectSection(SolutionItems) = preProject",
    "\t\tbuild\\build.cake = build\\build.cake",
    "\t\tbuild\\version.props = build\\version.props",
    "\tEndProjectSection",
    "EndProject",
    "Global",
    "EndGlobal",
    "",
  }, eol)
end

local SLNX = table.concat({
  "<Solution>",
  '  <Folder Name="/build/">',
  '    <File Path="build/build.cake" />',
  '    <File Path="build/version.props" />',
  "  </Folder>",
  "</Solution>",
  "",
}, "\n")

describe("solution items renamed or taken off", function()
  for _, case in ipairs({
    { name = "All.sln", text = sln_text("\r\n") },
    { name = "All.slnx", text = SLNX },
  }) do
    it("takes an item off its folder in " .. case.name .. ", leaving the others and the file", function()
      local dir = tempdir()
      local path = write(dir .. "/" .. case.name, case.text)
      local cake = write(dir .. "/build/build.cake", "x")
      local build = folder_named(parse(path), "build")
      assert.is_true(edit.remove_item(path, build, cake))
      assert.are.same({ dir .. "/build/version.props" }, items_of(folder_named(parse(path), "build")))
      assert.are.equal(1, vim.fn.filereadable(cake))
      assert.is_nil(bytes(path):find("build.cake", 1, true))
      if case.name:match("sln$") then
        assert.is_nil(bytes(path):gsub("\r\n", ""):find("\n"), "CRLF kept")
      end
    end)

    it("writes an item's new path in " .. case.name, function()
      local dir = tempdir()
      local path = write(dir .. "/" .. case.name, case.text)
      local build = folder_named(parse(path), "build")
      local new = write(dir .. "/eng/build.cake", "x")
      assert.is_true(edit.rename_item(path, build, dir .. "/build/build.cake", new))
      assert.are.same({ new, dir .. "/build/version.props" }, items_of(folder_named(parse(path), "build")))
    end)

    it("says when the item is not listed in " .. case.name, function()
      local dir = tempdir()
      local path = write(dir .. "/" .. case.name, case.text)
      local before = bytes(path)
      local ok, err = edit.remove_item(path, folder_named(parse(path), "build"), dir .. "/build/other.txt")
      assert.is_nil(ok)
      assert.matches("not listed in build", err, 1, true)
      assert.are.equal(before, bytes(path))
    end)
  end
end)

describe("lsp_files", function()
  local lsp_files = require("dotnet-tree.lsp_files")
  local saved, requests, notifications, applied

  local function stub(tbl, key, value)
    table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
    tbl[key] = value
  end

  local function client(name, capabilities, result)
    return {
      name = name,
      offset_encoding = "utf-16",
      server_capabilities = { workspace = { fileOperations = capabilities } },
      request_sync = function(_, method, params)
        table.insert(requests, { name = name, method = method, params = params })
        return { result = result }
      end,
      notify = function(_, method, params)
        table.insert(notifications, { name = name, method = method, params = params })
      end,
    }
  end

  before_each(function()
    saved, requests, notifications, applied = {}, {}, {}, {}
    stub(vim.lsp.util, "apply_workspace_edit", function(e)
      table.insert(applied, e)
    end)
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i].tbl[saved[i].key] = saved[i].value
    end
    package.loaded["lsp-file-operations"] = nil
  end)

  local CS = { filters = { { pattern = { glob = "**/*.cs", matches = "file" } } } }

  it("asks the servers that want to know, applies their edits, and tells them after", function()
    local edit_result = { changes = {} }
    stub(vim.lsp, "get_clients", function()
      return {
        client("roslyn", { willRename = CS, didRename = CS }, edit_result),
        client("other", {}, nil),
      }
    end)
    local changed = lsp_files.will_rename("/src/Api/Foo.cs", "/src/Api/Bar.cs")
    lsp_files.did_rename("/src/Api/Foo.cs", "/src/Api/Bar.cs")
    assert.are.same({ "roslyn" }, changed)
    assert.are.equal(1, #requests)
    assert.are.equal("workspace/willRenameFiles", requests[1].method)
    assert.are.equal(vim.uri_from_fname("/src/Api/Bar.cs"), requests[1].params.files[1].newUri)
    assert.are.same({ edit_result }, applied)
    assert.are.same(
      { "workspace/didRenameFiles" },
      vim.tbl_map(function(n)
        return n.method
      end, notifications)
    )
  end)

  it("asks nothing about a file its filters leave out", function()
    stub(vim.lsp, "get_clients", function()
      return { client("roslyn", { willRename = CS }, {}) }
    end)
    assert.are.same({}, lsp_files.will_rename("/src/Api/appsettings.json", "/src/Api/app.json"))
    assert.are.same({}, requests)
  end)

  -- That plugin listens to neo-tree's events and would apply the same edits
  it("steps aside when nvim-lsp-file-operations is loaded", function()
    package.loaded["lsp-file-operations"] = {}
    stub(vim.lsp, "get_clients", function()
      return { client("roslyn", { willRename = CS, didRename = CS }, {}) }
    end)
    lsp_files.will_rename("/src/Api/Foo.cs", "/src/Api/Bar.cs")
    lsp_files.did_rename("/src/Api/Foo.cs", "/src/Api/Bar.cs")
    assert.are.same({}, requests)
    assert.are.same({}, notifications)
  end)
end)

-- The keys through commands.lua, with neo-tree's file operations standing in
-- by doing the same on disk
describe("file operations from the tree", function()
  local commands, saved, inputs, confirms, messages, terminals, lsp_calls, focused
  local dir, project, sln_path

  local function stub(tbl, key, value)
    table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
    tbl[key] = value
  end

  -- A state whose cursor is on `node`, inside the project node
  local function state_on(node)
    local project_node = {
      name = "Api",
      extra = { kind = "project", project = { path = project } },
      get_parent_id = function() end,
    }
    node.get_parent_id = node.get_parent_id or function()
      return "project"
    end
    return {
      dotnet_sln = sln_path,
      path = dir,
      tree = {
        get_node = function(_, id)
          if id == "project" then
            return project_node
          end
          return id and nil or node
        end,
      },
    }
  end

  local function said(text)
    for _, m in ipairs(messages) do
      if m:find(text, 1, true) then
        return true
      end
    end
    return false
  end

  before_each(function()
    saved, inputs, confirms, messages, terminals, lsp_calls, focused = {}, {}, {}, {}, {}, {}, {}
    dir = tempdir()
    project = write(dir .. "/src/Api/Api.csproj", "<Project />")
    write(dir .. "/src/Api/Foo.cs", "class Foo {}")
    sln_path = write(dir .. "/All.sln", sln_text("\n"))
    write(dir .. "/build/build.cake", "x")

    package.loaded["neo-tree.sources.common.commands"] = {}
    package.loaded["neo-tree.sources.manager"] = {
      navigate = function(_, _, _, callback)
        callback()
      end,
    }
    package.loaded["neo-tree.ui.inputs"] = {
      confirm = function(message, cb)
        table.insert(confirms, message)
        cb(true)
      end,
    }
    package.loaded["neo-tree.sources.filesystem.lib.fs_actions"] = {
      move_node = function(src, dest, cb)
        vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
        assert(vim.uv.fs_rename(src, dest))
        cb(src, dest)
      end,
      copy_node = function(src, dest, cb)
        assert(vim.uv.fs_copyfile(src, dest))
        cb(src, dest)
      end,
      delete_node = function(path, cb)
        table.insert(confirms, "delete " .. path)
        vim.fn.delete(path, "rf")
        cb(path)
      end,
      create_directory = function(in_dir, cb, root)
        local name = table.remove(inputs, 1)
        vim.fn.mkdir(root .. "/" .. name, "p")
        cb(in_dir .. "/" .. name)
      end,
    }
    package.loaded["dotnet-tree.lsp_files"] = {
      will_rename = function(src, dest)
        table.insert(lsp_calls, { "will", src, dest })
        return { "roslyn" }
      end,
      did_rename = function(src, dest)
        table.insert(lsp_calls, { "did", src, dest })
      end,
    }
    package.loaded["dotnet-tree.commands"] = nil
    stub(require("dotnet-tree.terminal"), "open", function(cmd, label)
      table.insert(terminals, { cmd = cmd, label = label })
    end)
    stub(require("dotnet-tree.reveal"), "focus", function(_, id)
      table.insert(focused, id)
    end)
    stub(vim.ui, "input", function(_, on_confirm)
      on_confirm(table.remove(inputs, 1))
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
      "neo-tree.ui.inputs",
      "neo-tree.sources.filesystem.lib.fs_actions",
      "dotnet-tree.lsp_files",
      "dotnet-tree.commands",
    }) do
      package.loaded[name] = nil
    end
    vim.fn.delete(dir, "rf")
  end)

  local function file(path)
    return { name = vim.fn.fnamemodify(path, ":t"), path = path, extra = { kind = "file" } }
  end

  it("renames a file, telling the language servers before and after", function()
    inputs = { "Bar.cs" }
    commands.rename(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Bar.cs"))
    assert.are.same({
      { "will", dir .. "/src/Api/Foo.cs", dir .. "/src/Api/Bar.cs" },
      { "did", dir .. "/src/Api/Foo.cs", dir .. "/src/Api/Bar.cs" },
    }, lsp_calls)
    assert.is_true(said("code updated by roslyn"))
  end)

  it("refuses a rename over another file, or to a path", function()
    write(dir .. "/src/Api/Bar.cs", "")
    inputs = { "Bar.cs" }
    commands.rename(state_on(file(dir .. "/src/Api/Foo.cs")))
    inputs = { "../Foo.cs" }
    commands.rename(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Foo.cs"))
    assert.is_true(said("already exists"))
    assert.is_true(said("`m` moves"))
    assert.are.same({}, lsp_calls)
  end)

  it("moves a file into a folder, keeping its name", function()
    vim.fn.mkdir(dir .. "/src/Api/Models", "p")
    inputs = { dir .. "/src/Api/Models/" }
    commands.move(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Models/Foo.cs"))
  end)

  it("copies and pastes into the folder under the cursor, and cut moves", function()
    vim.fn.mkdir(dir .. "/src/Api/Models", "p")
    local models = { name = "Models", path = dir .. "/src/Api/Models", extra = { kind = "folder" } }
    commands.copy_to_clipboard(state_on(file(dir .. "/src/Api/Foo.cs")))
    local state = state_on(models)
    state.dotnet_clipboard = nil
    commands.paste_from_clipboard(state)
    assert.is_true(said("nothing to paste"))
    local copied = state_on(file(dir .. "/src/Api/Foo.cs"))
    commands.copy_to_clipboard(copied)
    local target = state_on(models)
    target.dotnet_clipboard = copied.dotnet_clipboard
    commands.paste_from_clipboard(target)
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Foo.cs"))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Models/Foo.cs"))
    write(dir .. "/src/Api/Baz.cs", "")
    local cut = state_on(file(dir .. "/src/Api/Baz.cs"))
    commands.cut_to_clipboard(cut)
    target.dotnet_clipboard = cut.dotnet_clipboard
    commands.paste_from_clipboard(target)
    assert.are.equal(0, vim.fn.filereadable(dir .. "/src/Api/Baz.cs"))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Models/Baz.cs"))
    assert.is_nil(target.dotnet_clipboard, "a cut is pasted once")
  end)

  it("creates a folder in a project", function()
    inputs = { "Services" }
    commands.add_directory(state_on({ name = "Api", extra = { kind = "project", project = { path = project } } }))
    assert.are.equal(1, vim.fn.isdirectory(dir .. "/src/Api/Services"))
  end)

  it("deletes a file of a project", function()
    commands.delete(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.equal(0, vim.fn.filereadable(dir .. "/src/Api/Foo.cs"))
  end)

  it("takes a solution item off its folder, keeping the file, and moves it with the solution", function()
    local build = folder_named(parse(sln_path), "build")
    local cake = dir .. "/build/build.cake"
    local item = { name = "build.cake", path = cake, extra = { kind = "file", sln_folder = build.guid } }
    inputs = { "make.cake" }
    commands.rename(state_on(item))
    assert.are.same(
      { dir .. "/build/make.cake", dir .. "/build/version.props" },
      items_of(folder_named(parse(sln_path), "build"))
    )
    item.path = dir .. "/build/make.cake"
    commands.delete(state_on(item))
    assert.are.same({ dir .. "/build/version.props" }, items_of(folder_named(parse(sln_path), "build")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/build/make.cake"))
    assert.matches("The file stays on disk", confirms[1], 1, true)
  end)

  it("removes a package, a reference and a project with dotnet, after asking", function()
    local package = { name = "Serilog", extra = { kind = "package", package = { name = "Serilog" } } }
    local reference = { name = "Core", path = dir .. "/src/Core/Core.csproj", extra = { kind = "project_reference" } }
    local project_node = {
      name = "Api",
      extra = { kind = "project", project = { path = project } },
      get_parent_id = function() end,
    }
    commands.delete(state_on(package))
    commands.delete(state_on(reference))
    local state = state_on(project_node)
    state.tree.get_node = function()
      return project_node
    end
    commands.delete(state)
    assert.are.same(
      {
        "dotnet remove " .. vim.fn.shellescape(project) .. " package " .. vim.fn.shellescape("Serilog"),
        "dotnet remove " .. vim.fn.shellescape(project) .. " reference " .. vim.fn.shellescape(reference.path),
        "dotnet sln " .. vim.fn.shellescape(sln_path) .. " remove " .. vim.fn.shellescape(project),
      },
      vim.tbl_map(function(t)
        return t.cmd
      end, terminals)
    )
    assert.are.equal(3, #confirms)
    assert.matches("files stay on disk", confirms[3], 1, true)
  end)

  it("does nothing a confirmation turns down", function()
    package.loaded["neo-tree.ui.inputs"].confirm = function(_, cb)
      cb(false)
    end
    commands.delete(state_on({ name = "Serilog", extra = { kind = "package", package = { name = "Serilog" } } }))
    assert.are.same({}, terminals)
  end)

  it("refuses what has nothing on disk, with the reason", function()
    for _, node in ipairs({
      { name = "Serilog", extra = { kind = "package", package = { name = "Serilog" } } },
      { name = "Packages", extra = { kind = "packages" } },
      { name = "build", extra = { kind = "sln_folder", guid = "X" } },
      { name = "All.sln", extra = { kind = "solution" } },
      file(project),
    }) do
      commands.rename(state_on(node))
    end
    assert.is_true(said("cannot rename Serilog: a package is not a file"))
    assert.is_true(said("cannot rename Packages: this groups the packages"))
    assert.is_true(said("cannot rename build: a solution folder only exists"))
    assert.is_true(said("cannot rename All.sln: the solution file"))
    assert.is_true(said("cannot rename Api.csproj: the project file goes with its project"))
    commands.delete(state_on({ name = "Packages", extra = { kind = "packages" } }))
    assert.is_true(said("cannot delete Packages"))
    assert.are.same({}, terminals)
  end)
end)
