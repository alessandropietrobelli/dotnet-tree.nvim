-- How much of the tree each event redoes (#49). neo-tree's manager and the git
-- module are stand-ins recording what they were asked: what is checked is the
-- choice between a redraw, a git fetch and a rebuild.

local INDEX = {
  ["/repo/App.sln"] = "dotnet:sln",
  ["/repo/src/Api/Api.csproj"] = "dotnet:proj:api",
  ["/repo/src/Api/Program.cs"] = "dotnet:proj:api:file:/repo/src/Api/Program.cs",
  ["/repo/src/Api/Controllers"] = "dotnet:proj:api:dir:/repo/src/Api/Controllers",
  ["/repo/src/Api/Controllers/Users.cs"] = "dotnet:proj:api:file:/repo/src/Api/Controllers/Users.cs",
}

describe("refresh", function()
  local refresh, calls, states

  before_each(function()
    calls = { rebuild = 0, redraw = {}, fetch = {} }
    states = { { name = "dotnet-tree", dotnet_sln = "/repo/App.sln", dotnet_index = INDEX } }
    package.loaded["neo-tree.sources.manager"] = {
      refresh = function()
        calls.rebuild = calls.rebuild + 1
      end,
      redraw = function(name)
        table.insert(calls.redraw, name)
      end,
      _for_each_state = function(_, action)
        for _, state in ipairs(states) do
          action(state)
        end
      end,
    }
    package.loaded["dotnet-tree.git"] = {
      fetch = function(root, on_change)
        table.insert(calls.fetch, root)
        assert.is_function(on_change)
      end,
    }
    package.loaded["dotnet-tree.refresh"] = nil
    refresh = require("dotnet-tree.refresh")
  end)

  after_each(function()
    for _, name in ipairs({ "neo-tree.sources.manager", "dotnet-tree.git", "dotnet-tree.refresh" }) do
      package.loaded[name] = nil
    end
  end)

  it("redraws without rebuilding", function()
    refresh.redraw()
    assert.are.same({ "dotnet-tree" }, calls.redraw)
    assert.are.equal(0, calls.rebuild)
  end)

  it("only asks git again when a file the tree shows is written", function()
    refresh.on_write("/repo/src/Api/Controllers/Users.cs")
    assert.are.same({ "/repo" }, calls.fetch)
    assert.are.equal(0, calls.rebuild)
  end)

  it("rebuilds when a new file is written in a project", function()
    refresh.on_write("/repo/src/Api/Startup.cs")
    refresh.on_write("/repo/src/Api/Controllers/Admin.cs")
    assert.are.equal(2, calls.rebuild)
    assert.are.same({}, calls.fetch)
  end)

  it("rebuilds when a new file is written in a new folder of a project", function()
    refresh.on_write("/repo/src/Api/Models/User.cs")
    assert.are.equal(1, calls.rebuild)
  end)

  it("ignores a file written where the tree lists nothing", function()
    refresh.on_write("/repo/src/Api/obj/Generated.cs") -- skipped by the walk
    refresh.on_write("/repo/README.md") -- next to the solution, not in a project
    refresh.on_write("/elsewhere/Notes.cs")
    refresh.on_write("")
    assert.are.equal(0, calls.rebuild)
    assert.are.same({}, calls.fetch)
  end)

  it("does nothing when no tree is open", function()
    states = {}
    refresh.on_write("/repo/src/Api/Startup.cs")
    refresh.on_write("/repo/src/Api/Program.cs")
    assert.are.equal(0, calls.rebuild)
    assert.are.same({}, calls.fetch)
  end)
end)

-- The autocommands in init.lua, with the refresh module recording calls.
describe("refresh wiring", function()
  local calls

  before_each(function()
    calls = { rebuild = 0, redraw = 0, written = {} }
    package.loaded["dotnet-tree.refresh"] = {
      rebuild = function()
        calls.rebuild = calls.rebuild + 1
      end,
      redraw = function()
        calls.redraw = calls.redraw + 1
      end,
      on_write = function(path)
        table.insert(calls.written, path)
      end,
    }
    package.loaded["dotnet-tree"] = nil
    require("dotnet-tree").setup({}, {})
  end)

  after_each(function()
    vim.api.nvim_del_augroup_by_name("DotnetTreeAutoRefresh")
    package.loaded["dotnet-tree.refresh"] = nil
    package.loaded["dotnet-tree"] = nil
  end)

  it("redraws, once, when diagnostics change", function()
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("DiagnosticChanged", {})
    end
    vim.wait(1000, function()
      return calls.redraw > 0
    end, 10)
    vim.wait(300)
    assert.are.equal(1, calls.redraw)
    assert.are.equal(0, calls.rebuild)
  end)

  it("hands a written source file to on_write, and rebuilds for a project file", function()
    vim.api.nvim_exec_autocmds("BufWritePost", { pattern = "/repo/src/Api/Program.cs" })
    assert.are.same({ "/repo/src/Api/Program.cs" }, calls.written)
    assert.are.equal(0, calls.rebuild)

    vim.api.nvim_exec_autocmds("BufWritePost", { pattern = "/repo/src/Api/Api.csproj" })
    vim.api.nvim_exec_autocmds("BufWritePost", { pattern = "/repo/Directory.Packages.props" })
    assert.are.equal(2, calls.rebuild)
    assert.are.equal(1, #calls.written)
  end)
end)
