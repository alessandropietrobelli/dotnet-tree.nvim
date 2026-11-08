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
-- Solution directory -> repository top level, or false when git said it is
-- not a repository. It does not change while the solution is open, so it is
-- asked once; a git that failed for another reason is asked again.
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

-- Milliseconds a git command may take before it is stopped. A git that never
-- answers (a stuck fsmonitor, a stalled network drive) would otherwise keep
-- its fetch in flight forever, and every later fetch would wait on it.
M.timeout_ms = 30000

-- Warnings already shown, by key: git failing is reported once per session,
-- not on every save.
local warned = {}

-- Quitting stops the jobs still running, and they end as failures: that is
-- not something to report on the way out. A function so tests can stand in
-- for `v:exiting`, which is read-only.
function M.exiting()
  return vim.v.exiting ~= vim.NIL
end

local function warn_once(key, msg)
  if M.exiting() then
    return
  end
  pcall(function()
    require("neo-tree.log").debug("[dotnet-tree] ", msg)
  end)
  if warned[key] then
    return
  end
  warned[key] = true
  vim.notify("[dotnet-tree] " .. msg, vim.log.levels.WARN)
end
M.warn_once = warn_once

-- Run `cmd` as a job. `done(lines, code, stderr)` gets the output lines, or nil
-- when the command failed, could not start or timed out; it is called once.
local function run(cmd, done)
  local lines, errors, finished = {}, {}, false
  local function once(output, code, stderr)
    if finished then
      return
    end
    finished = true
    vim.schedule(function()
      done(output, code, stderr)
    end)
  end
  local ok, job = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        line = line:gsub("\r$", "")
        if line ~= "" then
          table.insert(lines, line)
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          table.insert(errors, line)
        end
      end
    end,
    on_exit = function(_, code)
      once(code == 0 and lines or nil, code, table.concat(errors, "\n"))
    end,
  })
  if not ok or job <= 0 then
    local reason = not ok and tostring(job) or (job == -1 and "git is not executable" or "invalid arguments")
    once(nil, -1, reason)
    return
  end
  vim.defer_fn(function()
    if not finished then
      pcall(vim.fn.jobstop, job)
      once(nil, -1, ("no answer after %d s"):format(M.timeout_ms / 1000))
    end
  end, M.timeout_ms)
end

--- Ask git for the status of the repository holding `root`, in the background.
--- `on_change` is called once the answer is in, and only when it differs from
--- the status a rebuild would paint now. A fetch asked for while one is
--- running is not lost: the running one is asked again when it ends, since
--- its answer may predate what triggered the second request. When git fails,
--- the status painted is kept and the failure is reported once: a failed
--- `git status` is not a clean repository.
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

  -- `map` nil means "unknown": keep what is painted.
  local function finish(map)
    running[root] = nil
    if current.again then
      M.fetch(root, current.on_change)
      return
    end
    if not map then
      return
    end
    local before = known[root] and known[root].map or {}
    known[root] = { map = map }
    if not vim.deep_equal(before, map) and current.on_change then
      current.on_change()
    end
  end

  -- Whatever goes wrong in a callback, the fetch must end: a fetch left in
  -- flight would turn every later one into a no-op.
  local function guarded(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then
        running[root] = nil
        warn_once("git-error", "reading git status failed: " .. tostring(err))
      end
    end
  end

  local function status(toplevel)
    local cmd = { "git", "-C", root, "status", "--porcelain=v1", "-uall", "--ignored=no" }
    run(
      cmd,
      guarded(function(lines, _, stderr)
        if not lines then
          warn_once("git-status", "git status failed, markers may be out of date: " .. stderr)
          finish(nil)
          return
        end
        finish(M.parse(lines, toplevel))
      end)
    )
  end

  if toplevels[root] == false then
    finish({})
    return
  elseif toplevels[root] then
    status(toplevels[root])
    return
  end
  run(
    { "git", "-C", root, "rev-parse", "--show-toplevel" },
    guarded(function(lines, code, stderr)
      local toplevel = lines and lines[1]
      if toplevel and toplevel ~= "" then
        toplevels[root] = vim.fs.normalize(toplevel)
        status(toplevels[root])
      elseif code == 128 and stderr:find("not a git repository", 1, true) then
        -- Git ran and said so: nothing to paint, and nothing to ask next time.
        toplevels[root] = false
        finish({})
      else
        -- Git missing, refusing the directory (safe.directory) or failing
        -- otherwise: ask again next time, it may be fixed by then.
        warn_once("git-rev-parse", "git status unavailable, no git markers: " .. stderr)
        finish(nil)
      end
    end)
  )
end

--- Whether a fetch for `root` is in flight, for tests.
---@param root string
---@return boolean
function M._running(root)
  return running[vim.fs.normalize(root)] ~= nil
end

--- Forget every status, top level and warning, for tests.
function M.reset()
  known, toplevels, running, warned = {}, {}, {}, {}
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
