-- Telling the language servers about a file renamed or moved from the tree (#50):
-- `workspace/willRenameFiles` before, so a server that supports it can rename
-- the type and fix its references, and `workspace/didRenameFiles` after.
--
-- neo-tree's file operations, which the tree uses, fire the events that
-- nvim-lsp-file-operations listens to. With that plugin loaded it already does
-- this, and doing it here too would apply the same edits twice, so this steps
-- aside.
local M = {}

local TIMEOUT = 2000

local function other_plugin()
  return package.loaded["lsp-file-operations"] ~= nil
end

-- Whether a fileOperations registration covers `path`
local function covers(registration, path, is_dir)
  if type(registration) ~= "table" then
    return false
  end
  local filters = registration.filters or {}
  if #filters == 0 then
    return true
  end
  for _, filter in ipairs(filters) do
    local pattern = filter.pattern or {}
    local kind = pattern.matches
    if not kind or (kind == "folder") == is_dir then
      local glob = pattern.glob
      if not glob then
        return true
      end
      local ok, lpeg = pcall(vim.glob.to_lpeg, glob)
      if ok and lpeg:match(path) then
        return true
      end
    end
  end
  return false
end

local function clients_for(capability, path, is_dir)
  local found = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    local ops = vim.tbl_get(client.server_capabilities or {}, "workspace", "fileOperations", capability)
    if covers(ops, path, is_dir) then
      table.insert(found, client)
    end
  end
  return found
end

local function params(src, dest)
  return { files = { { oldUri = vim.uri_from_fname(src), newUri = vim.uri_from_fname(dest) } } }
end

local function request_sync(client, method, body)
  if vim.fn.has("nvim-0.11") == 1 then
    return client:request_sync(method, body, TIMEOUT)
  end
  return client.request_sync(method, body, TIMEOUT)
end

local function notify(client, method, body)
  if vim.fn.has("nvim-0.11") == 1 then
    return client:notify(method, body)
  end
  return client.notify(method, body)
end

--- Ask the servers for the edits renaming `src` to `dest` implies, and apply
--- them. Returns the names of the servers that changed something.
---@param src string
---@param dest string
---@return string[]
function M.will_rename(src, dest)
  local changed = {}
  if other_plugin() then
    return changed
  end
  local is_dir = vim.fn.isdirectory(src) == 1
  for _, client in ipairs(clients_for("willRename", src, is_dir)) do
    local ok, response = pcall(request_sync, client, "workspace/willRenameFiles", params(src, dest))
    if not ok or not response or response.err then
      vim.notify(
        ("[dotnet-tree] %s did not answer about renaming %s: %s"):format(
          client.name,
          vim.fn.fnamemodify(src, ":t"),
          tostring(ok and response and response.err and response.err.message or response or "timed out")
        ),
        vim.log.levels.WARN
      )
    elseif response.result then
      vim.lsp.util.apply_workspace_edit(response.result, client.offset_encoding or "utf-16")
      table.insert(changed, client.name)
    end
  end
  return changed
end

--- Tell the servers `src` is now `dest`.
---@param src string
---@param dest string
function M.did_rename(src, dest)
  if other_plugin() then
    return
  end
  local is_dir = vim.fn.isdirectory(dest) == 1
  for _, client in ipairs(clients_for("didRename", dest, is_dir)) do
    pcall(notify, client, "workspace/didRenameFiles", params(src, dest))
  end
end

return M
