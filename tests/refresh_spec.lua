-- How much of the tree each event redoes (#49). neo-tree's manager and the git
-- module are stand-ins recording what they were asked: what is checked is the
-- choice between a redraw, a git fetch and a rebuild.

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures"

local INDEX = {
  ["/repo/App.sln"] = "dotnet:sln",
  ["/repo/src/Api/Api.csproj"] = "dotnet:proj:api",
  ["/repo/src/Api/Program.cs"] = "dotnet:proj:api:file:/repo/src/Api/Program.cs",
  ["/repo/src/Api/Controllers"] = "dotnet:proj:api:dir:/repo/src/Api/Controllers",
  ["/repo/src/Api/Controllers/Users.cs"] = "dotnet:proj:api:file:/repo/src/Api/Controllers/Users.cs",
}

-- Let scheduled callbacks run.
local function settle()
  vim.wait(30, function()
    return false
  end, 5)
end

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
    settle()
    assert.are.same({ "/repo" }, calls.fetch)
    assert.are.equal(0, calls.rebuild)
  end)

  it("rebuilds once when new files are written in a project, as by :wa", function()
    refresh.on_write("/repo/src/Api/Startup.cs")
    refresh.on_write("/repo/src/Api/Controllers/Admin.cs")
    settle()
    assert.are.equal(1, calls.rebuild)
    assert.are.same({}, calls.fetch)
  end)

  it("rebuilds when a new file is written in a new folder of a project", function()
    refresh.on_write("/repo/src/Api/Models/User.cs")
    settle()
    assert.are.equal(1, calls.rebuild)
  end)

  it("ignores a file written where the tree lists nothing", function()
    refresh.on_write("/repo/src/Api/obj/Generated.cs") -- skipped by the walk
    refresh.on_write("/repo/README.md") -- next to the solution, not in a project
    refresh.on_write("/elsewhere/Notes.cs")
    refresh.on_write("")
    settle()
    assert.are.equal(0, calls.rebuild)
    assert.are.same({}, calls.fetch)
  end)

  it("does nothing when no tree is open", function()
    states = {}
    refresh.on_write("/repo/src/Api/Startup.cs")
    refresh.on_write("/repo/src/Api/Program.cs")
    settle()
    assert.are.equal(0, calls.rebuild)
    assert.are.same({}, calls.fetch)
  end)

  it("asks git once for two trees on the same solution, and skips a tree not built yet", function()
    table.insert(states, { name = "dotnet-tree", dotnet_sln = "/repo/App.sln", dotnet_index = INDEX })
    table.insert(states, { name = "dotnet-tree", dotnet_sln = "/repo/App.sln" })
    refresh.on_write("/repo/src/Api/Program.cs")
    settle()
    assert.are.same({ "/repo" }, calls.fetch)
  end)

  it("lets a rebuild in one tree stand for the git fetch of another", function()
    table.insert(states, {
      name = "dotnet-tree",
      dotnet_sln = "/repo/App.sln",
      dotnet_index = { ["/repo/src/Api/Api.csproj"] = "p", ["/repo/src/Api/Startup.cs"] = "f" },
    })
    refresh.on_write("/repo/src/Api/Startup.cs")
    settle()
    assert.are.equal(1, calls.rebuild)
    assert.are.same({}, calls.fetch)
  end)

  it("asks git again for every open tree when the repository may have changed outside", function()
    table.insert(states, { name = "dotnet-tree", dotnet_sln = "/repo/App.sln", dotnet_index = INDEX })
    table.insert(states, { name = "dotnet-tree", dotnet_sln = "/other/Other.slnx", dotnet_index = {} })
    table.insert(states, { name = "dotnet-tree", dotnet_sln = "/third/Third.sln" }) -- not built yet
    refresh.on_outside_change()
    table.sort(calls.fetch)
    assert.are.same({ "/other", "/repo" }, calls.fetch)
    assert.are.equal(0, calls.rebuild)
  end)

  it("reports a failing manager once instead of on every redraw", function()
    local warnings = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      table.insert(warnings, msg)
    end
    package.loaded["dotnet-tree.git"] = nil -- the real one, which warns
    require("dotnet-tree.git").reset()
    package.loaded["neo-tree.sources.manager"].redraw = function()
      error("renderer broke")
    end
    refresh.redraw()
    refresh.redraw()
    vim.notify = notify
    package.loaded["dotnet-tree.git"] = nil
    assert.are.equal(1, #warnings)
    assert.matches("renderer broke", warnings[1])
  end)
end)

-- The autocommands in init.lua, with the refresh module and the parsers'
-- caches recording calls. Writes go through real buffers, opened by a name
-- relative to the working directory, as a picker opens them.
describe("refresh wiring", function()
  local calls, cwd, dir

  local function write(rel)
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. rel), "p")
    vim.cmd("silent edit " .. vim.fn.fnameescape(rel))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })
    vim.cmd("silent write")
    vim.cmd("bwipeout!")
  end

  before_each(function()
    calls = { rebuild = 0, redraw = 0, outside = 0, written = {}, invalidated = {} }
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
      on_outside_change = function()
        calls.outside = calls.outside + 1
      end,
    }
    for _, name in ipairs({ "solution", "csproj", "cpm" }) do
      package.loaded["dotnet-tree.parser." .. name] = {
        invalidate = function(path)
          table.insert(calls.invalidated, name .. " " .. (path and vim.fs.basename(path) or "*"))
        end,
      }
    end
    package.loaded["dotnet-tree"] = nil
    require("dotnet-tree").setup({}, {})
    cwd = vim.fn.getcwd()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(vim.uv.fs_realpath(dir))
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    pcall(vim.api.nvim_del_augroup_by_name, "DotnetTreeAutoRefresh")
    for _, name in ipairs({ "dotnet-tree.refresh", "dotnet-tree", "dotnet-tree.parser.solution" }) do
      package.loaded[name] = nil
    end
    package.loaded["dotnet-tree.parser.csproj"] = nil
    package.loaded["dotnet-tree.parser.cpm"] = nil
  end)

  it("redraws, once per burst, when diagnostics change", function()
    for burst = 1, 2 do
      for _ = 1, 5 do
        vim.api.nvim_exec_autocmds("DiagnosticChanged", {})
      end
      vim.wait(1000, function()
        return calls.redraw >= burst
      end, 10)
      vim.wait(300)
      assert.are.equal(burst, calls.redraw)
    end
    assert.are.equal(0, calls.rebuild)
  end)

  it("asks git again on focus, when a terminal closes and after fugitive", function()
    vim.api.nvim_exec_autocmds("FocusGained", {})
    -- `data` as Neovim passes it: its own TermClose handler reads it.
    vim.api.nvim_exec_autocmds("TermClose", { data = { status = 0 } })
    vim.api.nvim_exec_autocmds("User", { pattern = "FugitiveChanged" })
    assert.are.equal(3, calls.outside)
    assert.are.equal(0, calls.rebuild)
  end)

  it("hands a written source file to on_write by its absolute path", function()
    write("src/Api/New.cs")
    assert.are.same({ dir .. "/src/Api/New.cs" }, calls.written)
    assert.are.equal(0, calls.rebuild)
  end)

  it("rebuilds for project, solution and package files, after invalidating their cache", function()
    write("App.sln")
    write("App.slnx")
    write("src/Api/Api.csproj")
    write("src/Lib/Lib.fsproj")
    write("src/Old/Old.vbproj")
    write("Directory.Packages.props")
    assert.are.equal(6, calls.rebuild)
    assert.are.same({}, calls.written)
    assert.are.same({
      "solution App.sln",
      "csproj *",
      "solution App.slnx",
      "csproj *",
      "csproj Api.csproj",
      "csproj Lib.fsproj",
      "csproj Old.vbproj",
      "cpm Directory.Packages.props",
    }, calls.invalidated)
  end)
end)

-- navigate, the git fetch it starts and the rebuild that answers it, wired
-- together: a status that changes rebuilds once, and the rebuild's own fetch,
-- finding the same status, ends there.
describe("refresh after navigate", function()
  local rebuilds, jobs, state

  before_each(function()
    rebuilds, jobs = 0, {}
    package.loaded["neo-tree.ui.renderer"] = { show_nodes = function() end }
    package.loaded["dotnet-tree"] = nil
    package.loaded["dotnet-tree.refresh"] = nil
    require("dotnet-tree.git").reset()
    state = { path = FIXTURES, dotnet_sln = FIXTURES .. "/Sample.slnx" }
    package.loaded["neo-tree.sources.manager"] = {
      refresh = function()
        rebuilds = rebuilds + 1
        require("dotnet-tree").navigate(state, state.path)
      end,
    }
  end)

  after_each(function()
    for _, name in ipairs({ "neo-tree.ui.renderer", "neo-tree.sources.manager", "dotnet-tree", "dotnet-tree.refresh" }) do
      package.loaded[name] = nil
    end
    require("dotnet-tree.git").reset()
  end)

  it("asks git for the solution's directory and rebuilds once when the status changed", function()
    local jobstart = vim.fn.jobstart
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(cmd, opts)
      table.insert(jobs, cmd)
      local out = cmd[4] == "rev-parse" and { FIXTURES } or { " M Sample.slnx" }
      vim.schedule(function()
        opts.on_stdout(#jobs, out)
        opts.on_stderr(#jobs, {})
        opts.on_exit(#jobs, 0)
      end)
      return #jobs
    end
    require("dotnet-tree").navigate(state, state.path)
    vim.wait(500, function()
      return false
    end, 10)
    vim.fn.jobstart = jobstart

    assert.are.equal(vim.fs.normalize(FIXTURES), jobs[1][3])
    assert.are.equal(1, rebuilds)
    -- rev-parse, then one status per navigate: the first build and the rebuild
    assert.are.equal(3, #jobs)
  end)
end)
