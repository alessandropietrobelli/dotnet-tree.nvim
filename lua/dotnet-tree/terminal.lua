-- The terminals `,r`, `,t`, `,w` and `,a` run in, and the `dotnet remove`
-- that `d` runs on a package, a reference or a project.
--
-- A `:terminal` buffer is named after its command line: `term://…//1234:dotnet
-- run --project '/a/long/path/Api/Api.csproj'`, which a statusline cuts down
-- to the pid or to the end of the path. With a run and a watch open side by
-- side there is no telling them apart, so each buffer is renamed after what it
-- is running: `dotnet-tree://run Api`.
--
-- The `scheme://` prefix keeps Neovim from treating the name as a file path,
-- so it is never expanded against the working directory, and `:t` — what most
-- statuslines show — is the readable part after the slash.

local M = {}

M.prefix = "dotnet-tree://"

--- The buffer name for `label`, made unique: a second `run Api` while the
--- first is still open becomes `run Api (2)`, since two buffers cannot share
--- a name.
---@param label string
---@return string
function M.buffer_name(label)
  local base = M.prefix .. label
  local name, n = base, 1
  while vim.fn.bufexists(name) == 1 do
    n = n + 1
    name = string.format("%s (%d)", base, n)
  end
  return name
end

--- The project name shown in a label: the project file without its extension.
---@param csproj_path string
---@return string
function M.project_name(csproj_path)
  return vim.fn.fnamemodify(csproj_path, ":t:r")
end

--- The winbar shown above the terminal split. `%` is escaped because a
--- winbar is a statusline expression, and a label can carry one.
---@param label string
---@return string
function M.winbar(label)
  return " " .. label:gsub("%%", "%%%%")
end

--- The strip of terminals along the bottom of this tab, left to right: the
--- non-floating windows showing one of these terminals on the lowest row any
--- of them is on. One shown somewhere else -- in the editor area, through
--- `:ls!` -- is not part of it.
---@return integer[]
function M.windows()
  local found, lowest = {}, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:sub(1, #M.prefix) == M.prefix and vim.api.nvim_win_get_config(win).relative == "" then
      local row = vim.api.nvim_win_get_position(win)[1]
      table.insert(found, { win = win, row = row, col = vim.api.nvim_win_get_position(win)[2] })
      lowest = math.max(lowest, row)
    end
  end
  local strip = vim.tbl_filter(function(entry)
    return entry.row == lowest
  end, found)
  table.sort(strip, function(a, b)
    return a.col < b.col
  end)
  return vim.tbl_map(function(entry)
    return entry.win
  end, strip)
end

-- Give the terminals of the strip an even share of its width
local function even_out(wins)
  local total = 0
  for _, w in ipairs(wins) do
    total = total + vim.api.nvim_win_get_width(w)
  end
  local each = math.floor(total / #wins)
  for _, w in ipairs(wins) do
    vim.api.nvim_win_set_width(w, each)
  end
end

-- Where a new terminal goes. The first opens a split along the bottom; the
-- next ones open to the right of the strip's last, and the terminals share
-- the strip's width: stacked one above the other, a few runs left each a
-- couple of lines, too few to read a log in. Returns nil, and says so, when
-- there is no room left beside them.
local function open_window()
  local others = M.windows()
  if #others == 0 then
    vim.cmd("botright 15split")
    return vim.api.nvim_get_current_win()
  end
  local from = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(others[#others])
  local ok, err = pcall(vim.cmd, "rightbelow vsplit")
  if not ok then
    vim.api.nvim_set_current_win(from)
    vim.notify(
      ("[dotnet-tree] no room for another terminal beside the open ones, close one: %s"):format(err),
      vim.log.levels.ERROR
    )
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  -- The new window shows the terminal it was split from until it gets its own
  local all = M.windows()
  if not vim.tbl_contains(all, win) then
    table.insert(all, win)
  end
  even_out(all)
  return win
end

--- Opens a terminal running `cmd`, named after `label`: along the bottom, or
--- beside the terminals already open there.
---
--- The buffer is unlisted: a listed terminal shows up in a bufferline next to
--- the files, and clicking it there opens the terminal in the editor window
--- instead of the split it belongs to. Its label goes in the split's own
--- winbar instead, and `:ls!` and the buffer name still find it.
---
--- `cwd` is the directory the command starts in; the current window's
--- working directory when nil. Only the command gets it: the split and the
--- editor keep theirs. A `cwd` that is not a directory -- a project listed in
--- the solution but no longer on disk -- is reported, and nothing opens.
---@param cmd string run by the shell, as `:terminal` runs it
---@param label string what the terminal is running, e.g. "run Api"
---@param cwd string|nil
---@return integer|nil bufnr nil when nothing was started
function M.open(cmd, label, cwd)
  if cwd and vim.fn.isdirectory(cwd) == 0 then
    vim.notify(
      ("[dotnet-tree] cannot %s: %s does not exist. Is the project still on disk?"):format(label, cwd),
      vim.log.levels.ERROR
    )
    return nil
  end
  local from = vim.api.nvim_get_current_win()
  local win = open_window()
  if not win then
    return nil
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  local ok, job = pcall(function()
    if vim.fn.has("nvim-0.11") == 1 then
      return vim.fn.jobstart(cmd, { term = true, cwd = cwd })
    end
    return vim.fn.termopen(cmd, { cwd = cwd })
  end)
  if not ok or job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    -- As it was before: the remaining terminals share the strip, and the
    -- cursor is back where `,r` was pressed
    if #M.windows() > 0 then
      even_out(M.windows())
    end
    if vim.api.nvim_win_is_valid(from) then
      vim.api.nvim_set_current_win(from)
    end
    vim.notify(
      ("[dotnet-tree] could not start `%s`: %s"):format(cmd, ok and ("job id " .. job) or job),
      vim.log.levels.ERROR
    )
    return nil
  end
  -- renaming never stops the command, so a failure here only costs the name
  pcall(vim.api.nvim_buf_set_name, buf, M.buffer_name(label))
  vim.bo[buf].buflisted = false
  vim.wo[win].winbar = M.winbar(label)
  vim.cmd("startinsert")
  return buf
end

return M
