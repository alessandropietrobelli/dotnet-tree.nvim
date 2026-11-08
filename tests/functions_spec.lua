-- Azure Functions apps (#57): which projects are function apps, which of them
-- `dotnet run` can start, and whether the Azurite they need is listening.

local functions = require("dotnet-tree.functions")

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/functions"

local function detect(rel)
  return functions.detect(FIXTURES .. "/" .. rel)
end

describe("functions.detect", function()
  it("lets dotnet run start an app on Worker SDK 2.x", function()
    local app = detect("Worker2/Worker2.csproj")
    assert.is_not_nil(app)
    assert.is_false(app.func)
    assert.are.equal(vim.fs.normalize(FIXTURES .. "/Worker2"), app.dir)
  end)

  it("starts an app on Worker SDK 1.x with func, its version in a child element", function()
    assert.is_true(detect("Worker1/Worker1.csproj").func)
  end)

  it("starts an in-process app with func", function()
    assert.is_true(detect("InProcess/InProcess.csproj").func)
  end)

  it("reads the Worker SDK version from Directory.Packages.props", function()
    assert.is_true(detect("Cpm/Fn/Fn.csproj").func, "1.17.4, set centrally")
  end)

  it("lets a VersionOverride win over the central version", function()
    assert.is_false(detect("Cpm/Override/Override.csproj").func, "2.0.5 overrides 1.17.4")
  end)

  it("knows a function app by its host.json alone", function()
    local app = detect("HostOnly/HostOnly.csproj")
    assert.is_not_nil(app)
    assert.is_false(app.func)
  end)

  it("knows a function app by the Worker SDK reference alone, and reads 1.x from it", function()
    assert.is_true(detect("WorkerOnly/WorkerOnly.csproj").func)
  end)

  it("takes a Worker SDK version with no number in it for a current one", function()
    assert.is_false(detect("Floating/Floating.csproj").func, "$(FunctionsWorkerSdkVersion)")
  end)

  it("accepts an F# project", function()
    assert.is_not_nil(detect("FsApp/FsApp.fsproj"))
  end)

  it("leaves other projects alone", function()
    assert.is_nil(detect("Plain/Plain.csproj"), "a Functions extension package is not the SDK")
    assert.is_nil(detect("Commented/Commented.csproj"), "a commented-out AzureFunctionsVersion")
    assert.is_nil(detect("Missing/Missing.csproj"))
    assert.is_nil(detect("Worker2"), "a directory, not a project file")
  end)
end)

describe("functions.uses_azurite", function()
  it("is true for UseDevelopmentStorage=true, with or without more settings", function()
    assert.is_true(functions.uses_azurite(FIXTURES .. "/Worker2"))
    assert.is_true(functions.uses_azurite(FIXTURES .. "/HostOnly"))
  end)

  it("reads a file func accepts and vim.json does not: a byte order mark, comments, any case", function()
    assert.is_true(functions.uses_azurite(FIXTURES .. "/Floating"))
  end)

  it("still finds the setting in a file that is not JSON at all", function()
    assert.is_true(functions.uses_azurite(FIXTURES .. "/Commented"), "a closing brace is missing")
  end)

  it("is false for a real storage account, or no file", function()
    assert.is_false(functions.uses_azurite(FIXTURES .. "/Worker1"))
    assert.is_false(functions.uses_azurite(FIXTURES .. "/InProcess"))
  end)
end)

describe("functions.azurite_listening", function()
  local uv = vim.uv or vim.loop
  local port, timeout, host

  before_each(function()
    port, timeout, host = functions.azurite_port, functions.connect_timeout_ms, functions.azurite_host
  end)

  after_each(function()
    functions.azurite_port, functions.connect_timeout_ms, functions.azurite_host = port, timeout, host
  end)

  -- The answer, and the reason the check could not be made, if any. Fails
  -- unless `done` is called exactly once.
  local function check()
    local calls = {}
    functions.azurite_listening(function(listening, problem)
      table.insert(calls, { listening, problem })
    end)
    assert.is_true(vim.wait(3000, function()
      return #calls > 0
    end, 10))
    vim.wait(100)
    assert.are.equal(1, #calls, "done is called once")
    return calls[1][1], calls[1][2]
  end

  -- A port that was free a moment ago: bind to 0, read the port, close.
  local function free_port()
    local server = uv.new_tcp()
    server:bind("127.0.0.1", 0)
    local free = server:getsockname().port
    server:close()
    return free
  end

  it("answers true when something accepts connections", function()
    local server = uv.new_tcp()
    server:bind("127.0.0.1", 0)
    server:listen(8, function()
      local client = uv.new_tcp()
      server:accept(client)
      client:close()
    end)
    functions.azurite_port = server:getsockname().port
    local listening = check()
    server:close()
    assert.is_true(listening)
  end)

  it("answers false when nothing listens", function()
    functions.azurite_port = free_port()
    local listening, problem = check()
    assert.is_false(listening)
    assert.is_nil(problem)
  end)

  it("answers false when no answer comes in time", function()
    functions.azurite_host = "192.0.2.1" -- TEST-NET-1: routed nowhere
    functions.connect_timeout_ms = 50
    local started = vim.uv.hrtime()
    local listening, problem = check()
    assert.is_false(listening)
    assert.is_nil(problem)
    assert.is_true((vim.uv.hrtime() - started) / 1e6 < 2000)
  end)

  it("tells a check it could not make from Azurite not listening", function()
    functions.azurite_host = "localhost" -- not an IP address: libuv refuses it
    local listening, problem = check()
    assert.is_false(listening)
    assert.is_string(problem)
  end)

  it("warns only when the app needs Azurite and it is not there", function()
    local warnings = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      table.insert(warnings, msg)
    end
    functions.azurite_port = free_port()
    functions.warn_without_azurite(FIXTURES .. "/Worker1", "Worker1") -- a real account
    functions.warn_without_azurite(FIXTURES .. "/Worker2", "Worker2")
    vim.wait(3000, function()
      return #warnings > 0
    end, 10)
    vim.wait(100)
    vim.notify = notify
    assert.are.equal(1, #warnings)
    assert.matches("Worker2 uses UseDevelopmentStorage=true", warnings[1])

    warnings = {}
    vim.notify = function(msg)
      table.insert(warnings, msg)
    end
    functions.azurite_host = "localhost"
    functions.warn_without_azurite(FIXTURES .. "/Worker2", "Worker2")
    vim.wait(3000, function()
      return #warnings > 0
    end, 10)
    vim.notify = notify
    assert.matches("could not check whether Azurite is listening", warnings[1])
  end)
end)

-- `r`, `t` and `w` through commands.lua, with neo-tree and the terminal split
-- standing in: what is checked is the command and the folder it starts in.
describe("run, test and watch", function()
  local opened, messages, saved, commands

  local function state_on(path)
    local node = {
      extra = { kind = "project", project = { path = path } },
      get_parent_id = function() end,
    }
    return {
      tree = {
        get_node = function()
          return node
        end,
      },
    }
  end

  local function stub(tbl, key, value)
    table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
    tbl[key] = value
  end

  before_each(function()
    opened, messages, saved = {}, {}, {}
    package.loaded["neo-tree.sources.common.commands"] = {}
    package.loaded["dotnet-tree.commands"] = nil
    local terminal = require("dotnet-tree.terminal")
    stub(terminal, "open", function(cmd, label, cwd)
      table.insert(opened, { cmd = cmd, label = label, cwd = cwd })
    end)
    stub(vim, "notify", function(msg, level)
      table.insert(messages, { msg = msg, level = level })
    end)
    stub(functions, "warn_without_azurite", function(dir, name)
      table.insert(messages, { msg = "azurite? " .. name .. " " .. dir })
    end)
    stub(vim.fn, "executable", function()
      return 1
    end)
    commands = require("dotnet-tree.commands")
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i].tbl[saved[i].key] = saved[i].value
    end
    package.loaded["neo-tree.sources.common.commands"] = nil
    package.loaded["dotnet-tree.commands"] = nil
  end)

  it("runs any project from its own folder with dotnet run", function()
    local path = vim.fs.normalize(FIXTURES .. "/Plain/Plain.csproj")
    commands.run_project(state_on(path))
    assert.are.same({
      { cmd = "dotnet run --project " .. vim.fn.shellescape(path), label = "run Plain", cwd = FIXTURES .. "/Plain" },
    }, opened)
    assert.are.same({}, messages, "no Azurite check for a project that is not a function app")
  end)

  it("runs a Worker SDK 2.x app with dotnet run, and checks for Azurite", function()
    local path = vim.fs.normalize(FIXTURES .. "/Worker2/Worker2.csproj")
    commands.run_project(state_on(path))
    assert.are.equal("dotnet run --project " .. vim.fn.shellescape(path), opened[1].cmd)
    assert.are.equal(FIXTURES .. "/Worker2", opened[1].cwd)
    assert.are.same({ { msg = "azurite? Worker2 " .. FIXTURES .. "/Worker2" } }, messages)
  end)

  it("runs an in-process app with func start in its folder, and checks for Azurite", function()
    commands.run_project(state_on(FIXTURES .. "/InProcess/InProcess.csproj"))
    assert.are.same({ { cmd = "func start", label = "run InProcess", cwd = FIXTURES .. "/InProcess" } }, opened)
    assert.are.equal(1, #messages)
    assert.matches("^azurite%? InProcess", messages[1].msg)
  end)

  it("runs a Worker SDK 1.x app with func start", function()
    commands.run_project(state_on(FIXTURES .. "/Worker1/Worker1.csproj"))
    assert.are.equal("func start", opened[1].cmd)
  end)

  it("does not start a function app without func, and says why", function()
    vim.fn.executable = function(name)
      return name == "func" and 0 or 1
    end
    commands.run_project(state_on(FIXTURES .. "/Worker2/Worker2.csproj"))
    assert.are.same({}, opened)
    assert.are.equal(1, #messages)
    assert.matches("Worker2 is an Azure Functions app", messages[1].msg)
    assert.matches("functions%-run%-local", messages[1].msg, "says where to get it")
    assert.are.equal(vim.log.levels.ERROR, messages[1].level)
  end)

  it("watches a Worker SDK 2.x app, with the same checks as r", function()
    stub(vim.ui, "select", function(_, _, on_choice)
      on_choice("run")
    end)
    commands.watch(state_on(FIXTURES .. "/Worker2/Worker2.csproj"))
    assert.matches("^dotnet watch run %-%-project", opened[1].cmd)
    assert.matches("^azurite%? Worker2", messages[1].msg)
  end)

  it("refuses to watch an app dotnet watch cannot start, and points to r", function()
    stub(vim.ui, "select", function(_, _, on_choice)
      on_choice("run")
    end)
    commands.watch(state_on(FIXTURES .. "/InProcess/InProcess.csproj"))
    assert.are.same({}, opened)
    assert.matches("Press `r` instead", messages[1].msg)
    assert.are.equal(vim.log.levels.ERROR, messages[1].level)
  end)

  it("watches the tests of a function app it would not run", function()
    stub(vim.ui, "select", function(_, _, on_choice)
      on_choice("test")
    end)
    commands.watch(state_on(FIXTURES .. "/InProcess/InProcess.csproj"))
    assert.matches("^dotnet watch test", opened[1].cmd)
  end)

  it("tests and watches from the project's folder", function()
    local path = FIXTURES .. "/Plain/Plain.csproj"
    commands.test(state_on(path))
    stub(vim.ui, "select", function(_, _, on_choice)
      on_choice("run")
    end)
    commands.watch(state_on(path))
    assert.are.same({ FIXTURES .. "/Plain", FIXTURES .. "/Plain" }, { opened[1].cwd, opened[2].cwd })
    assert.are.equal("watch run Plain", opened[2].label)
  end)
end)

-- :checkhealth, with vim.health recording what it reports.
describe("health", function()
  local health = require("dotnet-tree.health")
  local reported, saved

  local function stub(tbl, key, value)
    table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
    tbl[key] = value
  end

  before_each(function()
    reported, saved = {}, {}
    for _, kind in ipairs({ "start", "ok", "warn", "error" }) do
      stub(vim.health, kind, function(msg)
        table.insert(reported, kind .. ": " .. msg)
      end)
    end
    stub(vim.fn, "executable", function()
      return 1
    end)
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i].tbl[saved[i].key] = saved[i].value
    end
  end)

  local function listening(answer, problem)
    stub(functions, "azurite_listening", function(done)
      vim.schedule(function()
        done(answer, problem)
      end)
    end)
  end

  it("says nothing about Azure Functions when no solution has a function app", function()
    health.check_functions({ FIXTURES .. "/Web.slnx" })
    assert.are.same({}, reported)
  end)

  it("reports func and Azurite once for a solution with a function app", function()
    listening(true)
    health.check_functions({ FIXTURES .. "/Fn.slnx", FIXTURES .. "/Fn.slnx" })
    assert.are.same({
      "start: dotnet-tree: Azure Functions",
      "ok: Azure Functions Core Tools found (func)",
      "ok: Azurite is listening on 127.0.0.1:10000",
    }, reported)
  end)

  it("warns when func is missing or Azurite is down", function()
    listening(false)
    vim.fn.executable = function()
      return 0
    end
    health.check_functions({ FIXTURES .. "/Fn.slnx" })
    assert.are.equal("warn: func not found on PATH", reported[2])
    assert.matches("^warn: Azurite not found on PATH and nothing is listening", reported[3])
  end)

  it("says when Azurite could not be checked, rather than that it is down", function()
    listening(false, "Invalid IP address")
    health.check_functions({ FIXTURES .. "/Fn.slnx" })
    assert.matches("^warn: could not check whether Azurite is listening .*Invalid IP address", reported[3])
  end)

  it("names a project the solution lists but the disk does not have", function()
    health.check_solution(FIXTURES .. "/Fn.slnx")
    assert.are.equal("ok:   " .. FIXTURES .. "/Fn.slnx", reported[1])
    assert.are.equal(2, #reported)
    assert.matches("^warn:     listed but not on disk: .*/Gone/Gone%.csproj$", reported[2])
  end)

  it("warns about a solution it cannot read", function()
    health.check_solution(FIXTURES .. "/Missing.slnx")
    assert.matches("^warn:   .*/Missing%.slnx could not be read", reported[1])
  end)
end)
