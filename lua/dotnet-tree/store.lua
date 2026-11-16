-- What is remembered across sessions, in Neovim's state directory: the solution
-- chosen for each working directory, and the launch profile chosen for each
-- project (#51).
local M = {}

local function file_path(name)
  return vim.fn.stdpath("state") .. "/dotnet-tree/" .. name
end

local function notify(message)
  vim.notify("[dotnet-tree] " .. message, vim.log.levels.WARN)
end

-- A file that cannot be read is moved aside rather than written over on the
-- next save, which would lose every other entry in it without a word.
local function read(name)
  local p = file_path(name)
  if vim.fn.filereadable(p) == 0 then
    return {}
  end
  local content = table.concat(vim.fn.readfile(p), "\n")
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    return data
  end
  local aside = p .. ".bak"
  os.rename(p, aside)
  notify(("%s could not be read and was moved to %s; what it remembered is asked again"):format(p, aside))
  return {}
end

---@return boolean ok
---@return string|nil err
local function write(name, data)
  local p = file_path(name)
  return pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    -- Written next to it and renamed over it, so a crash halfway leaves the old file
    local tmp = p .. ".tmp"
    vim.fn.writefile({ vim.json.encode(data) }, tmp)
    assert(os.rename(tmp, p))
  end)
end

local SOLUTIONS = "solutions.json"
local PROFILES = "launch_profiles.json"

function M.get(cwd)
  return read(SOLUTIONS)[vim.fs.normalize(cwd)]
end

function M.set(cwd, sln_path)
  local data = read(SOLUTIONS)
  data[vim.fs.normalize(cwd)] = vim.fs.normalize(sln_path)
  local ok, err = write(SOLUTIONS, data)
  if not ok then
    notify("could not remember the solution chosen: " .. tostring(err))
  end
end

--- The launch profile chosen for a project, if any.
---@param project_path string
---@return string|nil
function M.get_profile(project_path)
  local name = read(PROFILES)[vim.fs.normalize(project_path)]
  return type(name) == "string" and name or nil
end

---@param project_path string
---@param name string
---@return boolean ok
---@return string|nil err why it could not be remembered
function M.set_profile(project_path, name)
  local data = read(PROFILES)
  data[vim.fs.normalize(project_path)] = name
  return write(PROFILES, data)
end

return M
