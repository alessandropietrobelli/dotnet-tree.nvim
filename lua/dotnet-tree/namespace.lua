-- The namespace a new file gets from the folder it is created in: the
-- project's root namespace, then one part per folder below the project, as
-- Visual Studio and Rider write it.
local csproj = require("dotnet-tree.parser.csproj")

local M = {}

-- A part as C# accepts it: what is not a letter, a digit or `_` becomes `_`,
-- and a leading digit gets a `_` in front
local function identifier(part)
  part = part:gsub("[^%w_]", "_")
  if part:match("^%d") then
    part = "_" .. part
  end
  return part
end

--- The project's root namespace: `<RootNamespace>` from the project or the
--- Directory.Build.props above it, with `$(MSBuildProjectName)` and
--- `$(AssemblyName)` expanded; otherwise MSBuild's default, the project's name
--- with spaces as `_`. A value with another `$(...)` falls back to the default.
---@param project_path string
---@return string
function M.root(project_path)
  local name = vim.fn.fnamemodify(project_path, ":t:r")
  local project = csproj.parse(project_path) or {}
  local declared = project.root_namespace
  if declared then
    local assembly = project.assembly_name or name
    declared = declared:gsub("%$%(MSBuildProjectName%)", (name:gsub("%%", "%%%%")))
    declared = declared:gsub("%$%(AssemblyName%)", (assembly:gsub("%%", "%%%%")))
    if not declared:find("$(", 1, true) and vim.trim(declared) ~= "" then
      return vim.trim(declared)
    end
  end
  return (name:gsub(" ", "_"))
end

--- The namespace for a file created in `dir`, inside the project at
--- `project_path`.
---@param project_path string
---@param dir string
---@return string
function M.for_dir(project_path, dir)
  local parts = {}
  for part in M.root(project_path):gmatch("[^.]+") do
    table.insert(parts, identifier(part))
  end
  local project_dir = vim.fs.normalize(vim.fn.fnamemodify(project_path, ":h"))
  local target = vim.fs.normalize(dir)
  if target:sub(1, #project_dir) == project_dir then
    for folder in target:sub(#project_dir + 1):gmatch("[^/]+") do
      table.insert(parts, identifier(folder))
    end
  end
  return table.concat(parts, ".")
end

return M
