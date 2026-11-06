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
                    {
                      id = "dotnet:pref:A:/elsewhere/Ext/Ext.csproj",
                      path = "/elsewhere/Ext/Ext.csproj",
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
    -- referenced, but not in the solution: no node shows the project itself
    assert.is_nil(reveal.lookup(index, "/elsewhere/Ext/Ext.csproj"))
  end)

  it("puts a file of a nested project under the innermost project", function()
    assert.equals(
      "dotnet:proj:I:file:/repo/src/Api/Inner/Thing.cs",
      reveal.lookup(index, "/repo/src/Api/Inner/Thing.cs")
    )
  end)

  it("keeps the innermost project whichever is listed first", function()
    local items = solution()
    local children = items[1].children
    -- move Api.Inner ahead of Api
    local inner = table.remove(children, 3)
    table.insert(children, 2, inner)
    assert.equals(
      "dotnet:proj:I:file:/repo/src/Api/Inner/Thing.cs",
      reveal.lookup(reveal.index(items), "/repo/src/Api/Inner/Thing.cs")
    )
  end)

  it("lands a .csproj on its project when two projects share a directory", function()
    -- B is listed first, and walks the directory where A.csproj sits as a file
    local items = {
      {
        id = "dotnet:proj:B",
        path = "/repo/legacy/B.csproj",
        extra = { kind = "project" },
        children = {
          {
            id = "dotnet:proj:B:file:/repo/legacy/A.csproj",
            path = "/repo/legacy/A.csproj",
            extra = { kind = "file" },
          },
        },
      },
      { id = "dotnet:proj:A", path = "/repo/legacy/A.csproj", extra = { kind = "project" }, children = {} },
    }
    assert.equals("dotnet:proj:A", reveal.lookup(reveal.index(items), "/repo/legacy/A.csproj"))
  end)

  it("normalizes the path it is asked for, and the paths it indexes", function()
    local idx = reveal.index({ { id = "d", path = "/repo//src/Api/", extra = { kind = "folder" } } })
    assert.equals("d", reveal.lookup(idx, "/repo/src/Api"))
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
  local focused, calls, window_exists, state

  local USERS = "dotnet:proj:A:file:/repo/src/Api/Controllers/Users.cs"

  before_each(function()
    focused = {}
    calls = {}
    window_exists = true
    package.loaded["neo-tree.ui.renderer"] = {
      redraw = function()
        table.insert(calls, "redraw")
      end,
      window_exists = function()
        return window_exists
      end,
      focus_node = function(s, id, do_not_focus_window)
        table.insert(calls, "focus_node")
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

  it("redraws the expanded tree before moving the cursor into it", function()
    reveal.focus(state, USERS)
    assert.same({ "redraw", "focus_node" }, calls)
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
    reveal.follow(state, "/repo/src/Api/Controllers/Users.cs")
    reveal.follow(state, "/repo/src/Lib/Lib.csproj")
    assert.is_true(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
    assert.is_true(state.tree.nodes["dotnet:proj:A"].expanded)
  end)

  it("follow leaves alone a folder the user toggled after follow opened it", function()
    reveal.follow(state, "/repo/src/Api/Controllers/Users.cs")
    -- the user closes Controllers and opens it again: it is theirs now
    reveal.forget(state, "dotnet:proj:A:dir:/repo/src/Api/Controllers")
    reveal.follow(state, "/repo/src/Lib/Lib.csproj")
    assert.is_true(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
    -- Api itself was not touched, so follow still closes it
    assert.is_false(state.tree.nodes["dotnet:proj:A"].expanded)
  end)

  it("forgets every folder when the user closes or expands all", function()
    reveal.follow(state, "/repo/src/Api/Controllers/Users.cs")
    reveal.forget(state)
    reveal.follow(state, "/repo/src/Lib/Lib.csproj")
    assert.is_true(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
  end)

  it("follow does nothing from inside a neo-tree window", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    for _, ft in ipairs({ "neo-tree", "neo-tree-popup" }) do
      vim.bo[buf].filetype = ft
      assert.is_false(reveal.follow(state, "/repo/src/Api/Controllers/Users.cs"))
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.same({}, focused)
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

-- The wiring in init.lua: navigate builds the index and reveals through it,
-- setup subscribes the follow handler. Only plenary is available in CI, so
-- neo-tree's modules are stand-ins recording what they were asked.
describe("source wiring", function()
  local stubs = {
    "neo-tree.ui.renderer",
    "neo-tree.sources.manager",
    "neo-tree.events",
    "neo-tree.log",
    "dotnet-tree.tree",
    "dotnet-tree.nuget",
  }
  local focused, subscriptions, source, notify, notified

  before_each(function()
    focused, subscriptions, notified = {}, {}, {}
    package.loaded["dotnet-tree"] = nil
    package.loaded["neo-tree.ui.renderer"] = {
      show_nodes = function(items, s)
        s.tree = fake_tree(items)
      end,
      redraw = function() end,
      window_exists = function()
        return true
      end,
      focus_node = function(s, id, do_not_focus_window)
        s.tree.cursor = id
        table.insert(focused, { id = id, keep_editor_focus = do_not_focus_window or false })
        return true
      end,
    }
    package.loaded["dotnet-tree.tree"] = {
      build = function()
        return solution()
      end,
    }
    package.loaded["neo-tree.events"] = { VIM_BUFFER_ENTER = "vim_buffer_enter" }
    package.loaded["neo-tree.log"] = { debug = function() end }
    package.loaded["dotnet-tree.nuget"] = { watch = function() end }
    package.loaded["neo-tree.sources.manager"] = {
      subscribe = function(name, sub)
        table.insert(subscriptions, { name = name, event = sub.event, handler = sub.handler })
      end,
    }
    notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    source = require("dotnet-tree")
  end)

  after_each(function()
    vim.notify = notify
    for _, name in ipairs(stubs) do
      package.loaded[name] = nil
    end
    package.loaded["dotnet-tree"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "DotnetTreeAutoRefresh")
  end)

  it("navigate reveals a file by its node id, not by its path", function()
    local state = { path = "/repo", dotnet_sln = "/repo/App.sln" }
    local done = false
    source.navigate(state, nil, "/repo/src/Api/Controllers/Users.cs", function()
      done = true
    end)
    assert.same(
      { { id = "dotnet:proj:A:file:/repo/src/Api/Controllers/Users.cs", keep_editor_focus = false } },
      focused
    )
    assert.is_true(state.tree.nodes["dotnet:proj:A:dir:/repo/src/Api/Controllers"].expanded)
    assert.is_true(done)
  end)

  it("navigate keeps the index on the state, and ignores a file no node shows", function()
    local state = { path = "/repo", dotnet_sln = "/repo/App.sln" }
    source.navigate(state, nil, "/repo/README.md")
    assert.same({}, focused)
    assert.same({}, notified)
    assert.equals("dotnet:proj:L", state.dotnet_index["/repo/src/Lib/Lib.csproj"])
  end)

  it("setup subscribes to buffer switches only when follow_current_file is enabled", function()
    source.setup({ follow_current_file = { enabled = false } })
    source.setup(nil)
    assert.same({}, subscriptions)
    source.setup({ follow_current_file = { enabled = true } })
    assert.equals(1, #subscriptions)
    assert.equals("dotnet-tree", subscriptions[1].name)
    assert.equals("vim_buffer_enter", subscriptions[1].event)
  end)

  it("the handler follows the path neo-tree would reveal, in this source's state", function()
    local reveal = require("dotnet-tree.reveal")
    local follow = reveal.follow
    local got = {}
    reveal.follow = function(s, path)
      got = { s, path }
    end
    local state = {}
    local manager = package.loaded["neo-tree.sources.manager"]
    manager.get_state = function(name)
      return name == "dotnet-tree" and state or nil
    end
    manager.get_path_to_reveal = function()
      return "/repo/src/Api/Controllers/Users.cs"
    end
    source.setup({ follow_current_file = { enabled = true } })
    local result = subscriptions[1].handler()
    reveal.follow = follow
    assert.equals(state, got[1])
    assert.equals("/repo/src/Api/Controllers/Users.cs", got[2])
    -- neo-tree unsubscribes a handler that returns true
    assert.is_nil(result)
  end)

  it("a failing follow never raises, and warns once", function()
    local reveal = require("dotnet-tree.reveal")
    local follow = reveal.follow
    reveal.follow = function()
      error("boom")
    end
    local manager = package.loaded["neo-tree.sources.manager"]
    manager.get_state = function()
      return {}
    end
    manager.get_path_to_reveal = function()
      return "/repo/x.cs"
    end
    source.setup({ follow_current_file = { enabled = true } })
    assert.has_no.errors(function()
      subscriptions[1].handler()
      subscriptions[1].handler()
    end)
    reveal.follow = follow
    assert.equals(1, #notified)
    assert.equals(vim.log.levels.WARN, notified[1].level)
    assert.truthy(notified[1].msg:find("boom", 1, true))
  end)
end)
