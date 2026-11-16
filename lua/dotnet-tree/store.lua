-- What is remembered across sessions, in Neovim's state directory: the solution
-- chosen for each working directory, and the launch profile chosen for each
-- project (#51).
local M = {}

local function file_path(name)
  return vim.fn.stdpath("state") .. "/dotnet-tree/" .. name
end

local function read(name)
  local p = file_path(name)
  if vim.fn.filereadable(p) == 0 then
    return {}
  end
  local content = table.concat(vim.fn.readfile(p), "\n")
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

local function write(name, data)
  local p = file_path(name)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(data) }, p)
end

local SOLUTIONS = "solutions.json"
local PROFILES = "launch_profiles.json"

function M.get(cwd)
  return read(SOLUTIONS)[vim.fs.normalize(cwd)]
end

function M.set(cwd, sln_path)
  local data = read(SOLUTIONS)
  data[vim.fs.normalize(cwd)] = vim.fs.normalize(sln_path)
  write(SOLUTIONS, data)
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
function M.set_profile(project_path, name)
  local data = read(PROFILES)
  data[vim.fs.normalize(project_path)] = name
  write(PROFILES, data)
end

return M
