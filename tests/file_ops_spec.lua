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

local function display_of(path)
  return vim.fn.fnamemodify(path, ":~:.")
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

  -- `answer` is what request_sync returns: a response, or a function giving
  -- its values (nil and a reason, or an error)
  local function client(name, capabilities, answer)
    return {
      name = name,
      offset_encoding = "utf-16",
      server_capabilities = { workspace = { fileOperations = capabilities } },
      request_sync = function(_, method, params)
        table.insert(requests, { name = name, method = method, params = params })
        if type(answer) == "function" then
          return answer()
        end
        return answer
      end,
      notify = function(_, method, params)
        table.insert(notifications, { name = name, method = method, params = params })
        return true
      end,
    }
  end

  local function edit_of(...)
    local changes = {}
    for _, path in ipairs({ ... }) do
      changes[vim.uri_from_fname(path)] = { { newText = "x", range = {} } }
    end
    return { result = { changes = changes } }
  end

  local messages

  before_each(function()
    saved, requests, notifications, applied, messages = {}, {}, {}, {}, {}
    stub(vim.lsp.util, "apply_workspace_edit", function(e)
      table.insert(applied, e)
    end)
    stub(vim, "notify", function(msg)
      table.insert(messages, msg)
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
    local answer = edit_of("/src/Api/Foo.cs", "/src/Api/Uses.cs")
    stub(vim.lsp, "get_clients", function()
      return {
        client("roslyn", { willRename = CS, didRename = CS }, answer),
        client("other", {}, nil),
      }
    end)
    local edits = lsp_files.will_rename("/src/Api/Foo.cs", "/src/Api/Bar.cs")
    lsp_files.did_rename("/src/Api/Foo.cs", "/src/Api/Bar.cs")
    assert.are.same({ servers = { "roslyn" }, files = 2 }, edits)
    assert.are.equal(1, #requests)
    assert.are.equal("workspace/willRenameFiles", requests[1].method)
    assert.are.equal(vim.uri_from_fname("/src/Api/Bar.cs"), requests[1].params.files[1].newUri)
    assert.are.same({ answer.result }, applied)
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
    assert.are.same({ servers = {}, files = 0 }, lsp_files.will_rename("/src/Api/appsettings.json", "/src/Api/a.json"))
    assert.are.same({}, requests)
  end)

  it("asks about a folder only a server matching folders", function()
    local folder = vim.fn.tempname()
    vim.fn.mkdir(folder, "p")
    local FOLDERS = { filters = { { pattern = { glob = "**", matches = "folder" } } } }
    stub(vim.lsp, "get_clients", function()
      return { client("folders", { willRename = FOLDERS }, edit_of("/x.cs")), client("files", { willRename = CS }, {}) }
    end)
    lsp_files.will_rename(folder, folder .. "-new")
    assert.are.same(
      { "folders" },
      vim.tbl_map(function(r)
        return r.name
      end, requests)
    )
    vim.fn.delete(folder, "rf")
  end)

  it("counts no edits from an answer that changes nothing", function()
    stub(vim.lsp, "get_clients", function()
      return { client("roslyn", { willRename = CS }, { result = { changes = {} } }) }
    end)
    assert.are.same({ servers = {}, files = 0 }, lsp_files.will_rename("/a/Foo.cs", "/a/Bar.cs"))
    assert.are.same({}, applied)
  end)

  it("says why a server was not heard, and goes on with the others", function()
    stub(vim.lsp, "get_clients", function()
      return {
        client("slow", { willRename = CS }, function()
          return nil, "timeout"
        end),
        client("refusing", { willRename = CS }, { err = { message = "boom" } }),
        client("broken", { willRename = CS }, function()
          error("crashed")
        end),
        client("good", { willRename = CS }, edit_of("/a/Foo.cs")),
      }
    end)
    local edits = lsp_files.will_rename("/a/Foo.cs", "/a/Bar.cs")
    assert.are.same({ "good" }, edits.servers)
    local text = table.concat(messages, "\n")
    assert.matches("slow was not asked about renaming Foo.cs: it did not answer in time", text, 1, true)
    assert.matches("refusing refused renaming Foo.cs: boom", text, 1, true)
    assert.matches("broken failed on renaming Foo.cs", text, 1, true)
  end)

  it("stops when the edits cannot be applied", function()
    stub(vim.lsp.util, "apply_workspace_edit", function()
      error("bad range")
    end)
    stub(vim.lsp, "get_clients", function()
      return { client("roslyn", { willRename = CS }, edit_of("/a/Foo.cs")) }
    end)
    local edits = lsp_files.will_rename("/a/Foo.cs", "/a/Bar.cs")
    assert.matches("roslyn's edits for renaming Foo.cs could not be applied", edits.err, 1, true)
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
      create_node = function(in_dir, cb, root)
        local name = table.remove(inputs, 1)
        local dest = root .. "/" .. name
        if name:sub(-1) == "/" then
          vim.fn.mkdir(dest, "p")
        else
          write(dest, "")
        end
        cb(in_dir .. "/" .. name)
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
        return { servers = { "roslyn" }, files = 2 }
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
    return {
      name = vim.fn.fnamemodify(path, ":t"),
      path = path,
      extra = { kind = "file" },
      get_parent_id = function()
        return "project"
      end,
    }
  end

  it("renames a file, telling the language servers before and after", function()
    inputs = { "Bar.cs" }
    commands.rename(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Bar.cs"))
    assert.are.same({
      { "will", dir .. "/src/Api/Foo.cs", dir .. "/src/Api/Bar.cs" },
      { "did", dir .. "/src/Api/Foo.cs", dir .. "/src/Api/Bar.cs" },
    }, lsp_calls)
    assert.is_true(said("2 files edited by roslyn, not saved yet: :wa"))
    assert.is_true(said("renamed Foo.cs to Bar.cs ("), "names only, within one folder")
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

  it("adds a file of any kind with a, or a folder when the name ends in /", function()
    inputs = { "appsettings.Development.json" }
    commands.add(state_on(file(dir .. "/src/Api/Foo.cs")))
    inputs = { "Views/" }
    commands.add(state_on({ name = "Api", extra = { kind = "project", project = { path = project } } }))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/appsettings.Development.json"))
    assert.are.equal(1, vim.fn.isdirectory(dir .. "/src/Api/Views"))
  end)

  it("adds a package or a reference with a on their groups, as ,a does", function()
    local offered
    stub(vim.ui, "select", function(items)
      offered = items
    end)
    local called = {}
    stub(require("dotnet-tree.nuget"), "open", function(kind)
      table.insert(called, kind)
      return true
    end)
    commands.add(state_on({ name = "Packages", extra = { kind = "packages" } }))
    assert.are.same({ "packages" }, called)
    commands.add_package_or_reference(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.same({ "package", "reference" }, offered)
  end)

  it("renames keeping the extension with b, and copies to a path with c", function()
    inputs = { "Bar" }
    commands.rename_basename(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Bar.cs"))
    vim.fn.mkdir(dir .. "/src/Api/Models", "p")
    inputs = { dir .. "/src/Api/Models/" }
    commands.copy(state_on(file(dir .. "/src/Api/Bar.cs")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Bar.cs"))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Models/Bar.cs"))
    inputs = { dir .. "/src/Api/Models/" }
    commands.copy(state_on(file(dir .. "/src/Api/Bar.cs")))
    assert.is_true(said("already exists"))
  end)

  -- A selection: files and folders of projects only, with one question
  it("deletes a selection of files and folders after one question", function()
    vim.fn.mkdir(dir .. "/src/Api/Old", "p")
    write(dir .. "/src/Api/Old.cs", "")
    commands.delete_visual(state_on(file(dir .. "/src/Api/Foo.cs")), {
      file(dir .. "/src/Api/Foo.cs"),
      file(dir .. "/src/Api/Old.cs"),
      {
        name = "Old",
        path = dir .. "/src/Api/Old",
        extra = { kind = "folder" },
        get_parent_id = function()
          return "project"
        end,
      },
    })
    assert.are.equal(1, #vim.tbl_filter(function(c)
      return c:find("^Delete ")
    end, confirms))
    assert.are.equal(0, vim.fn.filereadable(dir .. "/src/Api/Foo.cs"))
    assert.are.equal(0, vim.fn.filereadable(dir .. "/src/Api/Old.cs"))
    assert.are.equal(0, vim.fn.isdirectory(dir .. "/src/Api/Old"))
  end)

  it("deletes nothing from a selection that reaches a project's file or a package", function()
    local package = { name = "Serilog", extra = { kind = "package", package = { name = "Serilog" } } }
    commands.delete_visual(state_on(file(dir .. "/src/Api/Foo.cs")), { file(dir .. "/src/Api/Foo.cs"), package })
    commands.delete_visual(state_on(file(dir .. "/src/Api/Foo.cs")), { file(dir .. "/src/Api/Foo.cs"), file(project) })
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Foo.cs"))
    assert.are.equal(1, vim.fn.filereadable(project))
    assert.are.same({}, confirms)
    assert.are.same({}, terminals)
    assert.is_true(said("only files and folders of projects can be deleted together, not Serilog"))
    assert.is_true(said("not Api.csproj"))
  end)

  it("cuts a selection and pastes it all, then forgets it", function()
    vim.fn.mkdir(dir .. "/src/Api/Models", "p")
    write(dir .. "/src/Api/Baz.cs", "")
    local state = state_on(file(dir .. "/src/Api/Foo.cs"))
    commands.cut_to_clipboard_visual(state, { file(dir .. "/src/Api/Foo.cs"), file(dir .. "/src/Api/Baz.cs") })
    local target = state_on({ name = "Models", path = dir .. "/src/Api/Models", extra = { kind = "folder" } })
    target.dotnet_clipboard = state.dotnet_clipboard
    commands.paste_from_clipboard(target)
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Models/Foo.cs"))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Models/Baz.cs"))
    assert.is_nil(target.dotnet_clipboard)
  end)

  it("keeps a cut that did not move, and says why", function()
    local state = state_on(file(dir .. "/src/Api/Foo.cs"))
    commands.cut_to_clipboard(state)
    local same = state_on(file(dir .. "/src/Api/Foo.cs"))
    same.dotnet_clipboard = state.dotnet_clipboard
    commands.paste_from_clipboard(same)
    assert.is_true(said("is already there"))
    assert.truthy(same.dotnet_clipboard, "still there to paste elsewhere")
  end)

  it("says a copied file is gone instead of pasting it", function()
    local state = state_on(file(dir .. "/src/Api/Foo.cs"))
    commands.copy_to_clipboard(state)
    os.remove(dir .. "/src/Api/Foo.cs")
    vim.fn.mkdir(dir .. "/src/Api/Models", "p")
    local target = state_on({ name = "Models", path = dir .. "/src/Api/Models", extra = { kind = "folder" } })
    target.dotnet_clipboard = state.dotnet_clipboard
    commands.paste_from_clipboard(target)
    assert.is_true(said("is no longer there"))
    target.dotnet_clipboard.action = "cut"
    commands.paste_from_clipboard(target)
    assert.are.same({}, lsp_calls, "no language server asked about a file that is gone")
  end)

  -- The servers' edits come before the move, and neo-tree gives up in silence
  it("refuses a move neo-tree would refuse before asking the language servers", function()
    vim.fn.mkdir(dir .. "/src/Api/Models", "p")
    local models = { name = "Models", path = dir .. "/src/Api/Models", extra = { kind = "folder" } }
    inputs = { display_of(dir .. "/src/Api/Models") }
    commands.move(state_on(models))
    assert.is_true(said("cannot move"))
    assert.are.same({}, lsp_calls)
  end)

  it("moves a folder into another, keeping its name", function()
    vim.fn.mkdir(dir .. "/src/Api/Models", "p")
    write(dir .. "/src/Api/Models/Order.cs", "")
    vim.fn.mkdir(dir .. "/src/Api/Domain", "p")
    inputs = { dir .. "/src/Api/Domain/" }
    commands.move(state_on({ name = "Models", path = dir .. "/src/Api/Models", extra = { kind = "folder" } }))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Domain/Models/Order.cs"))
    assert.are.same({ "will", dir .. "/src/Api/Models", dir .. "/src/Api/Domain/Models" }, lsp_calls[1])
  end)

  it("does not move when the language servers' edits could not be applied", function()
    package.loaded["dotnet-tree.lsp_files"].will_rename = function()
      return { servers = {}, files = 0, err = "roslyn's edits could not be applied" }
    end
    inputs = { "Bar.cs" }
    commands.rename(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Foo.cs"))
    assert.is_true(said("roslyn's edits could not be applied; "))
    assert.is_true(said("Foo.cs was not renamed"))
  end)

  -- A file listed as a solution item can be moved through its project too
  it("updates the solution when a solution item moves through its project", function()
    write(dir .. "/src/Api/appsettings.json", "{}")
    local text = bytes(sln_path):gsub(
      "\t\tbuild\\version.props = build\\version.props\n",
      "\t\tbuild\\version.props = build\\version.props\n\t\tsrc\\Api\\appsettings.json = src\\Api\\appsettings.json\n"
    )
    write(sln_path, text)
    inputs = { "appsettings.Base.json" }
    commands.rename(state_on(file(dir .. "/src/Api/appsettings.json")))
    assert.truthy(bytes(sln_path):find("src\\Api\\appsettings.Base.json", 1, true))
    assert.is_nil(bytes(sln_path):find("src\\Api\\appsettings.json", 1, true))
  end)

  it("warns when the project names a file renamed under it", function()
    write(project, '<Project><ItemGroup><None Update="appsettings.json" /></ItemGroup></Project>')
    write(dir .. "/src/Api/appsettings.json", "{}")
    inputs = { "settings.json" }
    commands.rename(state_on(file(dir .. "/src/Api/appsettings.json")))
    assert.is_true(said("appsettings.json is named in Api.csproj"))
  end)

  it("has no trash, and says so", function()
    commands.trash(state_on(file(dir .. "/src/Api/Foo.cs")))
    assert.is_true(said("there is no trash"))
    assert.are.equal(1, vim.fn.filereadable(dir .. "/src/Api/Foo.cs"))
  end)

  it("words a refused delete as a delete", function()
    commands.delete(state_on({ name = "All.sln", extra = { kind = "solution" } }))
    commands.delete(state_on({ name = "build", extra = { kind = "sln_folder", guid = "X" } }))
    assert.is_true(said("cannot delete All.sln: the solution file is not deleted from the tree"))
    assert.is_true(said("cannot delete build: a solution folder only exists in the solution file, and is not deleted"))
  end)
end)

-- tpodolak's point on #50: neo-tree's keys for files mean the same here, and
-- the .NET actions live under a prefix of their own
describe("default mappings", function()
  local mappings = require("dotnet-tree").default_config.window.mappings

  it("keep neo-tree's keys for files", function()
    for key, command in pairs({
      a = "add",
      A = "add_directory",
      d = "delete",
      r = "rename",
      b = "rename_basename",
      m = "move",
      c = "copy",
      y = "copy_to_clipboard",
      x = "cut_to_clipboard",
      p = "paste_from_clipboard",
    }) do
      assert.are.equal(command, mappings[key][1], key)
    end
  end)

  it("put every .NET action under ,", function()
    for _, command in ipairs({
      "select_solution",
      "edit_project_file",
      "add_package_or_reference",
      "build",
      "build_solution",
      "clean",
      "clean_solution",
      "run_project",
      "debug",
      "test",
      "watch",
      "choose_launch_profile",
    }) do
      local keys = {}
      for key, value in pairs(mappings) do
        if type(value) == "table" and value[1] == command then
          table.insert(keys, key)
        end
      end
      assert.are.equal(1, #keys, command)
      assert.matches("^,", keys[1], command)
    end
  end)

  -- neo-tree's `s`, `t`, `w`... open what a node's path names: a package has
  -- none, and would open as a buffer named after its id
  it("opens with neo-tree's open commands only nodes that are files", function()
    local opened = {}
    package.loaded["neo-tree.sources.common.commands"] = {
      open_vsplit = function()
        table.insert(opened, "vsplit")
      end,
      toggle_node = function()
        table.insert(opened, "toggle")
      end,
    }
    package.loaded["dotnet-tree.commands"] = nil
    local commands = require("dotnet-tree.commands")
    local function state_with(node)
      function node.has_children()
        return true
      end
      function node.get_id()
        return "id"
      end
      return { tree = {
        get_node = function()
          return node
        end,
      } }
    end
    commands.open_vsplit(state_with({ name = "Serilog", extra = { kind = "package" } }))
    commands.open_vsplit(
      state_with({ name = "Foo.cs", path = "/src/Foo.cs", type = "file", extra = { kind = "file" } })
    )
    assert.are.same({ "toggle", "vsplit" }, opened)
    package.loaded["neo-tree.sources.common.commands"] = nil
    package.loaded["dotnet-tree.commands"] = nil
  end)

  -- `,` then a pause then `r`: the pause must not turn it into `r`, rename
  describe(", and the key after it", function()
    local commands, ran, keys, messages, real_getcharstr, real_notify

    before_each(function()
      ran, messages = {}, {}
      package.loaded["neo-tree.sources.common.commands"] = {}
      package.loaded["dotnet-tree.commands"] = nil
      commands = require("dotnet-tree.commands")
      real_getcharstr, real_notify = vim.fn.getcharstr, vim.notify
      vim.fn.getcharstr = function()
        return table.remove(keys, 1)
      end
      vim.notify = function(msg)
        table.insert(messages, msg)
      end
    end)

    after_each(function()
      vim.fn.getcharstr, vim.notify = real_getcharstr, real_notify
      package.loaded["neo-tree.sources.common.commands"] = nil
      package.loaded["dotnet-tree.commands"] = nil
    end)

    local function state(extra)
      local all = vim.tbl_extend("force", mappings, extra or {})
      return {
        winid = vim.api.nvim_get_current_win(),
        window = { mappings = all },
        commands = setmetatable({
          run_project = function()
            table.insert(ran, "run")
          end,
          debug = function()
            table.insert(ran, "debug")
          end,
          rename = function()
            table.insert(ran, "rename")
          end,
        }, { __index = commands }),
      }
    end

    it("runs the action of the key that follows, however long it takes", function()
      local floats, lines
      keys = { "r" }
      local getcharstr = vim.fn.getcharstr
      vim.fn.getcharstr = function()
        floats = vim.tbl_filter(function(win)
          return vim.api.nvim_win_get_config(win).relative ~= ""
        end, vim.api.nvim_list_wins())
        lines = floats[1] and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, -1, false)
        return getcharstr()
      end
      commands.dotnet_actions(state())
      keys = { "d" }
      vim.fn.getcharstr = getcharstr
      commands.dotnet_actions(state())
      assert.are.same({ "run", "debug" }, ran)
      assert.are.equal(1, #floats, "a float shows the actions while it waits")
      assert.truthy(vim.tbl_contains(lines, " r  run project"), vim.inspect(lines))
      assert.are.same(
        {},
        vim.tbl_filter(function(win)
          return vim.api.nvim_win_get_config(win).relative ~= ""
        end, vim.api.nvim_list_wins()),
        "and closes after"
      )
    end)

    it("does nothing on <esc>, and says when a key has no action", function()
      keys = { "\27" }
      commands.dotnet_actions(state())
      keys = { "q" }
      commands.dotnet_actions(state())
      assert.are.same({}, ran)
      assert.matches("no .NET action on `,q`", messages[1], 1, true)
    end)

    local function float_lines()
      local captured
      local getcharstr = vim.fn.getcharstr
      vim.fn.getcharstr = function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_config(win).relative ~= "" then
            captured = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
          end
        end
        return getcharstr()
      end
      return function()
        vim.fn.getcharstr = getcharstr
        return captured
      end
    end

    it("lists each lower-case key before its upper-case one, and runs the one pressed", function()
      local st = state()
      st.commands.build = function()
        table.insert(ran, "build")
      end
      st.commands.build_solution = function()
        table.insert(ran, "build solution")
      end
      keys = { "B" }
      local lines = float_lines()
      commands.dotnet_actions(st)
      assert.are.same(
        { " a  add package/reference", " b  build project", " B  build solution", " c  clean project" },
        vim.list_slice(lines(), 1, 4)
      )
      keys = { "b" }
      commands.dotnet_actions(st)
      assert.are.same({ "build solution", "build" }, ran)
    end)

    it("cancels quietly on <C-c>, a click or an interrupt, and closes the float", function()
      for _, key in ipairs({ "\3", vim.api.nvim_replace_termcodes("<LeftMouse>", true, true, true) }) do
        keys = { key }
        commands.dotnet_actions(state())
      end
      vim.fn.getcharstr = function()
        error("Keyboard interrupt")
      end
      commands.dotnet_actions(state())
      assert.are.same({}, ran)
      assert.are.same({}, messages)
      assert.are.same(
        {},
        vim.tbl_filter(function(win)
          return vim.api.nvim_win_get_config(win).relative ~= ""
        end, vim.api.nvim_list_wins())
      )
    end)

    it("runs function mappings and a special key, and passes the mapping's config", function()
      local got = {}
      local st = state({
        [",x"] = function(s)
          table.insert(got, "x:" .. tostring(s == nil))
        end,
        [",<C-r>"] = {
          function(s)
            table.insert(got, "ctrl-r:" .. vim.inspect(s.config))
          end,
          desc = "[.NET] again",
          config = { show_path = "relative" },
        },
      })
      keys = { "x" }
      commands.dotnet_actions(st)
      keys = { "\18" }
      commands.dotnet_actions(st)
      assert.are.same({ "x:false", 'ctrl-r:{\n  show_path = "relative"\n}' }, got)
    end)

    it("leaves out disabled mappings, and reports one too long to reach", function()
      local lines = float_lines()
      keys = { "\27" }
      commands.dotnet_actions(state({ [",r"] = "nop", [",rr"] = "run_project" }))
      local shown = lines()
      assert.is_false(vim.tbl_contains(shown, " r  nop"))
      assert.matches("`,rr` is more than one key after `,`", messages[1], 1, true)
    end)

    it("says when a mapping names something that is not a command", function()
      keys = { "x" }
      commands.dotnet_actions(state({ [",x"] = "no_such_command" }))
      assert.matches("`,x` is mapped to no_such_command", messages[1], 1, true)
    end)

    -- Neovim 0.9 has no float footer; any float that cannot open must not
    -- leave the next key taken without notice
    it("says what it waits for on the command line when the float cannot open", function()
      local open_win, echo = vim.api.nvim_open_win, vim.api.nvim_echo
      local echoed = {}
      vim.api.nvim_open_win = function()
        error("Invalid key: 'footer'")
      end
      vim.api.nvim_echo = function(chunks)
        table.insert(echoed, chunks)
      end
      local buffers = #vim.api.nvim_list_bufs()
      keys = { "r" }
      local ok, err = pcall(commands.dotnet_actions, state())
      vim.api.nvim_open_win, vim.api.nvim_echo = open_win, echo
      assert(ok, err)
      assert.are.same({ "run" }, ran)
      assert.are.equal(".NET: ", echoed[1][1][1])
      assert.are.equal(buffers, #vim.api.nvim_list_bufs(), "no buffer left behind")
    end)

    it("follows the , mappings of the configuration", function()
      keys = { "x" }
      commands.dotnet_actions(state({ [",x"] = { "rename", desc = "[.NET] my own" }, [",r"] = "none" }))
      keys = { "r" }
      commands.dotnet_actions(state({ [",x"] = { "rename", desc = "[.NET] my own" }, [",r"] = "none" }))
      assert.are.same({ "rename" }, ran)
      assert.matches("no .NET action on `,r`", messages[1], 1, true)
    end)
  end)

  it("map only commands the source has", function()
    package.loaded["neo-tree.sources.common.commands"] = {}
    package.loaded["dotnet-tree.commands"] = nil
    local commands = require("dotnet-tree.commands")
    for key, value in pairs(mappings) do
      local command = type(value) == "table" and value[1] or value
      if command ~= "show_help" and command ~= "toggle_node" and command ~= "open" then
        assert.is_function(commands[command], key .. " -> " .. tostring(command))
      end
    end
    package.loaded["neo-tree.sources.common.commands"] = nil
    package.loaded["dotnet-tree.commands"] = nil
  end)
end)
