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

local function warn(message)
  vim.notify("[dotnet-tree] " .. message, vim.log.levels.WARN)
end

local function other_plugin()
  return package.loaded["lsp-file-operations"] ~= nil
end

-- A glob a server sent that does not compile is said once, not on every rename
local bad_globs = {}

-- Whether a fileOperations registration covers `path`
local function covers(client, registration, path, is_dir)
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
      elseif not ok and not bad_globs[glob] then
        bad_globs[glob] = true
        warn(
          ("%s sent a file pattern that does not compile, %q: it is not told about renames"):format(client.name, glob)
        )
      end
    end
  end
  return false
end

local function clients_for(capability, path, is_dir)
  local found = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    local ops = vim.tbl_get(client.server_capabilities or {}, "workspace", "fileOperations", capability)
    if covers(client, ops, path, is_dir) then
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

-- The documents a WorkspaceEdit changes
local function edited(edit)
  local uris = {}
  for uri in pairs(edit.changes or {}) do
    uris[uri] = true
  end
  for _, change in ipairs(edit.documentChanges or {}) do
    local uri = change.textDocument and change.textDocument.uri or change.uri or change.newUri
    if uri then
      uris[uri] = true
    end
  end
  return vim.tbl_count(uris)
end

---@class DotnetTreeRenameEdits
---@field servers string[] the servers that sent edits, which were applied
---@field files integer documents they changed, in buffers not saved yet
---@field err string|nil why the edits could not all be applied: then the rename should not go on

--- Ask the servers for the edits renaming `src` to `dest` implies, and apply
--- them. A server that does not answer is reported and skipped; edits that
--- cannot be applied stop there, with `err` set.
---@param src string
---@param dest string
---@return DotnetTreeRenameEdits
function M.will_rename(src, dest)
  local result = { servers = {}, files = 0 }
  if other_plugin() then
    return result
  end
  local name = vim.fn.fnamemodify(src, ":t")
  local is_dir = vim.fn.isdirectory(src) == 1
  for _, client in ipairs(clients_for("willRename", src, is_dir)) do
    local ok, response, reason = pcall(request_sync, client, "workspace/willRenameFiles", params(src, dest))
    if not ok then
      warn(("%s failed on renaming %s: %s"):format(client.name, name, tostring(response)))
    elseif not response then
      local why = reason == "timeout" and "it did not answer in time"
        or reason == "interrupted" and "the request was interrupted"
        or "it is not running"
      warn(("%s was not asked about renaming %s: %s"):format(client.name, name, why))
    elseif response.err then
      warn(("%s refused renaming %s: %s"):format(client.name, name, tostring(response.err.message or response.err)))
    elseif response.result and edited(response.result) > 0 then
      local applied, err = pcall(vim.lsp.util.apply_workspace_edit, response.result, client.offset_encoding or "utf-16")
      if not applied then
        result.err = ("%s's edits for renaming %s could not be applied: %s"):format(client.name, name, tostring(err))
        return result
      end
      table.insert(result.servers, client.name)
      result.files = result.files + edited(response.result)
    end
  end
  return result
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
    local ok, sent = pcall(notify, client, "workspace/didRenameFiles", params(src, dest))
    if not ok or sent == false then
      warn(
        ("%s was not told %s is now %s; restart it if it still uses the old path"):format(
          client.name,
          vim.fn.fnamemodify(src, ":t"),
          vim.fn.fnamemodify(dest, ":t")
        )
      )
    end
  end
end

return M
