local M = {}

local function file_path()
  return vim.fn.stdpath("state") .. "/dotnet-tree/solutions.json"
end

local function read()
  local p = file_path()
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

local function write(data)
  local p = file_path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(data) }, p)
end

function M.get(cwd)
  local data = read()
  return data[vim.fs.normalize(cwd)]
end

function M.set(cwd, sln_path)
  local data = read()
  data[vim.fs.normalize(cwd)] = vim.fs.normalize(sln_path)
  write(data)
end

return M
