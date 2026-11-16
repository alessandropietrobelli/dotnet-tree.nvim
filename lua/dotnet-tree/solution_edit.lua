-- Writing solution folders and their files into the solution file (#66).
--
-- `dotnet sln` only manages projects: it has no command for a solution item or
-- for an empty solution folder. So the solution file is edited as text: new
-- lines are inserted (and a self-closing `<Folder />` is opened up), while the
-- existing lines keep their content, the line endings and the BOM, so a diff
-- of the file shows only what was added. New lines take the file's line ending
-- and, in a .slnx, its indentation; a .sln is indented with tabs, as Visual
-- Studio and `dotnet` write it.
--
--   .sln   a folder is a `Project("{2150E333-...}")` block with its own GUID,
--          nested under another through `GlobalSection(NestedProjects)`; its
--          files are lines of its `ProjectSection(SolutionItems)`
--   .slnx  a folder is `<Folder Name="/parent/name/">`, the hierarchy in the
--          Name; its files are `<File Path="..." />` inside it
local bit = require("bit")

local M = {}

local FOLDER_TYPE = "2150E333-8FDC-42A3-9474-1A3956D46DE8"

local function is_windows_like()
  return vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1
end

---@param path string
---@return string|nil content
---@return string|nil err
local function read(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local content = f:read("*a")
  f:close()
  return content
end

---@param path string
---@param content string
---@return boolean ok
---@return string|nil err
local function write_bytes(path, content)
  local f, err = io.open(path, "wb")
  if not f then
    return false, err
  end
  local written, write_err = f:write(content)
  local closed, close_err = f:close()
  if not written or not closed then
    return false, write_err or close_err or "write failed"
  end
  return true
end

--- Write `content` over the solution file, in place: through a symlink to the
--- file it points to, keeping its permissions, and refusing a read-only one
--- rather than replacing it. A write that fails puts `original` back.
---@param path string
---@param content string
---@param original string
---@return boolean ok
---@return string|nil err
local function write(path, content, original)
  local real = vim.uv.fs_realpath(path) or path
  local name = vim.fn.fnamemodify(path, ":t")
  if not vim.uv.fs_access(real, "W") then
    return false, ("%s is read-only: it was left unchanged"):format(name)
  end
  local ok, err = write_bytes(real, content)
  if ok then
    return true
  end
  if write_bytes(real, original) then
    return false, ("could not write %s (%s): it was left unchanged"):format(name, err)
  end
  return false, ("could not write %s (%s), nor put it back: restore it from version control"):format(name, err)
end

local function eol_of(content)
  return content:find("\r\n", 1, true) and "\r\n" or "\n"
end

local function is_slnx(path)
  return path:lower():match("%.slnx$") ~= nil
end

local function resolved(p)
  return vim.fs.normalize(vim.uv.fs_realpath(p) or p)
end

--- Whether two paths name the same file: resolved, so `/var` and `/private/var`
--- on macOS or a symlinked directory agree, and without regard to case where
--- the file system usually ignores it (macOS, Windows).
---@param a string
---@param b string
---@return boolean
function M.same_path(a, b)
  a, b = resolved(a), resolved(b)
  if is_windows_like() then
    return a:lower() == b:lower()
  end
  return a == b
end

--- `path` relative to `dir`, with `..` when it is outside; both are resolved
--- first, so `/var` and `/private/var` on macOS do not differ. On another
--- Windows drive there is no relative path, and the absolute one is returned.
---@param dir string
---@param path string
---@return string
function M.relative(dir, path)
  local from = vim.split(resolved(dir), "/", { trimempty = true })
  local to = vim.split(resolved(path), "/", { trimempty = true })
  if from[1] ~= to[1] and (to[1] or ""):match("^%a:$") then
    return resolved(path)
  end
  local i = 1
  while i <= #from and i <= #to and from[i] == to[i] do
    i = i + 1
  end
  local out = {}
  for _ = i, #from do
    table.insert(out, "..")
  end
  for j = i, #to do
    table.insert(out, to[j])
  end
  return table.concat(out, "/")
end

local function new_guid()
  local bytes = vim.uv.random(16)
  local hex = {}
  for i = 1, 16 do
    local b = bytes:byte(i)
    if i == 7 then
      b = bit.bor(bit.band(b, 0x0F), 0x40) -- version 4
    elseif i == 9 then
      b = bit.bor(bit.band(b, 0x3F), 0x80) -- variant
    end
    table.insert(hex, ("%02X"):format(b))
  end
  local s = table.concat(hex)
  return ("%s-%s-%s-%s-%s"):format(s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

-- Start of the line that holds position `pos`
local function line_start(content, pos)
  local before = content:sub(1, pos - 1)
  local nl = before:match(".*()\n")
  return nl and (nl + 1) or 1
end

-- Whether only whitespace comes before position `pos` on its line
local function starts_line(content, pos)
  return content:sub(line_start(content, pos), pos - 1):match("^%s*$") ~= nil
end

-- A line `text` (indentation included) inserted before position `pos`: on its
-- own line above it when `pos` starts a line, otherwise broken out before it.
local function insert_line_before(content, pos, text, eol)
  if starts_line(content, pos) then
    local at = line_start(content, pos)
    return content:sub(1, at - 1) .. text .. eol .. content:sub(at)
  end
  return content:sub(1, pos - 1) .. eol .. text .. eol .. content:sub(pos)
end

-- The position of the line break after `pos`, adding one when that line is
-- the last of the file, so a line can follow it
local function ensure_eol_after(content, pos, eol)
  local nl = content:find("\n", pos, true)
  if nl then
    return content, nl
  end
  content = content .. eol
  return content, #content
end

-- ─── .sln ──────────────────────────────────────────────────────────────────

-- The `Project(...)` line of the folder with `guid`: where it starts, and the
-- position of its line break (one is added when it is the last line).
local function sln_find_project(content, guid, eol)
  local from = 1
  while true do
    local s, e, id = content:find('Project%("{[^}]+}"%)%s*=%s*"[^"]*",%s*"[^"]*",%s*"{([^}]+)}"', from)
    if not s then
      return content, nil
    end
    if id:upper() == guid:upper() then
      local nl
      content, nl = ensure_eol_after(content, e, eol)
      return content, s, nl
    end
    from = e + 1
  end
end

-- The `EndProject` line that closes the block starting after `from`, not an
-- unindented `EndProjectSection`
local function sln_end_project(content, from)
  local pos = from
  while true do
    local s, e = content:find("\nEndProject", pos, true)
    if not s then
      return nil
    end
    local after = content:sub(e + 1, e + 1)
    if after == "" or after == "\r" or after == "\n" then
      return s + 1
    end
    pos = e + 1
  end
end

local function sln_add_file(content, folder, rel)
  local eol = eol_of(content)
  local s, nl
  content, s, nl = sln_find_project(content, folder.guid, eol)
  if not s then
    return nil, ("solution folder %s ({%s}) is not in the solution file; press R"):format(folder.name, folder.guid)
  end
  local block_end = sln_end_project(content, nl - 1)
  if not block_end then
    return nil, ("solution folder %s ({%s}) has no EndProject"):format(folder.name, folder.guid)
  end
  rel = rel:gsub("/", "\\")
  local line = ("\t\t%s = %s"):format(rel, rel)
  local section = content:find("ProjectSection(SolutionItems)", nl, true)
  if section and section < block_end then
    local close = content:find("EndProjectSection", section, true)
    if not close or close > block_end then
      return nil, ("the SolutionItems of %s are not closed"):format(folder.name)
    end
    return insert_line_before(content, close, line, eol)
  end
  local inserted = "\tProjectSection(SolutionItems) = preProject" .. eol .. line .. eol .. "\tEndProjectSection" .. eol
  return content:sub(1, nl) .. inserted .. content:sub(nl + 1)
end

local function sln_add_folder(content, parent, name)
  local eol = eol_of(content)
  local guid = new_guid()
  local block = ('Project("{%s}") = "%s", "%s", "{%s}"%sEndProject%s'):format(FOLDER_TYPE, name, name, guid, eol, eol)
  local global = content:find("\nGlobal%s*\n") or content:find("^Global%s*\n")
  if global then
    local at = content:sub(global, global) == "\n" and global + 1 or global
    content = content:sub(1, at - 1) .. block .. content:sub(at)
  else
    content = content .. (content:sub(-1) == "\n" and "" or eol) .. block
  end
  if parent then
    local line = ("\t\t{%s} = {%s}"):format(guid, parent.guid:upper())
    local nested = content:find("GlobalSection(NestedProjects)", 1, true)
    if nested then
      local close = content:find("EndGlobalSection", nested, true)
      if not close then
        return nil, "the NestedProjects section of the solution file is not closed"
      end
      content = insert_line_before(content, close, line, eol)
    else
      local end_global = content:find("\nEndGlobal")
      if not end_global then
        return nil, "the solution file has no Global section to nest the folder in"
      end
      local section = "\tGlobalSection(NestedProjects) = preSolution"
        .. eol
        .. line
        .. eol
        .. "\tEndGlobalSection"
        .. eol
      content = content:sub(1, end_global) .. section .. content:sub(end_global + 1)
    end
  end
  return content, nil, guid
end

-- ─── .slnx ─────────────────────────────────────────────────────────────────

local function xml_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function norm_folder(p)
  p = p:gsub("\\", "/")
  if p:sub(1, 1) ~= "/" then
    p = "/" .. p
  end
  if p:sub(-1) ~= "/" then
    p = p .. "/"
  end
  return (p:gsub("//+", "/"))
end

-- The indentation step of the file: a tab, or the smallest run of spaces,
-- two spaces when nothing is indented
local function indent_unit(content)
  if content:find("\n\t<", 1, true) then
    return "\t"
  end
  local unit
  for spaces in content:gmatch("\n( +)<") do
    if not unit or #spaces < #unit then
      unit = spaces
    end
  end
  return unit or "  "
end

-- The indentation of the line holding `pos`
local function indent_at(content, pos)
  return content:sub(line_start(content, pos), pos - 1):match("^%s*")
end

-- The `<Folder>` element whose path is `folderpath`: where its start tag starts
-- and ends, whether it closes itself, and where its `</Folder>` starts. A Name
-- nested in another `<Folder>` is read as the parser reads it: a full path when
-- it starts with the enclosing one's, else relative to it.
local function slnx_find_folder(content, folderpath)
  local xml = require("dotnet-tree.parser.xml")
  local stack = {} -- { path, s, e } of the open elements
  local pos = 1
  local found
  while true do
    local s, e, close, attrs, selfclose = content:find("<(/?)[Ff]older([^>]-)(/?)>", pos)
    if not s then
      return nil
    end
    pos = e + 1
    if close == "/" then
      local open = table.remove(stack)
      if open and open == found then
        return found.s, found.e, false, s
      end
    else
      local name = xml.attr_ci(xml.parse_attrs(attrs), "Name") or ""
      local np = norm_folder(name)
      local ctx = stack[#stack] and stack[#stack].path
      if ctx and np:sub(1, #ctx) ~= ctx then
        np = norm_folder(ctx .. (name:gsub("^/", "")))
      end
      local entry = { path = np, s = s, e = e }
      if np == folderpath and not found then
        if selfclose == "/" then
          return s, e, true, nil
        end
        found = entry
      end
      if selfclose ~= "/" then
        table.insert(stack, entry)
      end
    end
  end
end

local function slnx_add_root(content, element)
  local eol, unit = eol_of(content), indent_unit(content)
  local close = content:find("</[Ss]olution%s*>")
  if not close then
    return nil, "the solution file has no </Solution>"
  end
  local indent = starts_line(content, close) and indent_at(content, close) or ""
  local lines = vim.split(element, "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = indent .. unit .. l
  end
  return insert_line_before(content, close, table.concat(lines, eol), eol)
end

local function slnx_add_file(content, folder, rel)
  local eol, unit = eol_of(content), indent_unit(content)
  local file = ('<File Path="%s" />'):format(xml_escape(rel))
  local s, e, selfclosing, close = slnx_find_folder(content, folder._folderpath)
  if not s then
    -- A folder implied by a deeper one's Name, never written itself
    return slnx_add_root(
      content,
      ('<Folder Name="%s">\n%s%s\n</Folder>'):format(xml_escape(folder._folderpath), unit, file)
    )
  end
  local indent = starts_line(content, s) and indent_at(content, s) or ""
  if selfclosing then
    local open = content:sub(s, e):gsub("%s*/>$", ">")
    return content:sub(1, s - 1)
      .. open
      .. eol
      .. indent
      .. unit
      .. file
      .. eol
      .. indent
      .. "</Folder>"
      .. content:sub(e + 1)
  end
  if not close then
    return nil, ("solution folder %s is not closed in the solution file"):format(folder.name)
  end
  return insert_line_before(content, close, indent .. unit .. file, eol)
end

local function slnx_add_folder(content, parent, name)
  local folderpath = norm_folder((parent and parent._folderpath or "/") .. name)
  local out, err = slnx_add_root(content, ('<Folder Name="%s" />'):format(xml_escape(folderpath)))
  return out, err, folderpath
end

-- ─── public ────────────────────────────────────────────────────────────────

-- Refuse to write under unsaved changes to the same file
local function unsaved(path)
  local buf = vim.fn.bufnr(path)
  return buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified
end

-- A buffer showing the file reads it again, rather than holding the old text
-- that its next save would write back
local function reload(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    local ok, err = pcall(vim.cmd, "checktime " .. buf)
    if not ok then
      vim.notify(
        ("[dotnet-tree] the buffer of %s could not reload it, do not save it over the change: %s"):format(
          vim.fn.fnamemodify(path, ":t"),
          err
        ),
        vim.log.levels.WARN
      )
    end
  end
end

-- Read the file, apply `change` to its text and write the result. Returns
-- ok, err, and the id `change` gave back. Nothing is written when `change`
-- fails or raises.
local function edit(sln_path, change)
  local name = vim.fn.fnamemodify(sln_path, ":t")
  if unsaved(sln_path) then
    return nil, ("%s has unsaved changes: save or discard them first"):format(name)
  end
  local content, err = read(sln_path)
  if not content then
    return nil, ("could not read %s: %s"):format(name, err)
  end
  local ran, out, change_err, id = pcall(change, content)
  if not ran then
    return nil, ("could not edit %s, which was left unchanged: %s"):format(name, out)
  end
  if not out then
    return nil, change_err
  end
  local ok, write_err = write(sln_path, out, content)
  if not ok then
    return nil, write_err
  end
  require("dotnet-tree.parser.solution").invalidate(sln_path)
  reload(sln_path)
  return true, nil, id
end

--- Add the file at `file_path` to the solution folder `folder`.
---@param sln_path string
---@param folder table the folder's entry from parser/solution.lua
---@param file_path string absolute
---@return boolean|nil ok
---@return string|nil err
function M.add_file(sln_path, folder, file_path)
  for _, item in ipairs(folder.solution_items or {}) do
    if M.same_path(item.path, file_path) then
      return nil, ("%s is already in %s"):format(vim.fn.fnamemodify(file_path, ":t"), folder.name)
    end
  end
  local rel = M.relative(vim.fn.fnamemodify(sln_path, ":h"), file_path)
  return edit(sln_path, function(content)
    if is_slnx(sln_path) then
      return slnx_add_file(content, folder, rel)
    end
    return sln_add_file(content, folder, rel)
  end)
end

--- Create a solution folder named `name`, inside `parent` or at the root.
--- Names with `/ \ " < > | : ? *` are refused.
---@param sln_path string
---@param parent table|nil the parent folder's entry from parser/solution.lua
---@param name string
---@param siblings string[] names already used at that level (compared without case)
---@return boolean|nil ok
---@return string|nil err
---@return string|nil id the new folder's guid (.sln) or path (.slnx)
function M.add_folder(sln_path, parent, name, siblings)
  name = vim.trim(name or "")
  if name == "" or name:find('[/\\"<>|:?*]') then
    return nil, ("%q is not a solution folder name"):format(name)
  end
  for _, sibling in ipairs(siblings or {}) do
    if sibling:lower() == name:lower() then
      return nil, ("there is already a %s here"):format(sibling)
    end
  end
  return edit(sln_path, function(content)
    if is_slnx(sln_path) then
      return slnx_add_folder(content, parent, name)
    end
    return sln_add_folder(content, parent, name)
  end)
end

--- The path the parser gives the item `path` of `folder`, which the tree's
--- node id is built from; nil when it is not listed.
---@param folder table
---@param path string
---@return string|nil
function M.item_path(folder, path)
  for _, item in ipairs(folder and folder.solution_items or {}) do
    if M.same_path(item.path, path) then
      return item.path
    end
  end
end

--- The folder on disk a solution folder's files live in: the deepest directory
--- its items share, or else `<solution dir>/<folder path>`, e.g.
--- `<solution dir>/build/scripts`. A guess to start a prompt from, never
--- written anywhere.
---@param sln table from parser/solution.lua
---@param folder table
---@return string
function M.directory(sln, folder)
  local dirs = vim.tbl_map(function(item)
    return vim.fn.fnamemodify(vim.fs.normalize(item.path), ":h")
  end, folder.solution_items or {})
  if #dirs > 0 then
    local common = vim.split(dirs[1], "/", { plain = true })
    for i = 2, #dirs do
      local other = vim.split(dirs[i], "/", { plain = true })
      local n = 0
      while n < #common and n < #other and common[n + 1] == other[n + 1] do
        n = n + 1
      end
      common = vim.list_slice(common, 1, n)
    end
    if #common > 1 then
      return table.concat(common, "/")
    end
  end
  local names, entry = {}, folder
  while entry do
    table.insert(names, 1, entry.name)
    entry = entry.parent_guid and sln.by_guid[entry.parent_guid] or nil
  end
  return vim.fs.normalize(sln.dir .. "/" .. table.concat(names, "/"))
end

return M
