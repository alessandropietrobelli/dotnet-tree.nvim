-- Which launch profile `r`, `d` and `w` → run start a project with (#51).
--
-- `dotnet run` uses the first profile in `Properties/launchSettings.json`
-- unless told otherwise, and a web project usually has several (`http`,
-- `https`, a Docker one). With more than one that can be started, the choice is
-- asked once per project and remembered (store.lua); `L` asks again. With one
-- or none nothing is asked and nothing changes: that profile is what
-- `dotnet run` would use anyway.
local launch_settings = require("dotnet-tree.parser.launch_settings")
local store = require("dotnet-tree.store")

local M = {}

local function notify(message, level)
  vim.notify("[dotnet-tree] " .. message, level or vim.log.levels.INFO)
end

---@param project_path string
---@return string[]
local function names(project_path)
  return launch_settings.names(vim.fn.fnamemodify(project_path, ":h"))
end

---@param project_path string
---@param choices string[]
---@param cb fun(name: string)
local function ask(project_path, choices, cb)
  local default = choices[1]
  vim.ui.select(choices, {
    prompt = ("Launch profile for %s:"):format(vim.fn.fnamemodify(project_path, ":t:r")),
    format_item = function(name)
      -- The one `dotnet run` picks when it is not told
      return name == default and (name .. " (default)") or name
    end,
  }, function(choice)
    if choice then
      store.set_profile(project_path, choice)
      cb(choice)
    end
  end)
end

--- The profile to start `project_path` with, passed to `cb`: nil when the
--- project has one usable profile or none, so the default applies; otherwise
--- the one chosen before, as long as the file still has it, or else the answer
--- to a question that is then remembered. `cb` is not called when the question
--- is cancelled, which cancels the run.
---@param project_path string
---@param cb fun(name: string|nil)
function M.choose(project_path, cb)
  local choices = names(project_path)
  if #choices < 2 then
    cb(nil)
    return
  end
  local chosen = store.get_profile(project_path)
  if chosen and vim.tbl_contains(choices, chosen) then
    cb(chosen)
    return
  end
  ask(project_path, choices, cb)
end

--- Ask again which profile to use for `project_path` (`L`).
---@param project_path string
function M.pick(project_path)
  local choices = names(project_path)
  local project = vim.fn.fnamemodify(project_path, ":t:r")
  if #choices == 0 then
    notify(("%s has no launch profile that `r` and `d` can start"):format(project))
  elseif #choices == 1 then
    notify(("%s has one launch profile, %q: there is nothing to choose"):format(project, choices[1]))
  else
    ask(project_path, choices, function(name)
      notify(("%s starts with launch profile %q"):format(project, name))
    end)
  end
end

--- The arguments that select `name` for `dotnet run` and `dotnet watch run`,
--- with a leading space; empty for nil.
---@param name string|nil
---@return string
function M.args(name)
  return name and (" --launch-profile " .. vim.fn.shellescape(name)) or ""
end

return M
