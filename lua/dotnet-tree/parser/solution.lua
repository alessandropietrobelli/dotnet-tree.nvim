-- Dispatcher over the two solution formats: classic .sln and XML-based .slnx.
-- Both parsers return the same contract, so callers stay format-agnostic.

local M = {}

local function is_slnx(path)
  return path:lower():match("%.slnx$") ~= nil
end

function M.parse(path)
  if is_slnx(path) then
    return require("dotnet-tree.parser.slnx").parse(path)
  end
  return require("dotnet-tree.parser.sln").parse(path)
end

function M.invalidate(path)
  if path == nil then
    require("dotnet-tree.parser.sln").invalidate()
    require("dotnet-tree.parser.slnx").invalidate()
    return
  end
  if is_slnx(path) then
    require("dotnet-tree.parser.slnx").invalidate(path)
  else
    require("dotnet-tree.parser.sln").invalidate(path)
  end
end

-- All solution files directly in `dir` (non-recursive). .slnx (the canonical
-- successor) is listed first, so it wins as the default when a stale .sln also
-- lingers in a migrated repo.
function M.find(dir)
  local results = vim.fn.globpath(dir, "*.slnx", false, true)
  vim.list_extend(results, vim.fn.globpath(dir, "*.sln", false, true))
  return results
end

return M
