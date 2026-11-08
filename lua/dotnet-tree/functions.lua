-- Azure Functions apps: how `r` starts one, and what it needs running (#57).
--
-- A function app is started by the Functions host, `func start`, not by the
-- app itself. With `Microsoft.Azure.Functions.Worker.Sdk` 2.x, `dotnet run`
-- does that on its own: the SDK sets RunCommand to `func` and its working
-- directory to $(OutDir). In the default layout OutDir is relative
-- (`bin/Debug/net8.0/`), so the host is looked for under the directory
-- `dotnet run` was started in -- which is why it fails from the solution root
-- and works from the project's folder, where commands.lua starts it. With
-- `UseArtifactsOutput` OutDir is absolute and either works.
--
-- `dotnet run` cannot start the host for an in-process app
-- (`Microsoft.NET.Sdk.Functions`) or on Worker SDK 1.x, which set no
-- RunCommand: those are started with `func start`, from the same folder.
local M = {}

local IN_PROCESS_SDK = "microsoft.net.sdk.functions"
local WORKER_SDK = "microsoft.azure.functions.worker.sdk"

-- The ports Azurite listens on by default: blob, queue, table. The host keeps
-- its keys and leases in blob storage, so that is the port checked. Without it
-- the host starts, reports its storage unhealthy, and the triggers that need
-- storage (timers, queues, blobs) fail.
M.azurite_host = "127.0.0.1"
M.azurite_port = 10000
M.connect_timeout_ms = 1000

--- The version a project gets for the package `name`, as the tree shows it:
--- the project's VersionOverride, then a Version written in the project, then
--- the central one. "" when the project references it without a version
--- anyone states, nil when it does not reference it.
---@param csproj table parsed by parser/csproj.lua
---@param name string package id, lowercase
---@return string|nil
local function package_version(csproj, name)
  for _, pkg in ipairs(csproj.packages) do
    if pkg.name:lower() == name then
      local cpm = require("dotnet-tree.parser.cpm")
      return cpm.resolve(pkg, cpm.versions_for(csproj.dir)) or ""
    end
  end
  return nil
end

--- What kind of function app the project at `csproj_path` is, or nil when it
--- is not one. A project is a function app when its file sets
--- `<AzureFunctionsVersion>`, it references `Microsoft.NET.Sdk.Functions` or
--- `Microsoft.Azure.Functions.Worker.Sdk`, or its folder has a `host.json`.
---
--- `func` is true when `dotnet run` cannot start it and `r` has to run
--- `func start` instead: an in-process app, or Worker SDK 1.x. The major
--- version is the first number in the version as written, so `1.*` and
--- `[1.17,2.0)` count as 1.x; a version with no number in it (a
--- `$(Property)`, or none stated anywhere) is taken to be a current one.
---@param csproj_path string
---@return { func: boolean, dir: string }|nil
function M.detect(csproj_path)
  if not csproj_path:match("%.[cf]sproj$") then
    return nil
  end
  local csproj = require("dotnet-tree.parser.csproj").parse(csproj_path)
  if not csproj then
    return nil
  end
  -- Read again for the one property csproj.lua does not keep. Should the
  -- file go away in between, the package references and host.json still
  -- decide.
  local declared = false
  local f = io.open(csproj.path, "r")
  if f then
    local content = f:read("*a"):gsub("<!%-%-.-%-%->", "")
    f:close()
    declared = content:find("<AzureFunctionsVersion>", 1, true) ~= nil
  end
  local in_process = package_version(csproj, IN_PROCESS_SDK) ~= nil
  local worker = package_version(csproj, WORKER_SDK)
  if not declared and not in_process and not worker and vim.fn.filereadable(csproj.dir .. "/host.json") == 0 then
    return nil
  end
  local worker_major = worker and tonumber(worker:match("%d+"))
  return {
    dir = csproj.dir,
    func = in_process or (worker_major ~= nil and worker_major < 2),
  }
end

local DEV_STORAGE = "usedevelopmentstorage=true"

--- Whether the app in `dir` keeps its host storage in Azurite: the
--- AzureWebJobsStorage value in its local.settings.json contains
--- `UseDevelopmentStorage=true`, matched ignoring case as connection string
--- keys are. A missing file says no.
---
--- Core Tools reads the file with a lenient parser, which accepts a byte order
--- mark and comments; vim.json.decode accepts neither. A file it cannot decode
--- is searched for the setting as text instead, so the warning is not lost
--- for a file `func` itself reads fine.
---@param dir string
---@return boolean
function M.uses_azurite(dir)
  local f = io.open(dir .. "/local.settings.json", "r")
  if not f then
    return false
  end
  local content = f:read("*a"):gsub("^\239\187\191", "")
  f:close()
  local ok, settings = pcall(vim.json.decode, content)
  if not ok then
    return content:lower():find('"azurewebjobsstorage"%s*:%s*"[^"]*' .. vim.pesc(DEV_STORAGE)) ~= nil
  end
  local values = type(settings) == "table" and settings.Values or nil
  local storage = type(values) == "table" and values.AzureWebJobsStorage or nil
  return type(storage) == "string" and storage:lower():find(DEV_STORAGE, 1, true) ~= nil
end

--- Whether something accepts connections on Azurite's blob port, without
--- blocking: `done` is called once, on the main loop. `listening` is false
--- both when the connection was refused and when no answer came in time;
--- `problem` is set only when the check itself could not be made (an address
--- that is not an IP, no socket left), which says nothing about Azurite.
---@param done fun(listening: boolean, problem: string|nil)
function M.azurite_listening(done)
  local uv = vim.uv or vim.loop
  local tcp, timer = uv.new_tcp(), uv.new_timer()
  if not tcp or not timer then
    if tcp then
      tcp:close()
    end
    if timer then
      timer:close()
    end
    vim.schedule(function()
      done(false, "no socket available")
    end)
    return
  end
  local finished = false
  local function finish(listening, problem)
    if finished then
      return
    end
    finished = true
    timer:stop()
    timer:close()
    if not tcp:is_closing() then
      tcp:close()
    end
    vim.schedule(function()
      done(listening, problem)
    end)
  end
  timer:start(M.connect_timeout_ms, 0, function()
    finish(false)
  end)
  local ok, started, err = pcall(tcp.connect, tcp, M.azurite_host, M.azurite_port, function(cerr)
    finish(cerr == nil)
  end)
  if not ok or not started then
    finish(false, tostring(ok and err or started))
  end
end

--- Warn, once the check answers, when the app in `dir` needs Azurite and it is
--- not listening. The warning is advisory: the app is started anyway.
---@param dir string
---@param name string the project's name, for the message
function M.warn_without_azurite(dir, name)
  if not M.uses_azurite(dir) then
    return
  end
  M.azurite_listening(function(listening, problem)
    local where = ("%s:%d"):format(M.azurite_host, M.azurite_port)
    if problem then
      vim.notify(
        ("[dotnet-tree] could not check whether Azurite is listening on %s: %s"):format(where, problem),
        vim.log.levels.WARN
      )
    elseif not listening then
      local msg = "[dotnet-tree] %s uses UseDevelopmentStorage=true, but Azurite is not listening on %s. "
        .. "Start it with `azurite`."
      vim.notify(msg:format(name, where), vim.log.levels.WARN)
    end
  end)
end

return M
