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

  local versions = {}
  for tag in content:gmatch("<PackageVersion%s(.-)>") do
    local include = tag:match('Include%s*=%s*"([^"]+)"')
    local version = tag:match('Version%s*=%s*"([^"]+)"')
    if include and version then
      versions[include] = version
    end
  end
  for include, inner in content:gmatch('<PackageVersion[^>]*Include%s*=%s*"([^"]+)"[^>]*>(.-)</PackageVersion>') do
    if not versions[include] then
      local version = inner:match("<Version>%s*([^<]-)%s*</Version>")
      if version then
        versions[include] = version
      end
    end
  end

  cache[props_path] = { mtime = mtime, data = versions }
  return versions
end

function M.find_props(start_dir, stop_dir)
  local dir = vim.fs.normalize(start_dir)
  stop_dir = stop_dir and vim.fs.normalize(stop_dir) or nil
  local guard = 32
  while dir and dir ~= "" and guard > 0 do
    guard = guard - 1
    local candidate = dir .. "/Directory.Packages.props"
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    if stop_dir and dir == stop_dir then
      break
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

return M
