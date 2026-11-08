-- How much of the tree an event has to redo.
--
-- A rebuild walks every project directory and parses every project again, so
-- it is kept for the events that can change what the tree lists. The others
-- get less (#49):
--
--   diagnostics changed      redraw: the counts come from their own index
--   a file the tree shows    ask git again in the background; rebuild only
--   was written              when the status changed
--   a new file was written   rebuild, so it shows up
--   under a project
--
-- neo-tree is required lazily, so this module can be tested without it.
local M = {}

local SOURCE = "dotnet-tree"

-- Directories the tree never lists (tree.lua): writing a file in one changes
-- nothing on screen.
local IGNORED_DIRS = { bin = true, obj = true, [".vs"] = true, [".git"] = true, node_modules = true }

local function manager()
  return require("neo-tree.sources.manager")
end

--- Walk and parse again, keeping the focus where it was: neo-tree's refresh
--- may move it into the tree window.
function M.rebuild()
  local prev_win = vim.api.nvim_get_current_win()
  pcall(function()
    manager().refresh(SOURCE)
  end)
  if vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
end

--- Render the nodes the tree already has, so components read their data again.
function M.redraw()
  pcall(function()
    manager().redraw(SOURCE)
  end)
end

--- Ask git for the status of the solution in `sln_dir`, and rebuild when it
--- changed. Called after every rebuild, which only paints the status known
--- before it.
---@param sln_dir string
function M.git(sln_dir)
  require("dotnet-tree.git").fetch(sln_dir, M.rebuild)
end

-- The directories holding a project, from an index built by reveal.index.
local function project_dirs(index)
  local dirs = {}
  for path in pairs(index) do
    if path:match("%.[cfv][sb]?proj$") then
      dirs[vim.fs.dirname(path)] = true
    end
  end
  return dirs
end

--- Whether a file the tree does not show yet would be listed by a rebuild:
--- it sits under a directory the tree lists or under a project's directory,
--- and not under bin/, obj/ or another directory the walk skips.
---@param index table<string, string>
---@param path string normalized
---@return boolean
local function would_list(index, path)
  local dirs = project_dirs(index)
  local dir = vim.fs.dirname(path)
  while dir and dir ~= "" do
    if IGNORED_DIRS[vim.fs.basename(dir)] then
      return false
    end
    if index[dir] or dirs[dir] then
      return true
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return false
end

--- What writing `path` does to the tree of each open dotnet-tree.
---@param path string
function M.on_write(path)
  if not path or path == "" then
    return
  end
  path = vim.fs.normalize(path)
  local reveal = require("dotnet-tree.reveal")
  local rebuild, fetch = false, {}
  pcall(function()
    manager()._for_each_state(SOURCE, function(state)
      local index = state.dotnet_index
      if not index or not state.dotnet_sln then
        return
      end
      if reveal.lookup(index, path) then
        fetch[vim.fs.dirname(vim.fs.normalize(state.dotnet_sln))] = true
      elseif would_list(index, path) then
        rebuild = true
      end
    end)
  end)
  if rebuild then
    -- The rebuild asks git itself.
    M.rebuild()
    return
  end
  for sln_dir in pairs(fetch) do
    M.git(sln_dir)
  end
end

return M
