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

  it("leaves other projects alone", function()
    assert.is_nil(detect("Plain/Plain.csproj"), "a Functions extension package is not the SDK")
    assert.is_nil(detect("Commented/Commented.csproj"), "a commented-out AzureFunctionsVersion")
    assert.is_nil(detect("Missing/Missing.csproj"))
    assert.is_nil(detect("Worker2"), "a solution folder, not a project file")
  end)
end)

describe("functions.uses_azurite", function()
  it("is true for UseDevelopmentStorage=true, with or without more settings", function()
    assert.is_true(functions.uses_azurite(FIXTURES .. "/Worker2"))
    assert.is_true(functions.uses_azurite(FIXTURES .. "/HostOnly"))
  end)

  it("is false for a real storage account, no file, or a file that is not JSON", function()
    assert.is_false(functions.uses_azurite(FIXTURES .. "/Worker1"))
    assert.is_false(functions.uses_azurite(FIXTURES .. "/InProcess"))
    assert.is_false(functions.uses_azurite(FIXTURES .. "/Commented"))
  end)
end)

describe("functions.azurite_listening", function()
  local uv = vim.uv or vim.loop
  local port, timeout

  before_each(function()
    port, timeout = functions.azurite_port, functions.connect_timeout_ms
  end)

  after_each(function()
    functions.azurite_port, functions.connect_timeout_ms = port, timeout
  end)

  local function check()
    local result
    functions.azurite_listening(function(listening)
      result = listening
    end)
    assert.is_true(vim.wait(3000, function()
      return result ~= nil
    end, 10))
    return result
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
    assert.is_false(check())
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

  it("runs an in-process app with func start in its folder", function()
    commands.run_project(state_on(FIXTURES .. "/InProcess/InProcess.csproj"))
    assert.are.same({ { cmd = "func start", label = "run InProcess", cwd = FIXTURES .. "/InProcess" } }, opened)
  end)

  it("does not start a function app without func, and says why", function()
    vim.fn.executable = function(name)
      return name == "func" and 0 or 1
    end
    commands.run_project(state_on(FIXTURES .. "/Worker2/Worker2.csproj"))
    assert.are.same({}, opened)
    assert.are.equal(1, #messages)
    assert.matches("Worker2 is an Azure Functions app", messages[1].msg)
    assert.are.equal(vim.log.levels.ERROR, messages[1].level)
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
