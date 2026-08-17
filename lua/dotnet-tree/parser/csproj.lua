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

  -- PackageReference Include="X" Version="Y" (single line)
  local seen_pkg = {}
  for tag in content:gmatch("<PackageReference%s(.-)>") do
    local include = tag:match('Include%s*=%s*"([^"]+)"')
    local version = tag:match('Version%s*=%s*"([^"]+)"')
    if include and not seen_pkg[include] then
      seen_pkg[include] = true
      table.insert(result.packages, { name = include, version = version or "" })
    end
  end
  -- PackageReference with multiline (Version as child element)
  for include, inner in content:gmatch('<PackageReference[^>]*Include%s*=%s*"([^"]+)"[^>]*>(.-)</PackageReference>') do
    if not seen_pkg[include] then
      seen_pkg[include] = true
      local version = inner:match("<Version>%s*([^<]-)%s*</Version>") or ""
      table.insert(result.packages, { name = include, version = version })
    end
  end

  -- The attribute blob is captured with a non-greedy `.-` rather than a
  -- negated class: `[^/>]` would stop at the first slash, which silently
  -- dropped every reference written with forward slashes -- the normal style
  -- in repositories authored on macOS or Linux.
  for tag in content:gmatch("<ProjectReference%s(.-)>") do
    local include = tag:match('Include%s*=%s*"([^"]+)"')
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
