-- Parser for the new XML-based .slnx solution format.
-- Produces the SAME output contract as parser/sln.lua so tree.lua can consume
-- either transparently:
--   { path, name, dir, projects = { <entry>, ... }, by_guid = { [guid]=<entry> } }
-- where each <entry> = {
--   guid, name, path (abs csproj or nil for folder), kind,
--   parent_guid, children_guids = {}, solution_items = { { rel, path }, ... },
-- }
-- (type_guid is carried only by the classic .sln parser; it is always nil here
--  and no consumer reads it — kind is derived from the project file extension.)
--
-- In .slnx, solution folders are a flat list of <Folder Name="/Full/Path/">
-- siblings; the hierarchy lives in the Name path (leading + trailing slash,
-- full path, not just the leaf). Projects/files are nested inside their owning
-- <Folder> (or sit at solution root). We reconstruct the folder tree from the
-- Name paths and attach projects/files to the nearest enclosing folder.

local M = {}

local cache = {}

function M.invalidate(path)
  if path then
    cache[vim.fs.normalize(path)] = nil
  else
    cache = {}
  end
end

local EXT_KIND = {
  csproj = "csharp",
  fsproj = "fsharp",
  vbproj = "vbnet",
}

-- ─── minimal XML ──────────────────────────────────────────────────────────

local NAMED_ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function unescape(s)
  if not s or s:find("&", 1, true) == nil then
    return s
  end
  s = s:gsub("&#x(%x+);", function(h)
    return vim.fn.nr2char(tonumber(h, 16))
  end)
  s = s:gsub("&#(%d+);", function(d)
    return vim.fn.nr2char(tonumber(d))
  end)
  s = s:gsub("&(%a+);", function(name)
    return NAMED_ENTITIES[name] or ("&" .. name .. ";")
  end)
  return s
end

local function parse_attrs(str)
  local attrs = {}
  for k, v in str:gmatch('([%w_:%-%.]+)%s*=%s*"([^"]*)"') do
    attrs[k] = unescape(v)
  end
  for k, v in str:gmatch("([%w_:%-%.]+)%s*=%s*'([^']*)'") do
    if attrs[k] == nil then
      attrs[k] = unescape(v)
    end
  end
  return attrs
end

-- The Microsoft slnx reader matches element/attribute names case-insensitively
-- (it emits PascalCase but accepts any casing). Mirror that.
local function attr_ci(attrs, key)
  if attrs[key] ~= nil then
    return attrs[key]
  end
  local lk = key:lower()
  for k, v in pairs(attrs) do
    if k:lower() == lk then
      return v
    end
  end
  return nil
end

-- Find the '>' that closes a tag, ignoring any '>' that sits inside a quoted
-- attribute value (a literal '>' is legal in XML attribute values).
local function find_tag_end(content, from)
  local i, len = from, #content
  local quote = nil
  while i <= len do
    local c = content:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == ">" then
      return i
    end
    i = i + 1
  end
  return nil
end

-- Build a lightweight element tree. Text nodes are ignored (slnx carries data
-- in attributes only). Tolerant of self-closing tags (with or without spaces
-- around the slash), comments, declarations, and '>' inside attribute values.
local function parse_xml(content)
  content = content:gsub("^\239\187\191", "") -- strip UTF-8 BOM
  content = content:gsub("<!%-%-.-%-%->", "") -- comments
  content = content:gsub("<%?.-%?>", "") -- <?xml ... ?>
  content = content:gsub("<!%[CDATA%[.-%]%]>", "") -- CDATA (irrelevant here)
  content = content:gsub("<!.->", "") -- <!DOCTYPE ...>

  local root = { tag = "#root", attrs = {}, children = {} }
  local stack = { root }
  local pos, len = 1, #content

  while pos <= len do
    local lt = content:find("<", pos, true)
    if not lt then
      break
    end
    local gt = find_tag_end(content, lt + 1)
    if not gt then
      break
    end

    local raw = content:sub(lt + 1, gt - 1):gsub("^%s+", ""):gsub("%s+$", "")
    if raw:sub(1, 1) == "/" then
      if #stack > 1 then
        table.remove(stack)
      end
    elseif raw ~= "" then
      local self_closing = raw:sub(-1) == "/"
      if self_closing then
        raw = raw:gsub("/%s*$", "")
      end
      local name = raw:match("^([%w_:%-%.]+)")
      if name then
        local attr_str = raw:sub(#name + 1)
        local node = { tag = name, attrs = parse_attrs(attr_str), children = {} }
        table.insert(stack[#stack].children, node)
        if not self_closing then
          table.insert(stack, node)
        end
      end
    end
    pos = gt + 1
  end

  return root
end

-- ─── folder path helpers ────────────────────────────────────────────────────

local function norm_folder(p)
  p = p:gsub("\\", "/")
  if p:sub(1, 1) ~= "/" then
    p = "/" .. p
  end
  if p:sub(-1) ~= "/" then
    p = p .. "/"
  end
  p = p:gsub("//+", "/")
  return p
end

local function folder_leaf(normpath)
  local trimmed = normpath:sub(2, -2)
  return trimmed:match("([^/]+)$") or trimmed
end

local function folder_parent(normpath)
  local trimmed = normpath:sub(2, -2)
  local parent = trimmed:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then
    return "/" .. parent .. "/"
  end
  return nil
end

-- ─── tree walk: collect folders / projects / files with ownership ────────────

local function collect(node, folder_ctx, acc)
  for _, child in ipairs(node.children) do
    local tag = (child.tag or ""):lower()
    if tag == "folder" then
      local namepath = attr_ci(child.attrs, "Name")
      if namepath then
        local np = norm_folder(namepath)
        -- Microsoft emits full-path Names even for physically nested <Folder>
        -- elements, so the path is normally authoritative. Defensive guard for
        -- a leaf-relative Name nested inside another folder: compose with the
        -- enclosing path so the child stays attached to its parent.
        if folder_ctx and np:sub(1, #folder_ctx) ~= folder_ctx then
          np = norm_folder(folder_ctx .. namepath:gsub("^/", ""))
        end
        acc.folders[#acc.folders + 1] = np
        collect(child, np, acc)
      else
        collect(child, folder_ctx, acc)
      end
    elseif tag == "project" then
      local p = attr_ci(child.attrs, "Path")
      if p then
        acc.projects[#acc.projects + 1] = {
          path = p,
          folder = folder_ctx,
          displayname = attr_ci(child.attrs, "DisplayName"),
        }
      end
    elseif tag == "file" then
      local p = attr_ci(child.attrs, "Path")
      if p then
        acc.files[#acc.files + 1] = { path = p, folder = folder_ctx }
      end
    else
      -- Configurations, Properties, Solution, etc: keep descending
      collect(child, folder_ctx, acc)
    end
  end
end

-- ─── main ────────────────────────────────────────────────────────────────

function M.parse(slnx_path)
  slnx_path = vim.fs.normalize(slnx_path)
  local stat = vim.uv.fs_stat(slnx_path)
  if not stat then
    return nil, "cannot stat " .. slnx_path
  end
  local mtime = stat.mtime.sec
  local cached = cache[slnx_path]
  if cached and cached.mtime == mtime then
    return cached.data
  end

  local f = io.open(slnx_path, "r")
  if not f then
    return nil, "cannot open " .. slnx_path
  end
  local content = f:read("*a")
  f:close()

  local sln_dir = vim.fn.fnamemodify(slnx_path, ":h")

  local root = parse_xml(content)
  local acc = { folders = {}, projects = {}, files = {} }
  collect(root, nil, acc)

  local projects = {}
  local by_guid = {}
  local folder_entries = {} -- normpath -> entry

  local function ensure_folder(normpath)
    if normpath == "/" then
      return nil -- a Folder Name of "/" (or "") IS the solution root
    end
    if folder_entries[normpath] then
      return folder_entries[normpath]
    end
    local guid = "slnxfolder:" .. normpath
    local entry = {
      guid = guid,
      name = folder_leaf(normpath),
      path = nil,
      kind = "folder",
      type_guid = nil,
      parent_guid = nil,
      children_guids = {},
      solution_items = {},
      _folderpath = normpath,
    }
    folder_entries[normpath] = entry
    by_guid[guid] = entry
    table.insert(projects, entry)
    return entry
  end

  -- register every declared folder plus any missing ancestors
  local declared = {}
  for _, raw in ipairs(acc.folders) do
    declared[norm_folder(raw)] = true
  end
  for np in pairs(declared) do
    local cur = np
    while cur do
      ensure_folder(cur)
      cur = folder_parent(cur)
    end
  end

  -- link folder hierarchy
  for np, entry in pairs(folder_entries) do
    local pp = folder_parent(np)
    if pp and folder_entries[pp] then
      entry.parent_guid = folder_entries[pp].guid
      table.insert(folder_entries[pp].children_guids, entry.guid)
    end
  end

  -- projects
  local seen_proj = {}
  for _, pr in ipairs(acc.projects) do
    local rel = pr.path:gsub("\\", "/")
    local abs
    if rel:match("^%a[%w+.-]*://") then
      abs = rel -- website / URI project: leave the path untouched
    else
      abs = vim.fs.normalize(sln_dir .. "/" .. rel)
    end
    if not seen_proj[abs] then
      seen_proj[abs] = true
      local ext = (abs:match("%.([%w]+)$") or ""):lower()
      local kind = EXT_KIND[ext] or "unknown"
      local guid = "slnxproj:" .. abs
      local entry = {
        guid = guid,
        name = pr.displayname or vim.fn.fnamemodify(abs, ":t:r"),
        path = abs,
        kind = kind,
        type_guid = nil,
        parent_guid = nil,
        children_guids = {},
        solution_items = {},
      }
      if pr.folder then
        local fe = ensure_folder(pr.folder)
        if fe then
          entry.parent_guid = fe.guid
          table.insert(fe.children_guids, guid)
        end
      end
      by_guid[guid] = entry
      table.insert(projects, entry)
    end
  end

  -- files -> solution_items on the owning folder
  for _, fl in ipairs(acc.files) do
    if fl.folder then
      local fe = ensure_folder(fl.folder)
      if fe then
        local rel = fl.path:gsub("\\", "/")
        local abs = vim.fs.normalize(sln_dir .. "/" .. rel)
        table.insert(fe.solution_items, { rel = fl.path, path = abs })
      end
    end
  end

  local result = {
    path = slnx_path,
    name = vim.fn.fnamemodify(slnx_path, ":t"),
    dir = sln_dir,
    projects = projects,
    by_guid = by_guid,
  }
  cache[slnx_path] = { mtime = mtime, data = result }
  return result
end

return M
