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
--   focus back, a terminal   ask git again in the background: a commit or a
--   closed (lazygit)         checkout done outside may have changed it (#61)
--
-- neo-tree is required lazily, so this module can be tested without it.
local M = {}

local SOURCE = "dotnet-tree"

-- Directories the tree never lists (tree.lua): writing a file in one changes
-- nothing on screen.
local IGNORED_DIRS = { bin = true, obj = true, [".vs"] = true, [".git"] = true, node_modules = true }

-- neo-tree's manager, or nil before neo-tree is loaded: then there is no tree
-- to update and nothing to report.
local function manager()
  local ok, mgr = pcall(require, "neo-tree.sources.manager")
  return ok and mgr or nil
end

-- Run `fn`, reporting a failure once instead of on every keystroke or save.
local function guarded(what, fn)
  local ok, err = pcall(fn)
  if not ok then
    require("dotnet-tree.git").warn_once("refresh-" .. what, what .. " failed: " .. tostring(err))
  end
end

--- Walk and parse again, keeping the focus where it was: neo-tree's refresh
--- may move it into the tree window.
function M.rebuild()
  local mgr = manager()
  if not mgr then
    return
  end
  local prev_win = vim.api.nvim_get_current_win()
  guarded("rebuilding the tree", function()
    mgr.refresh(SOURCE)
  end)
  if vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
end

--- Render the nodes the tree already has, so components read their data again.
function M.redraw()
  local mgr = manager()
  if not mgr then
    return
  end
  guarded("redrawing the tree", function()
    mgr.redraw(SOURCE)
  end)
end

-- One rebuild for all the writes of a `:wa`, after they are done.
local rebuild_scheduled = false
local function schedule_rebuild()
  if rebuild_scheduled then
    return
  end
  rebuild_scheduled = true
  vim.schedule(function()
    rebuild_scheduled = false
    M.rebuild()
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
---@param path string absolute
function M.on_write(path)
  if not path or path == "" then
    return
  end
  local mgr = manager()
  if not mgr then
    return
  end
  path = vim.fs.normalize(path)
  local reveal = require("dotnet-tree.reveal")
  local rebuild, fetch = false, {}
  guarded("updating the tree after a write", function()
    mgr._for_each_state(SOURCE, function(state)
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
    schedule_rebuild()
    return
  end
  for sln_dir in pairs(fetch) do
    M.git(sln_dir)
  end
end

--- Ask git again for every open tree's solution, rebuilding only the ones
--- whose status changed: the repository may have changed outside Neovim (a
--- commit in another terminal, lazygit in a float).
function M.on_outside_change()
  local mgr = manager()
  if not mgr then
    return
  end
  local roots = {}
  guarded("checking git status", function()
    mgr._for_each_state(SOURCE, function(state)
      if state.dotnet_sln and state.dotnet_index then
        roots[vim.fs.dirname(vim.fs.normalize(state.dotnet_sln))] = true
      end
    end)
  end)
  for sln_dir in pairs(roots) do
    M.git(sln_dir)
  end
end

return M
