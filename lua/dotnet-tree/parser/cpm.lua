-- Central package management: the versions a `Directory.Packages.props` sets.
--
-- MSBuild looks for that file from each project's directory upward, so two
-- projects of one solution can use two different files (#56). A nested file
-- usually chains to the repository-root one with
-- `$([MSBuild]::GetPathOfFileAbove('Directory.Packages.props', ...))`, the
-- same form props.lua follows for Directory.Build.props, and then overrides a
-- version or two with `<PackageVersion Update="..." />`.
--
-- It is not MSBuild evaluation: only that import is followed, and the file it
-- imports is taken to come first, which is where every chain puts it.
local props = require("dotnet-tree.parser.props")
local xml = require("dotnet-tree.parser.xml")

local M = {}

local cache = {}

function M.invalidate(path)
  if path then
    cache[vim.fs.normalize(path)] = nil
  else
    cache = {}
  end
end

-- One props file, parsed once per (path, mtime): its PackageVersion entries in
-- document order, and whether it chains to the file above.
local function read(props_path)
  props_path = vim.fs.normalize(props_path)
  local stat = vim.uv.fs_stat(props_path)
  if not stat then
    return nil
  end
  local mtime = stat.mtime.sec
  local cached = cache[props_path]
  if cached and cached.mtime == mtime then
    return cached
  end

  local f = io.open(props_path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  content = content:gsub("<!%-%-.-%-%->", "")
  local root = xml.parse(content)

  -- Same two forms as a PackageReference in a .csproj: a `Version` attribute
  -- or a `<Version>` child element. Read from the element tree, as csproj.lua
  -- does, rather than from two text patterns -- the multi-line one used to run
  -- from the first <PackageVersion> in the file to the first </PackageVersion>,
  -- swallowing every self-closing entry in between.
  local entries = {}
  for _, node in ipairs(xml.find_all(root, "PackageVersion")) do
    local include = xml.attr_ci(node.attrs, "Include")
    local update = xml.attr_ci(node.attrs, "Update")
    local version = xml.attr_ci(node.attrs, "Version") or xml.child_text(node, "Version")
    if version and (include or update) then
      table.insert(entries, { name = include or update, version = version, update = include == nil })
    end
  end

  cached = {
    mtime = mtime,
    entries = entries,
    imports_above = props.imports_file_above(root, "Directory.Packages.props"),
  }
  cache[props_path] = cached
  return cached
end

-- Apply one file's entries to `versions`. An Include defines a version, the
-- first one in a file winning; an Update changes one defined before it, here or
-- in a file this one imports, and does nothing otherwise, as in MSBuild.
local function apply(versions, entries)
  local defined_here = {}
  for _, e in ipairs(entries) do
    if e.update then
      if versions[e.name] ~= nil then
        versions[e.name] = e.version
      end
    elseif not defined_here[e.name] then
      defined_here[e.name] = true
      versions[e.name] = e.version
    end
  end
end

--- The versions one props file sets on its own, without the files it imports.
---@param props_path string
---@return table<string, string>
function M.parse(props_path)
  local entry = read(props_path)
  local versions = {}
  if entry then
    apply(versions, entry.entries)
  end
  return versions
end

--- The versions central package management gives a project in `dir`: from the
--- nearest Directory.Packages.props at or above it, and from the files it
--- chains to, the nearer file overriding. Nil when no file applies.
---@param dir string the project's directory
---@return table<string, string>|nil
function M.versions_for(dir)
  local chain = {}
  local path = M.find_props(dir)
  local guard = 32
  while path and guard > 0 do
    guard = guard - 1
    local entry = read(path)
    if not entry then
      break
    end
    table.insert(chain, entry)
    if not entry.imports_above then
      break
    end
    -- Strictly above this file's directory, so a file cannot import itself.
    local dir_of_file = vim.fn.fnamemodify(vim.fs.normalize(path), ":h")
    local above = vim.fn.fnamemodify(dir_of_file, ":h")
    path = above ~= dir_of_file and M.find_props(above) or nil
  end
  if #chain == 0 then
    return nil
  end
  local versions = {}
  -- The imported file first: the nearer one's entries come after it.
  for i = #chain, 1, -1 do
    apply(versions, chain[i].entries)
  end
  return versions
end

-- Same upward walk as every other implicitly imported MSBuild file; it lives
-- in parser/props.lua so the Directory.Build.props lookup and this one cannot
-- drift apart.
function M.find_props(start_dir, stop_dir)
  return props.find_up(start_dir, "Directory.Packages.props", stop_dir)
end

return M
