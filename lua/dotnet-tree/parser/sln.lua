local M = {}

local cache = {}

function M.invalidate(path)
  if path then
    cache[vim.fs.normalize(path)] = nil
  else
    cache = {}
  end
end

local PROJECT_TYPES = {
  ["FAE04EC0-301F-11D3-BF4B-00C04F79EFBC"] = "csharp",
  ["9A19103F-16F7-4668-BE54-9A1E7A4F7556"] = "csharp",
  ["F2A71F9B-5D33-465A-A702-920D77279786"] = "fsharp",
  ["F184B08F-C81C-45F6-A57F-5ABD9991F28F"] = "vbnet",
  ["2150E333-8FDC-42A3-9474-1A3956D46DE8"] = "folder",
}

function M.parse(sln_path)
  sln_path = vim.fs.normalize(sln_path)
  local stat = vim.uv.fs_stat(sln_path)
  if not stat then
    return nil, "cannot stat " .. sln_path
  end
  local mtime = stat.mtime.sec
  local cached = cache[sln_path]
  if cached and cached.mtime == mtime then
    return cached.data
  end

  local f = io.open(sln_path, "r")
  if not f then
    return nil, "cannot open " .. sln_path
  end
  local content = f:read("*a")
  f:close()

  local sln_dir = vim.fn.fnamemodify(sln_path, ":h")
  local projects = {}
  local by_guid = {}

  for type_guid, name, rel_path, guid, body in content:gmatch(
    'Project%("{([^}]+)}"%)%s*=%s*"([^"]+)",%s*"([^"]+)",%s*"{([^}]+)}"(.-)\nEndProject\r?\n'
  ) do
    type_guid = type_guid:upper()
    guid = guid:upper()
    local kind = PROJECT_TYPES[type_guid] or "unknown"
    local abs_path = nil
    if kind ~= "folder" then
      abs_path = vim.fs.normalize(sln_dir .. "/" .. rel_path:gsub("\\", "/"))
    end

    local solution_items = {}
    local items_section = body:match("ProjectSection%(SolutionItems%)%s*=%s*preProject(.-)EndProjectSection")
    if items_section then
      for line in items_section:gmatch("[^\r\n]+") do
        local rel = line:match("^%s*(.-)%s*=")
        if rel and rel ~= "" then
          local abs = vim.fs.normalize(sln_dir .. "/" .. rel:gsub("\\", "/"))
          table.insert(solution_items, { rel = rel, path = abs })
        end
      end
    end

    local proj = {
      guid = guid,
      type_guid = type_guid,
      name = name,
      path = abs_path,
      kind = kind,
      parent_guid = nil,
      children_guids = {},
      solution_items = solution_items,
    }
    table.insert(projects, proj)
    by_guid[guid] = proj
  end

  local nested = content:match("GlobalSection%(NestedProjects%).-EndGlobalSection")
  if nested then
    for child, parent in nested:gmatch("{([^}]+)}%s*=%s*{([^}]+)}") do
      child = child:upper()
      parent = parent:upper()
      if by_guid[child] and by_guid[parent] then
        by_guid[child].parent_guid = parent
        table.insert(by_guid[parent].children_guids, child)
      end
    end
  end

  local result = {
    path = sln_path,
    name = vim.fn.fnamemodify(sln_path, ":t"),
    dir = sln_dir,
    projects = projects,
    by_guid = by_guid,
  }
  cache[sln_path] = { mtime = mtime, data = result }
  return result
end

return M
