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

-- An MSBuild property is whatever the last unconditional assignment says. A
-- `Condition` we cannot evaluate is skipped rather than guessed at, so a
-- property declared only conditionally reads as nil -- unknown -- and the
-- caller decides what to do about it. The value itself is returned as written:
-- a `$(Property)` reference is not expanded here, same as everywhere else in
-- this parser.
local function read_property(root, name)
  local value = nil
  for _, group in ipairs(xml.find_all(root, "PropertyGroup")) do
    if xml.attr_ci(group.attrs, "Condition") == nil then
      for _, node in ipairs(group.children) do
        if node.tag == name and xml.attr_ci(node.attrs, "Condition") == nil and node.text ~= "" then
          value = node.text
        end
      end
    end
  end
  return value
end

-- MSBuild booleans are the strings "true" and "false", compared without regard
-- to case. Anything else -- an unevaluated property, a typo -- is not a
-- boolean, and is treated as "the project did not say".
local function msbuild_bool(value)
  if value == nil then
    return nil
  end
  local lowered = value:lower()
  if lowered == "true" then
    return true
  elseif lowered == "false" then
    return false
  end
  return nil
end

-- The package that makes a project a test project as far as MSBuild is
-- concerned: it is what brings in the test targets, and every template that
-- produces a test project references it. NuGet ids are case-insensitive.
local TEST_SDK = "microsoft.net.test.sdk"

local function references_test_sdk(packages)
  for _, package in ipairs(packages) do
    if package.name:lower() == TEST_SDK then
      return true
    end
  end
  return false
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

  local root = xml.parse(content)

  -- What an action needs before it can point at a project's build output:
  -- whether the project produces something runnable, and what the file is
  -- called. Both stay nil when the project does not say, and the defaults are
  -- the caller's -- MSBuild's own are "Library" and the project file's
  -- basename, and the caller is the one that knows which it is looking at.
  result.output_type = read_property(root, "OutputType")
  result.assembly_name = read_property(root, "AssemblyName")

  -- A PackageReference declares its version either as a `Version` attribute or
  -- as a `<Version>` child element; MSBuild accepts both and repositories
  -- contain both. Reading the element tree covers the two forms in one pass.
  -- The two text patterns that used to do this could not: the single-line one
  -- matched the opening tag of the child-element form and recorded an empty
  -- version, which then hid that package from the loop written to read it.
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

  -- Whether this is a test project, as far as *this file* says. OutputType
  -- does not answer it: an xunit v3 test project declares `Exe`, because v3
  -- runs each test assembly as its own process -- all 16 test projects in a
  -- jellyfin checkout do. An explicit property wins over the package reference,
  -- the way it does in MSBuild, so a project that opts out with
  -- `<IsTestProject>false</IsTestProject>` is believed.
  local declared_test = msbuild_bool(read_property(root, "IsTestProject"))
  if declared_test ~= nil then
    result.is_test_project = declared_test
  else
    result.is_test_project = references_test_sdk(result.packages)
  end

  cache[csproj_path] = { mtime = mtime, data = result }
  return result
end

return M
