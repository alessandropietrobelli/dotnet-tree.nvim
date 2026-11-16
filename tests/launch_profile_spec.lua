-- Choosing the launch profile `r`, `d` and `w` → run start a project with (#51).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local LAUNCH = root .. "/fixtures/launch"

local launch_settings = require("dotnet-tree.parser.launch_settings")

describe("parser.launch_settings names and read by name", function()
  it("lists the profiles r and d can start, first in the file first", function()
    -- IIS Express is not one: it does not start the assembly that was built
    assert.are.same({ "http", "https" }, launch_settings.names(LAUNCH .. "/Webapi"))
    assert.are.same(
      { "zzz-first-in-file", "Ordered", "aaa-alphabetically-first" },
      launch_settings.names(LAUNCH .. "/Ordered")
    )
    assert.are.same({}, launch_settings.names(LAUNCH .. "/NoProject"))
    assert.are.same({}, launch_settings.names(root .. "/fixtures"))
  end)

  it("reads the profile asked for, and nothing for one the file does not have", function()
    local settings, name = launch_settings.read(LAUNCH .. "/Webapi", "https")
    assert.are.equal("https", name)
    assert.are.equal("https://localhost:7135;http://localhost:5135", settings.env.ASPNETCORE_URLS)
    assert.is_nil(launch_settings.read(LAUNCH .. "/Webapi", "IIS Express"))
    assert.is_nil(launch_settings.read(LAUNCH .. "/Webapi", "gone"))
  end)
end)

describe("launch profile choice", function()
  local store = require("dotnet-tree.store")
  local launch_profile = require("dotnet-tree.launch_profile")
  local saved, remembered, asked, answer, messages

  local function stub(tbl, key, value)
    table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
    tbl[key] = value
  end

  local WEBAPI = LAUNCH .. "/Webapi/Webapi.csproj"

  before_each(function()
    saved, remembered, asked, messages = {}, {}, {}, {}
    answer = "https"
    stub(store, "get_profile", function(path)
      return remembered[path]
    end)
    stub(store, "set_profile", function(path, name)
      remembered[path] = name
    end)
    stub(vim.ui, "select", function(items, opts, on_choice)
      table.insert(asked, vim.tbl_map(opts.format_item or tostring, items))
      on_choice(answer)
    end)
    stub(vim, "notify", function(msg)
      table.insert(messages, msg)
    end)
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i].tbl[saved[i].key] = saved[i].value
    end
  end)

  local function choose(path)
    local got = "not called"
    launch_profile.choose(path, function(name)
      got = name
    end)
    return got
  end

  it("asks once per project, marking the default, and remembers the answer", function()
    assert.are.equal("https", choose(WEBAPI))
    assert.are.equal("https", choose(WEBAPI))
    assert.are.same({ { "http (default)", "https" } }, asked)
    assert.are.equal("https", remembered[WEBAPI])
  end)

  it("asks nothing for a project with one profile or none", function()
    assert.is_nil(choose(LAUNCH .. "/NoProject/NoProject.csproj"))
    assert.is_nil(choose(root .. "/fixtures/Nothing.csproj"))
    assert.are.same({}, asked)
  end)

  it("asks again when the file no longer has the profile chosen", function()
    remembered[WEBAPI] = "renamed-since"
    answer = "http"
    assert.are.equal("http", choose(WEBAPI))
    assert.are.equal(1, #asked)
  end)

  it("does not go on when the question is cancelled", function()
    answer = nil
    assert.are.equal("not called", choose(WEBAPI))
    assert.is_nil(remembered[WEBAPI])
  end)

  it("asks again with L, and says when there is nothing to choose", function()
    remembered[WEBAPI] = "https"
    answer = "http"
    launch_profile.pick(WEBAPI)
    assert.are.equal("http", remembered[WEBAPI])
    assert.matches('starts with launch profile "http"', messages[1])
    launch_profile.pick(LAUNCH .. "/NoProject/NoProject.csproj")
    assert.matches("no launch profile", messages[2])
    assert.are.equal(1, #asked)
  end)

  it("passes the profile to dotnet only when there is one", function()
    assert.are.equal(" --launch-profile " .. vim.fn.shellescape("IIS x"), launch_profile.args("IIS x"))
    assert.are.equal("", launch_profile.args(nil))
  end)

  -- r, d and w → run through commands.lua, with the terminal and the debugger
  -- standing in.
  describe("in r, d and w", function()
    local opened, debugged, commands

    local function state_on(path)
      local node = { extra = { kind = "project", project = { path = path } }, get_parent_id = function() end }
      return {
        tree = {
          get_node = function()
            return node
          end,
        },
      }
    end

    before_each(function()
      opened, debugged = {}, {}
      package.loaded["neo-tree.sources.common.commands"] = {}
      package.loaded["dotnet-tree.commands"] = nil
      stub(require("dotnet-tree.terminal"), "open", function(cmd)
        table.insert(opened, cmd)
      end)
      stub(require("dotnet-tree.debug"), "debug", function(path, opts)
        table.insert(debugged, { path = path, profile = opts and opts.profile })
      end)
      commands = require("dotnet-tree.commands")
    end)

    after_each(function()
      package.loaded["neo-tree.sources.common.commands"] = nil
      package.loaded["dotnet-tree.commands"] = nil
    end)

    it("runs and watches with the profile chosen, asked once for both", function()
      commands.run_project(state_on(WEBAPI))
      answer = "run" -- the watch menu
      commands.watch(state_on(WEBAPI))
      local suffix = " --launch-profile " .. vim.fn.shellescape("https")
      assert.are.same({
        "dotnet run --project " .. vim.fn.shellescape(WEBAPI) .. suffix,
        "dotnet watch run --project " .. vim.fn.shellescape(WEBAPI) .. suffix,
      }, opened)
      assert.are.equal(2, #asked, "the profile once, then the watch menu")
    end)

    it("runs as before when there is nothing to choose", function()
      local path = LAUNCH .. "/NoProject/NoProject.csproj"
      commands.run_project(state_on(path))
      assert.are.same({ "dotnet run --project " .. vim.fn.shellescape(path) }, opened)
      assert.are.same({}, asked)
    end)

    it("debugs with the profile chosen, asked before the build", function()
      commands.debug(state_on(WEBAPI))
      assert.are.same({ { path = WEBAPI, profile = "https" } }, debugged)
    end)

    it("chooses again with L", function()
      remembered[WEBAPI] = "https"
      answer = "http"
      commands.choose_launch_profile(state_on(WEBAPI))
      assert.are.equal("http", remembered[WEBAPI])
    end)
  end)
end)

describe("store of launch profiles", function()
  it("keeps the choice per project, next to the solutions", function()
    local store = require("dotnet-tree.store")
    local state = vim.fn.tempname()
    local stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(what)
      return what == "state" and state or stdpath(what)
    end
    local ok, err = pcall(function()
      store.set_profile("/src/Api/Api.csproj", "https")
      store.set_profile("/src/Web/Web.csproj", "http")
      store.set("/src", "/src/All.sln")
      assert.are.equal("https", store.get_profile("/src/Api/Api.csproj"))
      assert.are.equal("http", store.get_profile("/src/Web/Web.csproj"))
      assert.is_nil(store.get_profile("/src/Other/Other.csproj"))
      assert.are.equal("/src/All.sln", store.get("/src"))
    end)
    vim.fn.stdpath = stdpath
    vim.fn.delete(state, "rf")
    assert(ok, err)
  end)
end)
