-- The MSBuild framework properties, and the `Directory.Build.props` above a
-- project file.
--
-- MSBuild imports `Directory.Build.props` implicitly, at the top of every
-- project, which is why a project can declare no `TargetFramework` of its own
-- and still target one (15 of jellyfin's 42 projects, #23). What is read here
-- is deliberately narrow: the frameworks from the *nearest* props file, found
-- with the same upward walk and the same stopping rule cpm.lua already uses
-- for `Directory.Packages.props`.
--
-- It is not MSBuild evaluation. An `Import` inside a props file is not
-- followed, a property defined further up the tree than the nearest props file
-- is not seen, and a framework written as `$(DefaultTfm)` stays unknown rather
-- than being guessed at.

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

-- The nearest `filename` at or above `start_dir`, or nil. Stops at `stop_dir`
-- when one is given, at the filesystem root otherwise; the guard is what keeps
-- a symlinked parent from turning the walk into a loop.
function M.find_up(start_dir, filename, stop_dir)
  local dir = vim.fs.normalize(start_dir)
  stop_dir = stop_dir and vim.fs.normalize(stop_dir) or nil
  local guard = 32
  while dir and dir ~= "" and guard > 0 do
    guard = guard - 1
    local candidate = dir .. "/" .. filename
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

local function push_frameworks(list, seen, text)
  -- `TargetFrameworks` is semicolon separated; `TargetFramework` is a single
  -- value, and splitting it the same way costs nothing and cannot go wrong.
  for tf in text:gmatch("([^;%s]+)") do
    if not tf:find("%$%(", 1, false) and not seen[tf] then
      seen[tf] = true
      table.insert(list, tf)
    end
  end
end

-- Every framework an element tree names, in document order, without
-- duplicates.
--
-- Read from the tree the way `OutputType` is (#16), rather than with a literal
-- `<TargetFramework>` text pattern: the pattern required nothing between the
-- tag name and the '>', so `<TargetFramework Condition="...">net9.0</...>`
-- read as no framework at all even though the value sits in the file we are
-- already reading.
--
-- Frameworks differ from a single-valued property such as `OutputType` in what
-- a `Condition` should mean. `OutputType` gets one answer and a guess picks the
-- wrong build output, so an unevaluated condition reads as unknown. Frameworks
-- are a list the tree displays, so a conditional assignment is kept as a
-- candidate -- but only when nothing unconditional names a framework, so a
-- project whose real answer is written plainly is never widened by a branch we
-- cannot evaluate.
function M.frameworks(root)
  local plain, conditional = {}, {}
  local seen_plain, seen_conditional = {}, {}
  for _, group in ipairs(xml.find_all(root, "PropertyGroup")) do
    local group_conditional = xml.attr_ci(group.attrs, "Condition") ~= nil
    for _, node in ipairs(group.children) do
      if (node.tag == "TargetFramework" or node.tag == "TargetFrameworks") and node.text ~= "" then
        if group_conditional or xml.attr_ci(node.attrs, "Condition") ~= nil then
          push_frameworks(conditional, seen_conditional, node.text)
        else
          push_frameworks(plain, seen_plain, node.text)
        end
      end
    end
  end
  if #plain > 0 then
    return plain
  end
  return conditional
end

-- The frameworks declared by the nearest `Directory.Build.props` at or above
-- `dir`, plus the file and mtime they were read from so a caller that caches a
-- project can tell when the props file changed under it. All three are nil when
-- there is no props file above the project.
function M.inherited_frameworks(dir)
  local path = M.find_up(dir, "Directory.Build.props")
  if not path then
    return nil, nil, nil
  end
  path = vim.fs.normalize(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, nil, nil
  end
  local mtime = stat.mtime.sec
  local cached = cache[path]
  if not (cached and cached.mtime == mtime) then
    local f = io.open(path, "r")
    if not f then
      return nil, nil, nil
    end
    local content = f:read("*a")
    f:close()
    cached = { mtime = mtime, frameworks = M.frameworks(xml.parse(content)) }
    cache[path] = cached
  end
  return vim.deepcopy(cached.frameworks), path, mtime
end

return M
