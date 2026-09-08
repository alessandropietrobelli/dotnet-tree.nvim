-- Build and clean, routed to the quickfix list instead of a terminal buffer.
--
-- `run`, `test` and `watch` stay in the terminal on purpose: their output is
-- interactive. A build's output is not -- it is a list of file positions, and a
-- `:terminal` split is the one place in Neovim you cannot jump from.
--
-- Three things this has to get right, all of them measured against real
-- `dotnet build` output rather than assumed (captured under
-- tests/fixtures/build/):
--
--   1. The errorformat has to cover restore errors, which carry no line or
--      column. See M.errorformat.
--   2. MSBuild prints every diagnostic twice -- once inline, once in the
--      `Build FAILED.` summary -- so the entries have to be deduplicated or
--      every one of them is doubled.
--   3. A successful build is a notification, not a window.
--
-- The entry point is M.build(path, opts). It is deliberately usable by another
-- action and not only by a keymap: `opts.on_complete` receives the outcome, so
-- a caller can build first and do something else if the build came back clean.

local M = {}

-- Neovim's bundled dotnet compiler plugin (runtime/compiler/dotnet.vim) carries
-- only `%E%f(%l\,%c): %trror %m`. That covers the compiler and nothing else:
--
--   /tmp/B/B.csproj : error NU1101: Unable to find package Wds.Nonexistent ...
--
-- has no `(line,column)`, so on the bundled format it is swallowed by
-- `%-G%.%#` and yields zero quickfix entries. And a failed restore *masks
-- compilation* -- with an unresolvable package reference, a CS0029 in the same
-- project is not reported at all -- so the restore error is the only thing the
-- user gets. Dropping it would lose exactly the class of error that justifies
-- this module: no language server sees a failed restore, a missing SDK or a bad
-- import. `%f : %trror %m` is what recovers it.
--
-- Warnings are collected too. They do not open the window on their own (see
-- M.build), but `TreatWarningsAsErrors` and analyzer output are the reason
-- people look at build results at all.
M.errorformat = table.concat({
  "%f(%l\\,%c): %trror %m",
  "%f(%l\\,%c): %tarning %m",
  "%f : %trror %m",
  "%f : %tarning %m",
  "%-G%.%#",
}, ",")

-- Marks the quickfix list as ours. Used to decide between replacing the current
-- list and pushing a new one, so a build never overwrites someone's :grep.
local TITLE_PREFIX = "dotnet-tree: "

-- When a build fails and nothing matched, the raw output goes to the list
-- instead. Capped so a solution-wide failure cannot produce thousands of lines.
local MAX_UNPARSED_LINES = 200

local ACTIONS = { build = true, clean = true }

-- Jobs in flight, keyed by action and path: pressing `b` twice while the first
-- build is still running would otherwise publish two lists over each other.
local running = {}

-- MSBuild appends the project that produced a diagnostic, and on a
-- multi-targeted project the target framework as well:
--
--   ... error CS0029: ... [/tmp/C/C.csproj::TargetFramework=net8.0]
--
-- Stripping it is what makes the inline and summary copies compare equal, and
-- what collapses one error reported once per target framework into the single
-- source position it actually is. Only a bracket that names a project file is
-- touched, so a diagnostic whose own text ends in a bracket survives.
local function strip_project_suffix(text)
  return (text:gsub("%s*%[[^%]]*%.%w+proj[^%]]*%]%s*$", ""))
end

-- `MSBUILD : error MSB1009: Project file does not exist.` names the engine, not
-- a file. Left alone it becomes a quickfix entry that opens an empty buffer
-- called MSBUILD. A name with no path separator that is not readable is not a
-- file; the text is kept, the destination is dropped.
local function is_pseudo_file(name)
  return name ~= "" and not name:find("[/\\]") and vim.fn.filereadable(name) == 0
end

--- Parse build output into deduplicated quickfix items.
---
--- Uses Neovim's own errorformat engine through getqflist({ lines = ... }),
--- which parses without touching any quickfix list -- so this is testable
--- headlessly against captured output, which is the only way to know the
--- format still matches what MSBuild prints.
---@param lines string[] raw stdout/stderr lines
---@return table[] items suitable for setqflist
function M.parse(lines)
  local parsed = vim.fn.getqflist({ lines = lines, efm = M.errorformat })
  local items, seen = {}, {}

  for _, item in ipairs(parsed.items or {}) do
    local name = item.bufnr > 0 and vim.fn.bufname(item.bufnr) or ""
    item.text = strip_project_suffix(item.text)

    if is_pseudo_file(name) then
      item.text = name .. ": " .. item.text
      item.bufnr = 0
      name = ""
    end

    local key = table.concat({ name, item.lnum, item.col, item.type, item.text }, "\0")
    if not seen[key] then
      seen[key] = true
      table.insert(items, item)
    end
  end

  return items
end

--- Count errors and warnings in a parsed item list.
---@param items table[]
---@return integer errors
---@return integer warnings
function M.counts(items)
  local errors, warnings = 0, 0
  for _, item in ipairs(items) do
    if (item.type or ""):lower() == "w" then
      warnings = warnings + 1
    else
      errors = errors + 1
    end
  end
  return errors, warnings
end

local function text_items(output)
  local items = {}
  local first = math.max(1, #output - MAX_UNPARSED_LINES + 1)
  if first > 1 then
    table.insert(items, { text = ("[dotnet-tree] %d earlier output lines omitted"):format(first - 1) })
  end
  for i = first, #output do
    table.insert(items, { text = output[i] })
  end
  return items
end

local function owns_quickfix()
  local title = vim.fn.getqflist({ title = 0 }).title or ""
  return title:sub(1, #TITLE_PREFIX) == TITLE_PREFIX
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local function publish(result, opts)
  local errors, warnings = M.counts(result.items)
  result.errors, result.warnings = errors, warnings

  -- Replacing our own list keeps a green build from leaving the previous
  -- failure on screen; anything else on the stack is left where it is.
  local replace = owns_quickfix()
  local items, unparsed = result.items, false

  if result.code ~= 0 and #items == 0 then
    -- The build failed in a way the errorformat does not recognise. Zero
    -- entries and a failing exit code must never look like a clean build, and
    -- the output is the only diagnostic there is, so it goes in verbatim.
    items, unparsed = text_items(result.output), true
  end

  local title = ("%sdotnet %s %s"):format(TITLE_PREFIX, result.action, vim.fn.fnamemodify(result.path, ":t"))
  vim.fn.setqflist({}, replace and "r" or " ", { title = title, items = items })

  if opts.open_quickfix ~= false and result.code ~= 0 and #items > 0 then
    vim.cmd("botright copen")
  elseif result.code == 0 and #items == 0 and replace then
    vim.cmd("cclose")
  end

  if opts.notify ~= false then
    local level, message
    if result.code == 0 then
      level = vim.log.levels.INFO
      message = ("%s succeeded"):format(result.action)
      if warnings > 0 then
        message = ("%s (%s)"):format(message, plural(warnings, "warning"))
      end
    elseif unparsed then
      level = vim.log.levels.ERROR
      message = ("%s failed (exit %d); no diagnostics recognised, full output in the quickfix list"):format(
        result.action,
        result.code
      )
    else
      level = vim.log.levels.ERROR
      message = ("%s failed: %s"):format(result.action, plural(errors, "error"))
      if warnings > 0 then
        message = ("%s, %s"):format(message, plural(warnings, "warning"))
      end
    end
    vim.notify("[dotnet-tree] " .. message, level)
  end
end

--- Run `dotnet build` or `dotnet clean` and send the diagnostics to quickfix.
---
--- Asynchronous: the return value is the job id, and the outcome arrives on
--- `opts.on_complete`. That callback is the reason this takes an options table
--- rather than being a keymap handler -- another action can build first and act
--- on `result.code` instead of guessing.
---
---@param path string path to a project or solution file
---@param opts table|nil
---   action        "build" (default) or "clean"
---   args          string[] extra arguments appended to the dotnet command
---   open_quickfix boolean, default true: :copen when the build failed
---   notify        boolean, default true: vim.notify on start and on outcome
---   on_complete   fun(result) with
---                 { action, path, code, items, output, errors, warnings }
---@return integer|nil job_id nil when the build was not started
function M.build(path, opts)
  opts = opts or {}
  local action = opts.action or "build"

  if not ACTIONS[action] then
    error(("dotnet-tree: unsupported action %q, expected build or clean"):format(tostring(action)), 2)
  end
  if type(path) ~= "string" or path == "" then
    vim.notify("[dotnet-tree] nothing to " .. action, vim.log.levels.WARN)
    return nil
  end
  if vim.fn.executable("dotnet") == 0 then
    vim.notify("[dotnet-tree] `dotnet` is not executable; see :checkhealth dotnet-tree", vim.log.levels.ERROR)
    return nil
  end

  local key = action .. " " .. path
  if running[key] then
    vim.notify(("[dotnet-tree] %s already running"):format(action), vim.log.levels.WARN)
    return nil
  end

  local cmd = { "dotnet", action, path }
  vim.list_extend(cmd, opts.args or {})

  local output = {}
  local function collect(_, data)
    if not data then
      return
    end
    for _, line in ipairs(data) do
      line = line:gsub("\r$", "")
      if line ~= "" then
        table.insert(output, line)
      end
    end
  end

  if opts.notify ~= false then
    vim.notify(("[dotnet-tree] dotnet %s %s"):format(action, vim.fn.fnamemodify(path, ":t")))
  end

  local ok, job = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = collect,
    on_stderr = collect,
    on_exit = function(_, code)
      running[key] = nil
      local result = {
        action = action,
        path = path,
        code = code,
        output = output,
        items = M.parse(output),
      }
      publish(result, opts)
      if opts.on_complete then
        opts.on_complete(result)
      end
    end,
  })

  if not ok or job <= 0 then
    vim.notify(("[dotnet-tree] could not start `dotnet %s`"):format(action), vim.log.levels.ERROR)
    return nil
  end

  running[key] = true
  return job
end

return M
