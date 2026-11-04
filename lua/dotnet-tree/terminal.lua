-- The terminal split `r`, `t`, `w` and `a` run in.
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

--- Opens a bottom split running `cmd` in a terminal, named after `label`.
---
--- The buffer is unlisted: a listed terminal shows up in a bufferline next to
--- the files, and clicking it there opens the terminal in the editor window
--- instead of the split it belongs to. Its label goes in the split's own
--- winbar instead, and `:ls!` and the buffer name still find it.
---@param cmd string
---@param label string what the terminal is running, e.g. "run Api"
---@return integer bufnr
function M.open(cmd, label)
  vim.cmd("botright 15split")
  vim.cmd("terminal " .. cmd)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  -- renaming never stops the command, so a failure here only costs the name
  pcall(vim.api.nvim_buf_set_name, buf, M.buffer_name(label))
  vim.bo[buf].buflisted = false
  vim.wo[win].winbar = M.winbar(label)
  vim.cmd("startinsert")
  return buf
end

return M
