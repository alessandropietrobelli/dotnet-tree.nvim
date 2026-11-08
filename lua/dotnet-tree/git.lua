-- Git status markers on the tree's nodes.
--
-- `git status` runs as a job, never inside `tree.build`: on a large repository
-- it is most of the cost of a rebuild, and a blocking call there froze the
-- editor every time the tree was rebuilt (#49). A rebuild paints the last
-- status known for the repository, and `fetch` asks git again in the
-- background, calling back only when the answer differs from what is painted.
local M = {}

-- Solution directory -> { map = path -> two-letter code }, the status a
-- rebuild paints.
local known = {}
-- Solution directory -> repository top level, or false outside a repository.
-- It does not change while the solution is open, so it is asked once.
local toplevels = {}
-- Solution directory -> the fetch in flight: { on_change, again }.
local running = {}

--- Status codes by absolute path, from `git status --porcelain=v1` output.
--- Porcelain paths are relative to the repository's top level.
---@param lines string[]
---@param toplevel string
---@return table<string, string>
function M.parse(lines, toplevel)
  local map = {}
  for _, line in ipairs(lines) do
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
  return map
end

-- Run `cmd` as a job and hand its output lines to `done`, or nil when it
-- failed or could not start.
local function run(cmd, done)
  local lines = {}
  local ok, job = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        line = line:gsub("\r$", "")
        if line ~= "" then
          table.insert(lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        done(code == 0 and lines or nil)
      end)
    end,
  })
  if not ok or job <= 0 then
    vim.schedule(function()
      done(nil)
    end)
  end
end

--- Ask git for the status of the repository holding `root`, in the background.
--- `on_change` is called once the answer is in, and only when it differs from
--- the status a rebuild would paint now. A fetch asked for while one is
--- running is not lost: the running one is asked again when it ends, since
--- its answer may predate what triggered the second request.
---@param root string the solution directory
---@param on_change fun()?
function M.fetch(root, on_change)
  root = vim.fs.normalize(root)
  local current = running[root]
  if current then
    current.again = true
    current.on_change = on_change or current.on_change
    return
  end
  current = { on_change = on_change }
  running[root] = current

  local function finish(map)
    running[root] = nil
    if current.again then
      M.fetch(root, current.on_change)
      return
    end
    local before = known[root] and known[root].map or {}
    known[root] = { map = map }
    if not vim.deep_equal(before, map) and current.on_change then
      current.on_change()
    end
  end

  local function status(toplevel)
    run({ "git", "-C", root, "status", "--porcelain=v1", "-uall", "--ignored=no" }, function(lines)
      finish(lines and M.parse(lines, toplevel) or {})
    end)
  end

  if toplevels[root] == false then
    finish({})
    return
  elseif toplevels[root] then
    status(toplevels[root])
    return
  end
  run({ "git", "-C", root, "rev-parse", "--show-toplevel" }, function(lines)
    local toplevel = lines and lines[1]
    if not toplevel or toplevel == "" then
      -- Not a repository: nothing to paint, and nothing to ask next time.
      toplevels[root] = false
      finish({})
      return
    end
    toplevels[root] = vim.fs.normalize(toplevel)
    status(toplevels[root])
  end)
end

--- Whether a fetch for `root` is in flight, for tests.
---@param root string
---@return boolean
function M._running(root)
  return running[vim.fs.normalize(root)] ~= nil
end

--- Forget every status and top level, for tests.
function M.reset()
  known, toplevels, running = {}, {}, {}
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

--- Paint the last status known for `root` on `items`. It never runs git:
--- `fetch` does that, after the tree is shown.
---@param items table[]
---@param root string the solution directory
function M.apply_to_tree(items, root)
  local entry = known[vim.fs.normalize(root)]
  local status_map = entry and entry.map or {}
  if not next(status_map) then
    return
  end
  apply(items, status_map)
end

return M
