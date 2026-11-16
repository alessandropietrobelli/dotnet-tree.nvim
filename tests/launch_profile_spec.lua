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
    assert.are.same({ "Single" }, launch_settings.names(LAUNCH .. "/Single"))
    assert.are.same({}, launch_settings.names(LAUNCH .. "/NoProject"))
    assert.are.same({}, launch_settings.names(root .. "/fixtures"))
  end)

  it("reads the profile asked for, and says so when the file does not have it", function()
    local settings, name = launch_settings.read(LAUNCH .. "/Webapi", "https")
    assert.are.equal("https", name)
    assert.are.equal("https://localhost:7135;http://localhost:5135", settings.env.ASPNETCORE_URLS)
    for _, missing in ipairs({ "IIS Express", "gone" }) do
      local none, none_name, err = launch_settings.read(LAUNCH .. "/Webapi", missing)
      assert.is_nil(none)
      assert.is_nil(none_name)
      assert.matches(missing, err, 1, true)
    end
  end)

  it("names the default the same way read picks it", function()
    for _, dir in ipairs({ "Webapi", "Ordered", "Single" }) do
      local _, name = launch_settings.read(LAUNCH .. "/" .. dir)
      assert.are.equal(launch_settings.names(LAUNCH .. "/" .. dir)[1], name)
    end
  end)

  -- `dotnet` reads comments and trailing commas, and Visual Studio writes them
  it("reads a file with comments and trailing commas", function()
    local settings, name = launch_settings.read(LAUNCH .. "/Json5")
    assert.are.equal("http", name)
    assert.are.equal("Development", settings.env.ASPNETCORE_ENVIRONMENT)
    local text = launch_settings.strip_jsonc(table.concat({
      "{ // a comment",
      '  "url": "http://localhost:5000", /* a block',
      "     comment */",
      '  "odd": "a // b, }",',
      '  "list": [1, 2, // last',
      "  ],",
      "}",
    }, "\n"))
    assert.are.same({ url = "http://localhost:5000", odd = "a // b, }", list = { 1, 2 } }, vim.json.decode(text))
  end)

  it("says why a file it still cannot read gives no profile", function()
    local names, err = launch_settings.names(LAUNCH .. "/Broken")
    assert.are.same({}, names)
    assert.matches("launchSettings.json", err, 1, true)
    local settings, _, read_err = launch_settings.read(LAUNCH .. "/Broken")
    assert.is_nil(settings)
    assert.are.equal(err, read_err)
  end)

  -- A profile that declares nothing still is the profile in use: `d` names it
  it("reads a profile that declares nothing as an empty one, not as none", function()
    local root_dir = vim.fn.tempname()
    vim.fn.mkdir(root_dir .. "/Properties", "p")
    vim.fn.writefile(
      { '{ "profiles": { "bare": { "commandName": "Project" } } }' },
      root_dir .. "/Properties/launchSettings.json"
    )
    local settings, name = launch_settings.read(root_dir)
    assert.are.same({}, settings)
    assert.are.equal("bare", name)
    vim.fn.delete(root_dir, "rf")
  end)
end)

describe("launch profile choice", function()
  local store = require("dotnet-tree.store")
  local launch_profile
  local saved, remembered, asked, answers, messages, write_fails

  local function stub(tbl, key, value)
    table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
    tbl[key] = value
  end

  local WEBAPI = LAUNCH .. "/Webapi/Webapi.csproj"
  local SINGLE = LAUNCH .. "/Single/Single.csproj"

  before_each(function()
    saved, remembered, asked, messages = {}, {}, {}, {}
    -- One answer per question, in order: which question got which shows
    answers = { "https" }
    write_fails = false
    stub(store, "get_profile", function(path)
      return remembered[path]
    end)
    stub(store, "set_profile", function(path, name)
      if write_fails then
        return false, "E482: Can't create file"
      end
      remembered[path] = name
      return true
    end)
    stub(vim.ui, "select", function(items, opts, on_choice)
      table.insert(asked, vim.tbl_map(opts.format_item or tostring, items))
      on_choice(table.remove(answers, 1))
    end)
    stub(vim, "notify", function(msg, level)
      table.insert(messages, { msg = msg, level = level })
    end)
    -- What was said once is said once per module load
    package.loaded["dotnet-tree.launch_profile"] = nil
    launch_profile = require("dotnet-tree.launch_profile")
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

  it("marks the first in the file as the default, not the first alphabetically", function()
    answers = { "Ordered" }
    choose(LAUNCH .. "/Ordered/Ordered.csproj")
    assert.are.equal("zzz-first-in-file (default)", asked[1][1])
  end)

  it("asks nothing for a project with one profile or none", function()
    assert.is_nil(choose(SINGLE))
    assert.is_nil(choose(LAUNCH .. "/NoProject/NoProject.csproj"))
    assert.is_nil(choose(root .. "/fixtures/Nothing.csproj"))
    assert.are.same({}, asked)
    assert.are.same({}, messages)
  end)

  it("asks again when the file no longer has the profile chosen", function()
    remembered[WEBAPI] = "renamed-since"
    answers = { "http" }
    assert.are.equal("http", choose(WEBAPI))
    assert.are.equal(1, #asked)
  end)

  it("says once that a choice made before is not used any more", function()
    remembered[SINGLE] = "https"
    assert.is_nil(choose(SINGLE))
    assert.is_nil(choose(SINGLE))
    assert.are.equal(1, #messages)
    assert.matches('"https" chosen for Single is not used: only "Single"', messages[1].msg, 1, true)
    assert.are.equal(vim.log.levels.WARN, messages[1].level)
  end)

  it("says once why a file it cannot read offers no choice", function()
    local broken = LAUNCH .. "/Broken/Broken.csproj"
    assert.is_nil(choose(broken))
    assert.is_nil(choose(broken))
    assert.are.equal(1, #messages)
    assert.matches("cannot read", messages[1].msg, 1, true)
    assert.matches("default", messages[1].msg, 1, true)
  end)

  it("starts anyway when the choice cannot be remembered, and says so", function()
    write_fails = true
    assert.are.equal("https", choose(WEBAPI))
    assert.matches("could not remember the launch profile", messages[1].msg, 1, true)
  end)

  it("does not go on when the question is cancelled", function()
    answers = {}
    assert.are.equal("not called", choose(WEBAPI))
    assert.is_nil(remembered[WEBAPI])
  end)

  it("asks again with L, and says when there is nothing to choose", function()
    remembered[WEBAPI] = "https"
    answers = { "http" }
    launch_profile.pick(WEBAPI)
    assert.are.equal("http", remembered[WEBAPI])
    assert.matches('starts with launch profile "http"', messages[1].msg, 1, true)
    launch_profile.pick(SINGLE)
    assert.matches('one launch profile, "Single": there is nothing to choose', messages[2].msg, 1, true)
    launch_profile.pick(LAUNCH .. "/NoProject/NoProject.csproj")
    assert.matches("no launch profile", messages[3].msg, 1, true)
    launch_profile.pick(LAUNCH .. "/Broken/Broken.csproj")
    assert.matches("cannot read", messages[4].msg, 1, true)
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
        table.insert(debugged, { path = path, opts = opts })
      end)
      commands = require("dotnet-tree.commands")
    end)

    after_each(function()
      package.loaded["neo-tree.sources.common.commands"] = nil
      package.loaded["dotnet-tree.commands"] = nil
    end)

    it("runs and watches with the profile chosen, asked once for both", function()
      answers = { "https", "run" }
      commands.run_project(state_on(WEBAPI))
      commands.watch(state_on(WEBAPI))
      local suffix = " --launch-profile " .. vim.fn.shellescape("https")
      assert.are.same({
        "dotnet run --project " .. vim.fn.shellescape(WEBAPI) .. suffix,
        "dotnet watch run --project " .. vim.fn.shellescape(WEBAPI) .. suffix,
      }, opened)
      assert.are.equal(2, #asked, "the profile once, then the watch menu")
    end)

    it("does not ask for a profile to watch tests or a build", function()
      for _, what in ipairs({ "test", "build" }) do
        answers = { what }
        commands.watch(state_on(WEBAPI))
      end
      assert.are.same({
        "dotnet watch test --project " .. vim.fn.shellescape(WEBAPI),
        "dotnet watch build --project " .. vim.fn.shellescape(WEBAPI),
      }, opened)
      assert.are.equal(2, #asked, "only the watch menu, twice")
    end)

    it("runs as before when there is nothing to choose", function()
      commands.run_project(state_on(SINGLE))
      assert.are.same({ "dotnet run --project " .. vim.fn.shellescape(SINGLE) }, opened)
      assert.are.same({}, asked)
    end)

    it("starts nothing when the question is cancelled", function()
      answers = {}
      commands.run_project(state_on(WEBAPI))
      assert.are.same({}, opened)
    end)

    -- `func start` reads no launch profile: asking would be a question for nothing
    it("does not ask on r for a function app started with func start", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/Properties", "p")
      vim.fn.writefile(
        vim.fn.readfile(root .. "/fixtures/functions/InProcess/InProcess.csproj"),
        dir .. "/InProcess.csproj"
      )
      vim.fn.writefile(
        vim.fn.readfile(LAUNCH .. "/Webapi/Properties/launchSettings.json"),
        dir .. "/Properties/launchSettings.json"
      )
      stub(vim.fn, "executable", function()
        return 1
      end)
      stub(require("dotnet-tree.functions"), "warn_without_azurite", function() end)
      commands.run_project(state_on(dir .. "/InProcess.csproj"))
      assert.are.same({ "func start" }, opened)
      assert.are.same({}, asked)
      vim.fn.delete(dir, "rf")
    end)

    -- The question itself is asked inside debug.debug, after the project has
    -- been checked: see debug_spec
    it("leaves the profile of d to the debugger", function()
      commands.debug(state_on(WEBAPI))
      assert.are.same({ { path = WEBAPI } }, debugged)
      assert.are.same({}, asked)
    end)

    it("chooses again with L", function()
      remembered[WEBAPI] = "https"
      answers = { "http" }
      commands.choose_launch_profile(state_on(WEBAPI))
      assert.are.equal("http", remembered[WEBAPI])
    end)
  end)
end)

describe("store of launch profiles", function()
  local store = require("dotnet-tree.store")
  local state, stdpath, messages, notify

  before_each(function()
    state = vim.fn.tempname()
    stdpath, notify, messages = vim.fn.stdpath, vim.notify, {}
    vim.fn.stdpath = function(what)
      return what == "state" and state or stdpath(what)
    end
    vim.notify = function(msg)
      table.insert(messages, msg)
    end
  end)

  after_each(function()
    vim.fn.stdpath, vim.notify = stdpath, notify
    vim.fn.delete(state, "rf")
  end)

  it("keeps the choice per project, next to the solutions", function()
    assert.is_true(store.set_profile("/src/Api//Api.csproj", "https"))
    store.set_profile("/src/Web/Web.csproj", "http")
    store.set("/src", "/src/All.sln")
    assert.are.equal("https", store.get_profile("/src/Api/Api.csproj"), "the path is normalized")
    assert.are.equal("http", store.get_profile("/src/Web/Web.csproj"))
    assert.is_nil(store.get_profile("/src/Other/Other.csproj"))
    assert.are.equal("/src/All.sln", store.get("/src"))
  end)

  it("ignores a value that is not a profile name", function()
    vim.fn.mkdir(state .. "/dotnet-tree", "p")
    vim.fn.writefile({ '{"/src/Api/Api.csproj": 3}' }, state .. "/dotnet-tree/launch_profiles.json")
    assert.is_nil(store.get_profile("/src/Api/Api.csproj"))
  end)

  -- Writing over it would lose every other project's choice without a word
  it("moves a file it cannot read aside instead of writing over it", function()
    local file = state .. "/dotnet-tree/launch_profiles.json"
    vim.fn.mkdir(state .. "/dotnet-tree", "p")
    vim.fn.writefile({ '{"/src/Api/Api.csproj": "ht' }, file)
    assert.is_nil(store.get_profile("/src/Api/Api.csproj"))
    assert.are.equal(1, vim.fn.filereadable(file .. ".bak"))
    assert.matches("could not be read", messages[1], 1, true)
    store.set_profile("/src/Web/Web.csproj", "http")
    assert.are.equal("http", store.get_profile("/src/Web/Web.csproj"))
    assert.are.same({ '{"/src/Api/Api.csproj": "ht' }, vim.fn.readfile(file .. ".bak"))
  end)

  it("reports a choice it cannot write instead of raising", function()
    vim.fn.writefile({ "a file where the directory should be" }, state)
    local ok, err = store.set_profile("/src/Api/Api.csproj", "https")
    assert.is_false(ok)
    assert.truthy(err)
  end)
end)
