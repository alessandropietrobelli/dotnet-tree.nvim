-- Writing solution folders and their files into the solution file (#66).
--
-- `dotnet sln` only manages projects: it has no command for a solution item or
-- for an empty solution folder. So the file is edited as text, touching only
-- the lines that change. Its line endings, BOM, indentation and everything else
-- stay as they were, and so does a diff of it.
--
--   .sln   a folder is a `Project("{2150E333-...}")` block with its own GUID,
--          nested under another through `GlobalSection(NestedProjects)`; its
--          files are lines of its `ProjectSection(SolutionItems)`
--   .slnx  a folder is `<Folder Name="/parent/name/">`, flat, the hierarchy in
--          the Name; its files are `<File Path="..." />` inside it
local M = {}

local FOLDER_TYPE = "2150E333-8FDC-42A3-9474-1A3956D46DE8"

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
local function write(path, content)
  local tmp = path .. ".dotnet-tree.tmp"
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  f:write(content)
  f:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rename_err
  end
  return true
end

local function eol_of(content)
  return content:find("\r\n", 1, true) and "\r\n" or "\n"
end

local function is_slnx(path)
  return path:lower():match("%.slnx$") ~= nil
end

--- `path` relative to `dir`, with `..` when it is outside; both are resolved
--- first, so `/var` and `/private/var` on macOS do not differ.
---@param dir string
---@param path string
---@return string
function M.relative(dir, path)
  local function parts(p)
    p = vim.uv.fs_realpath(p) or vim.fs.normalize(p)
    return vim.split(vim.fs.normalize(p), "/", { trimempty = true })
  end
  local from, to = parts(dir), parts(path)
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

-- ─── .sln ──────────────────────────────────────────────────────────────────

-- The `Project(...)` line of the folder with `guid`: its start, and the end of
-- the line (after its line break).
local function sln_find_project(content, guid)
  local from = 1
  while true do
    local s, e, id = content:find('Project%("{[^}]+}"%)%s*=%s*"[^"]*",%s*"[^"]*",%s*"{([^}]+)}"[^\n]*\n', from)
    if not s then
      return nil
    end
    if id:upper() == guid:upper() then
      return s, e
    end
    from = e + 1
  end
end

local function sln_add_file(content, folder, rel)
  local eol = eol_of(content)
  local s, e = sln_find_project(content, folder.guid)
  if not s then
    return nil, ("solution folder %s not found in the solution file"):format(folder.name)
  end
  local block_end = content:find("\nEndProject", e - 1, true) or #content
  rel = rel:gsub("/", "\\")
  local line = ("\t\t%s = %s%s"):format(rel, rel, eol)
  local section = content:find("ProjectSection(SolutionItems)", e, true)
  if section and section < block_end then
    local close = content:find("EndProjectSection", section, true)
    if close and close < block_end then
      local at = line_start(content, close)
      return content:sub(1, at - 1) .. line .. content:sub(at)
    end
  end
  local inserted = "\tProjectSection(SolutionItems) = preProject" .. eol .. line .. "\tEndProjectSection" .. eol
  return content:sub(1, e) .. inserted .. content:sub(e + 1)
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
    local line = ("\t\t{%s} = {%s}%s"):format(guid, parent.guid:upper(), eol)
    local nested = content:find("GlobalSection(NestedProjects)", 1, true)
    if nested then
      local close = content:find("EndGlobalSection", nested, true)
      local at = line_start(content, close)
      content = content:sub(1, at - 1) .. line .. content:sub(at)
    else
      local section = "\tGlobalSection(NestedProjects) = preSolution" .. eol .. line .. "\tEndGlobalSection" .. eol
      local end_global = content:find("\nEndGlobal")
      if not end_global then
        return nil, "the solution file has no Global section to nest the folder in"
      end
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

-- The indentation step of the file: a tab, or the smallest run of spaces
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

-- The `<Folder>` element named `folderpath`: where its tag starts and ends, and
-- whether it closes itself.
local function slnx_find_folder(content, folderpath)
  local xml = require("dotnet-tree.parser.xml")
  local from = 1
  while true do
    local s, e, attrs, slash = content:find("<[Ff]older(%s[^>]-)(/?)>", from)
    if not s then
      return nil
    end
    local name = xml.attr_ci(xml.parse_attrs(attrs), "Name")
    if name and norm_folder(xml.unescape(name)) == folderpath then
      return s, e, slash == "/"
    end
    from = e + 1
  end
end

-- The `</Folder>` that closes the element whose start tag ends at `from`
local function slnx_closing(content, from)
  local depth = 1
  local pos = from
  while true do
    local s, e, close, selfclose = content:find("<(/?)[Ff]older[^>]-(/?)>", pos)
    if not s then
      return nil
    end
    if close == "/" then
      depth = depth - 1
      if depth == 0 then
        return s
      end
    elseif selfclose ~= "/" then
      depth = depth + 1
    end
    pos = e + 1
  end
end

local function slnx_insert_before_end(content, text)
  local close = content:find("</[Ss]olution>")
  if not close then
    return nil, "the solution file has no </Solution>"
  end
  local at = line_start(content, close)
  return content:sub(1, at - 1) .. text .. content:sub(at)
end

local function slnx_add_file(content, folder, rel)
  local eol, unit = eol_of(content), indent_unit(content)
  local file = ('<File Path="%s" />'):format(xml_escape(rel))
  local s, e, selfclosing = slnx_find_folder(content, folder._folderpath)
  if not s then
    -- A folder implied by a deeper one's Name, never written itself
    local block = ('%s<Folder Name="%s">%s%s%s%s%s</Folder>%s'):format(
      unit,
      xml_escape(folder._folderpath),
      eol,
      unit .. unit,
      file,
      eol,
      unit,
      eol
    )
    return slnx_insert_before_end(content, block)
  end
  local indent = content:sub(line_start(content, s), s - 1):match("^%s*")
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
  local close = slnx_closing(content, e + 1)
  if not close then
    return nil, ("solution folder %s is not closed in the solution file"):format(folder.name)
  end
  local at = line_start(content, close)
  return content:sub(1, at - 1) .. indent .. unit .. file .. eol .. content:sub(at)
end

local function slnx_add_folder(content, parent, name)
  local eol, unit = eol_of(content), indent_unit(content)
  local folderpath = norm_folder((parent and parent._folderpath or "/") .. name)
  local block = ('%s<Folder Name="%s" />%s'):format(unit, xml_escape(folderpath), eol)
  local out, err = slnx_insert_before_end(content, block)
  return out, err, folderpath
end

-- ─── public ────────────────────────────────────────────────────────────────

-- Refuse to write under unsaved changes to the same file
local function unsaved(path)
  local buf = vim.fn.bufnr(path)
  return buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified
end

-- A buffer showing the file reads it again, rather than holding the old text
local function reload(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    pcall(vim.cmd, "checktime " .. buf)
  end
end

local function edit(sln_path, change)
  if unsaved(sln_path) then
    return nil, ("%s has unsaved changes: save or discard them first"):format(vim.fn.fnamemodify(sln_path, ":t"))
  end
  local content, err = read(sln_path)
  if not content then
    return nil, err
  end
  local out, change_err, id = change(content)
  if not out then
    return nil, change_err
  end
  local ok, write_err = write(sln_path, out)
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
    if vim.fs.normalize(item.path) == vim.fs.normalize(file_path) then
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
---@param sln_path string
---@param parent table|nil the parent folder's entry from parser/solution.lua
---@param name string
---@param siblings string[] names already used at that level
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

--- The folder on disk a solution folder's files live in: the directory its
--- items share, or else `<solution dir>/<folder path>`. A guess to start a
--- prompt from, never written anywhere.
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
