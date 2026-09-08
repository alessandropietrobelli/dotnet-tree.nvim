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

function M.parse(csproj_path)
  csproj_path = vim.fs.normalize(csproj_path)
  local stat = vim.uv.fs_stat(csproj_path)
  if not stat then
    return nil
  end
  local mtime = stat.mtime.sec
  local cached = cache[csproj_path]
  if cached and cached.mtime == mtime then
    return cached.data
  end

  local f = io.open(csproj_path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  -- Drop comments before scanning, the way parser/slnx.lua already does.
  -- Without this a commented-out entry is reported as a real dependency, which
  -- is worse than missing one: the tree shows something that is not there.
  content = content:gsub("<!%-%-.-%-%->", "")

  local result = {
    path = csproj_path,
    dir = vim.fn.fnamemodify(csproj_path, ":h"),
    target_frameworks = {},
    packages = {},
    project_references = {},
    sdk_style = content:match("<Project%s+[^>]*Sdk=") ~= nil,
  }

  for tf in content:gmatch("<TargetFramework>%s*([^<]-)%s*</TargetFramework>") do
    table.insert(result.target_frameworks, tf)
  end
  for tfs in content:gmatch("<TargetFrameworks>%s*([^<]-)%s*</TargetFrameworks>") do
    for tf in tfs:gmatch("([^;%s]+)") do
      table.insert(result.target_frameworks, tf)
    end
  end

  -- A PackageReference declares its version either as a `Version` attribute or
  -- as a `<Version>` child element; MSBuild accepts both and repositories
  -- contain both. Reading the element tree covers the two forms in one pass.
  -- The two text patterns that used to do this could not: the single-line one
  -- matched the opening tag of the child-element form and recorded an empty
  -- version, which then hid that package from the loop written to read it.
  local root = xml.parse(content)
  local seen_pkg = {}
  for _, node in ipairs(xml.find_all(root, "PackageReference")) do
    local include = xml.attr_ci(node.attrs, "Include")
    if include and not seen_pkg[include] then
      seen_pkg[include] = true
      local version = xml.attr_ci(node.attrs, "Version") or xml.child_text(node, "Version") or ""
      table.insert(result.packages, { name = include, version = version })
    end
  end

  -- Read from the same element tree. The pattern this replaces captured the
  -- attribute blob with a non-greedy `.-`, which two earlier fixes had to
  -- widen: `[^/>]` dropped every reference written with forward slashes, and
  -- `.-` still stopped at a literal '>' inside a quoted value.
  for _, node in ipairs(xml.find_all(root, "ProjectReference")) do
    local include = xml.attr_ci(node.attrs, "Include")
    if include then
      local norm = include:gsub("\\", "/")
      local abs = vim.fs.normalize(result.dir .. "/" .. norm)
      table.insert(result.project_references, { include = include, path = abs })
    end
  end

  cache[csproj_path] = { mtime = mtime, data = result }
  return result
end

return M
