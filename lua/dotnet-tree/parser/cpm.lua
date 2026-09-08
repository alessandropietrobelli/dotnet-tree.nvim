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

function M.parse(props_path)
  props_path = vim.fs.normalize(props_path)
  local stat = vim.uv.fs_stat(props_path)
  if not stat then
    return {}
  end
  local mtime = stat.mtime.sec
  local cached = cache[props_path]
  if cached and cached.mtime == mtime then
    return cached.data
  end

  local f = io.open(props_path, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()

  content = content:gsub("<!%-%-.-%-%->", "")

  -- Same two forms as a PackageReference in a .csproj: a `Version` attribute
  -- or a `<Version>` child element. Read from the element tree, as csproj.lua
  -- does, rather than from two text patterns -- the multi-line one used to run
  -- from the first <PackageVersion> in the file to the first </PackageVersion>,
  -- swallowing every self-closing entry in between.
  local versions = {}
  for _, node in ipairs(xml.find_all(xml.parse(content), "PackageVersion")) do
    local include = xml.attr_ci(node.attrs, "Include")
    local version = xml.attr_ci(node.attrs, "Version") or xml.child_text(node, "Version")
    if include and version and versions[include] == nil then
      versions[include] = version
    end
  end

  cache[props_path] = { mtime = mtime, data = versions }
  return versions
end

-- Same upward walk as every other implicitly imported MSBuild file; it lives
-- in parser/props.lua so the Directory.Build.props lookup and this one cannot
-- drift apart.
function M.find_props(start_dir, stop_dir)
  return props.find_up(start_dir, "Directory.Packages.props", stop_dir)
end

return M
