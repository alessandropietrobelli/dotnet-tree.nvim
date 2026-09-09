-- `Properties/launchSettings.json`: the profile `dotnet run` would use.
--
-- This is the file that makes `r` and `d` disagree (#33). `r` runs
-- `dotnet run`, which reads it; `d` starts the built assembly, which does not.
-- On a `dotnet new webapi` the profile sets `ASPNETCORE_ENVIRONMENT` to
-- Development, so the same project debugged with `d` came up in Production:
-- `IsDevelopment()` false, no OpenAPI endpoints, `appsettings.Development.json`
-- never read.
--
-- What is read is deliberately narrow: one profile, four fields, no MSBuild
-- evaluation and no token expansion. Anything this cannot understand leaves
-- `d` behaving exactly as it did before the file existed -- an unreadable
-- profile is not a reason to raise, and it is not a licence to guess either.
--
-- Two things here are measured rather than assumed, and both would be wrong
-- if written the obvious way. See M.profile and M.read.

local M = {}

-- `commandName` values other than this one start something else -- Docker, IIS
-- Express -- and none of them is the assembly `d` just built.
local COMMAND_NAME = "Project"

-- Fields consumed below. Everything else in a profile (`launchBrowser`,
-- `dotnetRunMessages`, `hotReloadEnabled`, `sslPort`) belongs to `dotnet run`
-- or to a browser, not to a debugger launch.
local ENV_URLS = "ASPNETCORE_URLS"

-- An MSBuild-style token comes out of a JSON file verbatim, and expanding it
-- would mean evaluating MSBuild. Same rule as debug.lua's is_unevaluated: a
-- value that cannot be resolved is dropped, not guessed at.
local function is_unevaluated(value)
  return type(value) == "string" and value:find("$(", 1, true) ~= nil
end

--- Split `commandLineArgs` the way a shell would, honouring double quotes.
---
--- launchSettings holds the arguments as one string, and dap wants a list. A
--- plain split on whitespace breaks `--path "C:\Program Files\x"`, which is the
--- shape this field usually has when it has quotes at all.
---@param text string
---@return string[]
function M.split_args(text)
  local args = {}
  local current, quoted, has = {}, false, false
  local function flush()
    if has then
      table.insert(args, table.concat(current))
      current, has = {}, false
    end
  end
  for i = 1, #text do
    local c = text:sub(i, i)
    if c == '"' then
      quoted = not quoted
      has = true
    elseif c:match("%s") and not quoted then
      flush()
    else
      table.insert(current, c)
      has = true
    end
  end
  flush()
  return args
end

--- The profile `dotnet run` would pick, out of a decoded launchSettings table.
---
--- "The first profile in the file" is not something a decoded table can
--- answer: `vim.json.decode` returns a Lua table and `pairs` does not iterate
--- in file order -- measured on a four-profile file, `pairs` gave
--- beta, zeta, middle, alpha for a file written zeta, alpha, middle, beta.
--- So the order is recovered from the raw text, by where each candidate's key
--- appears in it.
---
--- And the order matters, because `dotnet run` does not pick the profile named
--- after the project. Measured on a project with three `Project` profiles --
--- one first in the file, one named after the project, one alphabetically
--- first -- `dotnet run` with no `--launch-profile` used the first in the
--- file. Picking the project-named one would have made `d` disagree with `r`
--- on exactly the file that exists to make them agree.
---
--- The limit: a profile name that also occurs earlier in the text as a string
--- value would be ordered too early. Names not found in the text at all fall
--- back to alphabetical order, so the choice is deterministic either way.
---@param decoded table the whole decoded launchSettings.json
---@param raw string|nil the file's text, for recovering file order
---@return string|nil name
---@return table|nil profile
function M.profile(decoded, raw)
  if type(decoded) ~= "table" or type(decoded.profiles) ~= "table" then
    return nil, nil
  end

  local candidates = {}
  for name, profile in pairs(decoded.profiles) do
    if type(profile) == "table" and profile.commandName == COMMAND_NAME then
      local at = raw and raw:find('"' .. vim.pesc(name) .. '"%s*:')
      table.insert(candidates, { name = name, profile = profile, at = at })
    end
  end
  if #candidates == 0 then
    return nil, nil
  end

  table.sort(candidates, function(a, b)
    if a.at and b.at and a.at ~= b.at then
      return a.at < b.at
    end
    if (a.at == nil) ~= (b.at == nil) then
      return a.at ~= nil
    end
    return a.name < b.name
  end)

  return candidates[1].name, candidates[1].profile
end

--- What the profile declares, in the shape a dap launch configuration wants.
---
--- `env` and not `environmentVariables`, which is the whole point of doing this
--- carefully: `environmentVariables` is the key inside launchSettings.json and
--- the one vsdbg takes, and netcoredbg ignores it without saying so. Driven by
--- hand over DAP against netcoredbg 3.1.3-1, a launch carrying
--- `environmentVariables` answered success and passed nothing to the process;
--- the same launch carrying `env` passed it.
---@param profile table
---@param dir string the project directory, for resolving a relative cwd
---@return table settings { env, args, cwd } -- each nil when not declared
function M.settings(profile, dir)
  local settings = {}

  local env = {}
  local declared = profile.environmentVariables
  if type(declared) == "table" then
    for name, value in pairs(declared) do
      -- JSON allows a number or a boolean here; the environment does not.
      local kind = type(value)
      if kind == "string" and not is_unevaluated(value) then
        env[name] = value
      elseif kind == "number" or kind == "boolean" then
        env[name] = tostring(value)
      end
    end
  end

  -- `applicationUrl` is the profile's own field, not an environment variable.
  -- It loses to an explicit ASPNETCORE_URLS: a profile that sets both means
  -- the variable.
  if type(profile.applicationUrl) == "string" and not is_unevaluated(profile.applicationUrl) then
    env[ENV_URLS] = env[ENV_URLS] or profile.applicationUrl
  end
  if next(env) then
    settings.env = env
  end

  if type(profile.commandLineArgs) == "string" and not is_unevaluated(profile.commandLineArgs) then
    local args = M.split_args(profile.commandLineArgs)
    if #args > 0 then
      settings.args = args
    end
  end

  -- Relative to the project directory, which is what `dotnet run` resolves it
  -- against. An absolute one is used as written.
  local cwd = profile.workingDirectory
  if type(cwd) == "string" and cwd ~= "" and not is_unevaluated(cwd) then
    local absolute = cwd:sub(1, 1) == "/" or cwd:match("^%a:[/\\]") ~= nil
    settings.cwd = vim.fs.normalize(absolute and cwd or (dir .. "/" .. cwd))
  end

  return settings
end

--- Read the launch profile for a project, or nil when there is nothing usable.
---
--- Under `pcall`, and not as caution for its own sake: `vim.json.decode`
--- rejects both comments and a trailing comma, and real launchSettings.json
--- files carry them -- easy-dotnet.nvim maps the filename to `json5`, which is
--- what having met them looks like. A file this cannot read leaves `d` exactly
--- as it was.
---@param dir string the project directory
---@return table|nil settings { env, args, cwd }
---@return string|nil name the profile the settings came from
function M.read(dir)
  local path = vim.fs.normalize(dir) .. "/Properties/launchSettings.json"
  if vim.fn.filereadable(path) == 0 then
    return nil, nil
  end

  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then
    return nil, nil
  end

  local name, profile = M.profile(decoded, raw)
  if not profile then
    return nil, nil
  end

  local settings = M.settings(profile, dir)
  if not next(settings) then
    return nil, nil
  end
  return settings, name
end

return M
