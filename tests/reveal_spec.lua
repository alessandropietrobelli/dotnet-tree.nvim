local reveal = require("dotnet-tree.reveal")

-- A solution as tree.build shapes it: Api at src/Api, and Api.Inner, a project
-- living inside Api's directory, so its files are listed under both.
local function solution()
  return {
    {
      id = "dotnet:sln:/repo/App.sln",
      path = "/repo/App.sln",
      extra = { kind = "solution" },
      children = {
        {
          id = "dotnet:slnfolder:F",
          extra = { kind = "sln_folder" },
          children = {
            {
              id = "dotnet:slnitem:F:/repo/Directory.Packages.props",
              path = "/repo/Directory.Packages.props",
              extra = { kind = "file" },
            },
          },
        },
        {
          id = "dotnet:proj:A",
          path = "/repo/src/Api/Api.csproj",
          extra = { kind = "project" },
          children = {
            {
              id = "dotnet:deps:A",
              extra = { kind = "dependencies" },
              children = {
                {
                  id = "dotnet:projrefs:A",
                  extra = { kind = "projrefs" },
                  children = {
                    {
                      id = "dotnet:pref:A:/repo/src/Lib/Lib.csproj",
                      path = "/repo/src/Lib/Lib.csproj",
                      extra = { kind = "project_reference" },
                    },
                  },
                },
              },
            },
            {
              id = "dotnet:proj:A:dir:/repo/src/Api/Controllers",
              path = "/repo/src/Api/Controllers",
              extra = { kind = "folder" },
              children = {
                {
                  id = "dotnet:proj:A:file:/repo/src/Api/Controllers/Users.cs",
                  path = "/repo/src/Api/Controllers/Users.cs",
                  extra = { kind = "file" },
                },
              },
            },
            {
              id = "dotnet:proj:A:dir:/repo/src/Api/Inner",
              path = "/repo/src/Api/Inner",
              extra = { kind = "folder" },
              children = {
                {
                  id = "dotnet:proj:A:file:/repo/src/Api/Inner/Thing.cs",
                  path = "/repo/src/Api/Inner/Thing.cs",
                  extra = { kind = "file" },
                },
              },
            },
          },
        },
        {
          id = "dotnet:proj:I",
          path = "/repo/src/Api/Inner/Api.Inner.csproj",
          extra = { kind = "project" },
          children = {
            {
              id = "dotnet:proj:I:file:/repo/src/Api/Inner/Thing.cs",
              path = "/repo/src/Api/Inner/Thing.cs",
              extra = { kind = "file" },
            },
          },
        },
        {
          id = "dotnet:proj:L",
          path = "/repo/src/Lib/Lib.csproj",
          extra = { kind = "project" },
          children = {},
        },
      },
    },
  }
end

describe("reveal index", function()
  local index = reveal.index(solution())

  it("maps a file to its node", function()
    assert.equals(
      "dotnet:proj:A:file:/repo/src/Api/Controllers/Users.cs",
      reveal.lookup(index, "/repo/src/Api/Controllers/Users.cs")
    )
  end)

  it("maps a folder, a solution item and the solution itself", function()
    assert.equals("dotnet:proj:A:dir:/repo/src/Api/Controllers", reveal.lookup(index, "/repo/src/Api/Controllers"))
    assert.equals(
      "dotnet:slnitem:F:/repo/Directory.Packages.props",
      reveal.lookup(index, "/repo/Directory.Packages.props")
    )
    assert.equals("dotnet:sln:/repo/App.sln", reveal.lookup(index, "/repo/App.sln"))
  end)

  it("maps a .csproj to its project, never to a reference to it", function()
    assert.equals("dotnet:proj:L", reveal.lookup(index, "/repo/src/Lib/Lib.csproj"))
  end)

  it("puts a file of a nested project under the innermost project", function()
    assert.equals(
      "dotnet:proj:I:file:/repo/src/Api/Inner/Thing.cs",
      reveal.lookup(index, "/repo/src/Api/Inner/Thing.cs")
    )
  end)

  it("normalizes the path it is asked for", function()
    assert.equals(
      "dotnet:proj:A:file:/repo/src/Api/Controllers/Users.cs",
      reveal.lookup(index, "/repo/src/Api//Controllers/Users.cs")
    )
  end)

  it("finds nothing for a file outside the solution, or no file at all", function()
    assert.is_nil(reveal.lookup(index, "/repo/README.md"))
    assert.is_nil(reveal.lookup(index, ""))
    assert.is_nil(reveal.lookup(index, nil))
    assert.is_nil(reveal.lookup(nil, "/repo/App.sln"))
  end)

  it("finds a file opened through a symlink", function()
    local real = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(real, "p")
    local file = real .. "/Users.cs"
    vim.fn.writefile({}, file)
    local link = vim.fn.tempname()
    vim.uv.fs_symlink(real, link)
    local idx = reveal.index({ { id = "f", path = file, extra = { kind = "file" } } })
    assert.equals("f", reveal.lookup(idx, link .. "/Users.cs"))
  end)
end)

-- A NuiTree stand-in: nodes with a parent, expanded or not, and a cursor.
local function fake_tree(items)
  local nodes = {}
  local function add(list, parent_id)
    for _, item in ipairs(list) do
      local node = { id = item.id, parent_id = parent_id, expanded = false }
      function node.get_id(self)
        return self.id
      end
      function node.get_parent_id(self)
        return self.parent_id
      end
      function node.is_expanded(self)
        return self.expanded
      end
      function node.expand(self)
        self.expanded = true
      end
      function node.collapse(self)
        self.expanded = false
      end
      nodes[item.id] = node
      add(item.children or {}, item.id)
    end
  end
  add(items, nil)
  return {
    nodes = nodes,
    cursor = nil,
    get_node = function(self, id)
      return self.nodes[id or self.cursor]
    end,
  }
end

describe("reveal focus and follow", function()
  local focused, window_exists, state

  local USERS = "dotnet:proj:A:file:/repo/src/Api/Controllers/Users.cs"
  local THING = "dotnet:proj:A:file:/repo/src/Api/Inner/Thing.cs"

  before_each(function()
    focused = {}
    window_exists = true
    package.loaded["neo-tree.ui.renderer"] = {
      redraw = function() end,
      window_exists = function()
        return window_exists
      end,
      focus_node = function(s, id, do_not_focus_window)
        s.tree.cursor = id
        table.insert(focused, { id = id, keep_editor_focus = do_not_focus_window or false })
        return true
      end,
    }
    local items = solution()
    state = {
      tree = fake_tree(items),
      dotnet_index = reveal.index(items),
      follow_current_file = { enabled = true, leave_dirs_open = false },
    }
  end)

  after_each(function()
    package.loaded["neo-tree.ui.renderer"] = nil
  end)

  it("reveal expands the way down and takes the focus", function()
    assert.is_true(reveal.focus(state, USERS))
    assert.is_true(state.tree.nodes["dotnet:sln:/repo/App.sln"].expanded)
    assert.is_true(state.tree.nodes["dotnet:proj:A"].expanded)
    assert.is_true(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
    assert.same({ { id = USERS, keep_editor_focus = false } }, focused)
  end)

  it("follow keeps the focus in the editor", function()
    assert.is_true(reveal.follow(state, "/repo/src/Api/Controllers/Users.cs"))
    assert.same({ { id = USERS, keep_editor_focus = true } }, focused)
  end)

  it("follow closes the folders it opened for the previous file", function()
    reveal.follow(state, "/repo/src/Api/Controllers/Users.cs")
    reveal.follow(state, "/repo/src/Api/Inner/Api.Inner.csproj")
    assert.is_false(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
    assert.is_false(state.tree.nodes["dotnet:proj:A"].expanded)
    assert.is_true(state.tree.nodes["dotnet:sln:/repo/App.sln"].expanded)
  end)

  it("follow never closes a folder the user opened", function()
    state.tree.nodes["dotnet:sln:/repo/App.sln"].expanded = true
    state.tree.nodes["dotnet:proj:A"].expanded = true
    state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded = true
    reveal.follow(state, "/repo/src/Api/Controllers/Users.cs")
    reveal.follow(state, "/repo/src/Lib/Lib.csproj")
    assert.is_true(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
    assert.is_true(state.tree.nodes["dotnet:proj:A"].expanded)
  end)

  it("follow leaves the folders open with leave_dirs_open", function()
    state.follow_current_file.leave_dirs_open = true
    reveal.focus(state, THING, { follow = true, leave_dirs_open = false })
    reveal.follow(state, "/repo/src/Api/Controllers/Users.cs")
    reveal.follow(state, "/repo/src/Lib/Lib.csproj")
    assert.is_true(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
  end)

  it("follow does nothing when it is disabled", function()
    state.follow_current_file.enabled = false
    assert.is_false(reveal.follow(state, "/repo/src/Api/Controllers/Users.cs"))
    assert.same({}, focused)
  end)

  it("follow does nothing when the tree is not on screen, or floats", function()
    window_exists = false
    assert.is_false(reveal.follow(state, "/repo/src/Api/Controllers/Users.cs"))
    window_exists = true
    state.current_position = "float"
    assert.is_false(reveal.follow(state, "/repo/src/Api/Controllers/Users.cs"))
    assert.same({}, focused)
  end)

  it("follow does nothing for a file outside the solution", function()
    assert.is_false(reveal.follow(state, "/repo/README.md"))
    assert.same({}, focused)
  end)

  it("follow does not move a cursor already on the file", function()
    state.tree.cursor = USERS
    assert.is_false(reveal.follow(state, "/repo/src/Api/Controllers/Users.cs"))
    assert.same({}, focused)
  end)
end)
