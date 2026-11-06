-- Finding a file in the tree: `:Neotree reveal` and `follow_current_file`.
--
-- neo-tree reveals a path by focusing the node whose id is that path. That is
-- how the filesystem source names its nodes, but not this one: a file here is
-- `dotnet:proj:<guid>:file:<path>`, because the id has to say which project it
-- sits under. So every lookup goes through an index from path to node id,
-- built once per tree and kept on the state. Following the current file is
-- then a table lookup, not a rebuild, which matters because a rebuild rescans
-- every project directory and would run on each buffer switch.

local M = {}

local function normalize(path)
  return vim.fs.normalize(path)
end

-- Node kinds that stand for a file or directory on disk. A project reference
-- carries the referenced .csproj as its path too, but it is a dependency, not
-- the project, so it is left out: opening a .csproj lands on the project node.
local INDEXED = { solution = true, project = true, folder = true, file = true }

--- Builds the path -> node id index for a tree as `tree.build` returns it.
---
--- A project nested in another project's directory has its files listed
--- twice: under its own node, and under the outer project's folders. The
--- copy kept is the one under the innermost project, the one that compiles
--- the file.
---@param items table[]
---@return table<string, string>
function M.index(items)
  local index, owner_depth = {}, {}

  local function visit(nodes, owner_dir)
    for _, node in ipairs(nodes) do
      local kind = node.extra and node.extra.kind
      local dir = owner_dir
      if kind == "project" and node.path then
        dir = vim.fn.fnamemodify(normalize(node.path), ":h")
      end
      if node.path and INDEXED[kind] then
        local path = normalize(node.path)
        local depth = #(dir or "")
        if not index[path] or depth > owner_depth[path] then
          index[path] = node.id
          owner_depth[path] = depth
        end
      end
      if node.children then
        visit(node.children, dir)
      end
    end
  end

  visit(items, nil)
  return index
end

--- The id of the node showing `path`, or nil when the file is not in the
--- solution. The real path is tried too, so a file opened through a symlink
--- (or /tmp vs /private/tmp on macOS) is still found.
---@param index table<string, string>|nil
---@param path string|nil
---@return string|nil
function M.lookup(index, path)
  if not index or not path or path == "" then
    return nil
  end
  local id = index[normalize(path)]
  if id then
    return id
  end
  local real = vim.uv.fs_realpath(path)
  return real and index[normalize(real)] or nil
end

--- The ids of the nodes above `id`, root first.
---@param tree table a NuiTree
---@param id string
---@return string[]
local function ancestors(tree, id)
  local chain = {}
  local node = tree:get_node(id)
  local parent_id = node and node:get_parent_id()
  while parent_id do
    table.insert(chain, 1, parent_id)
    local parent = tree:get_node(parent_id)
    parent_id = parent and parent:get_parent_id()
  end
  return chain
end

--- Expands the nodes above `id` and moves the tree cursor onto it.
---
--- With `opts.follow`, the editor keeps the focus, and unless
--- `opts.leave_dirs_open` is set, the directories a previous follow opened
--- and this one does not need are collapsed again, the way the filesystem
--- source does it. Directories the user opened are never collapsed: only the
--- ones this function expanded are tracked.
---@param state table neo-tree state, with `tree`
---@param id string
---@param opts? { follow?: boolean, leave_dirs_open?: boolean }
---@return boolean focused
function M.focus(state, id, opts)
  opts = opts or {}
  local renderer = require("neo-tree.ui.renderer")
  local tree = state.tree
  if not tree or not tree:get_node(id) then
    return false
  end

  local needed = {}
  local opened = state.dotnet_follow_opened or {}
  for _, parent_id in ipairs(ancestors(tree, id)) do
    needed[parent_id] = true
    local parent = tree:get_node(parent_id)
    if parent and not parent:is_expanded() then
      parent:expand()
      opened[parent_id] = true
    end
  end

  if opts.follow and not opts.leave_dirs_open then
    for opened_id in pairs(opened) do
      if not needed[opened_id] then
        local node = tree:get_node(opened_id)
        if node and node:is_expanded() then
          node:collapse()
        end
        opened[opened_id] = nil
      end
    end
  end
  state.dotnet_follow_opened = opened

  renderer.redraw(state)
  return renderer.focus_node(state, id, opts.follow) ~= false
end

--- The `follow_current_file` handler: reveals the current buffer's file in a
--- visible tree, keeping the focus in the editor.
---@param state table neo-tree state of this source
---@param path string|nil the file to follow
---@return boolean followed
function M.follow(state, path)
  local follow = state.follow_current_file
  if not follow or not follow.enabled then
    return false
  end
  if vim.bo.filetype == "neo-tree" or vim.bo.filetype == "neo-tree-popup" then
    return false
  end
  if state.current_position == "float" then
    return false
  end
  if not require("neo-tree.ui.renderer").window_exists(state) then
    return false
  end
  local id = M.lookup(state.dotnet_index, path)
  if not id then
    return false
  end
  local current = state.tree and state.tree:get_node()
  if current and current:get_id() == id then
    return false
  end
  return M.focus(state, id, { follow = true, leave_dirs_open = follow.leave_dirs_open })
end

return M
