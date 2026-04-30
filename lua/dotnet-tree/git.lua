local M = {}

function M.status(root)
  local out = vim.fn.systemlist({ "git", "-C", root, "status", "--porcelain=v1", "-uall", "--ignored=no" })
  if vim.v.shell_error ~= 0 then
    return {}, nil
  end

  local toplevel = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--show-toplevel" })[1]
  if not toplevel or toplevel == "" then
    return {}, nil
  end
  toplevel = vim.fs.normalize(toplevel)

  local map = {}
  for _, line in ipairs(out) do
    if #line > 3 then
      local code = line:sub(1, 2)
      local path = line:sub(4)
      if path:find(" %-> ") then
        path = path:match(" %-> (.+)$") or path
      end
      if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
        path = path:sub(2, -2)
      end
      map[vim.fs.normalize(toplevel .. "/" .. path)] = code
    end
  end

  return map, toplevel
end

local function dir_status(child_codes)
  local has_modified, has_untracked = false, false
  for _, code in pairs(child_codes) do
    if code == "??" then
      has_untracked = true
    else
      has_modified = true
    end
  end
  if has_modified then
    return " M"
  elseif has_untracked then
    return "??"
  end
  return nil
end

local function apply(items, status_map)
  local has_change_below = false
  for _, item in ipairs(items) do
    local own = nil
    if item.path and status_map[item.path] then
      own = status_map[item.path]
      item.extra = item.extra or {}
      item.extra.git_status = own
    end

    local child_changes = false
    if item.children and #item.children > 0 then
      child_changes = apply(item.children, status_map)
    end

    if not own and child_changes then
      local children_codes = {}
      for _, c in ipairs(item.children or {}) do
        if c.extra and c.extra.git_status then
          table.insert(children_codes, c.extra.git_status)
        end
      end
      local rolled = dir_status(children_codes)
      if rolled then
        item.extra = item.extra or {}
        item.extra.git_status = rolled
        item.extra.git_rolled_up = true
      end
    end

    if own or child_changes then
      has_change_below = true
    end
  end
  return has_change_below
end

function M.apply_to_tree(items, root)
  local status_map = M.status(root)
  if not next(status_map) then
    return
  end
  apply(items, status_map)
end

return M
