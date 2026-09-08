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
-- One `Import` is followed, and only one form of it: the
-- `$([MSBuild]::GetPathOfFileAbove('Directory.Build.props', ...))` that a
-- `src/Directory.Build.props` uses to chain to the repository-root one (#30).
-- Stopping at the nearest file was right for jellyfin, whose nearest props
-- file names the framework itself, and wrong for every repository that splits
-- rules between `src/` and `tests/`: there the nearest file names no framework
-- at all, it imports the file that does.
--
-- It is still not MSBuild evaluation. No other `Import` is followed, a
-- property defined further up than the chain reaches is not seen, and a
-- framework written as `$(DefaultTfm)` stays unknown rather than being guessed
-- at.

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

-- Whether a props file chains to the one above it with the single import form
-- in scope: `<Import Project="$([MSBuild]::GetPathOfFileAbove(
-- 'Directory.Build.props', ...))" />`. Only the file name argument is read --
-- the second argument is a start directory, and "the nearest
-- Directory.Build.props strictly above this one" is what every use of it in a
-- repository root chain means. A path built out of a `$(Property)` is not
-- resolved, so an import whose file name argument is not a literal
-- `Directory.Build.props` is not followed.
--
-- A `Condition` on the import is not decided. Following it anyway is safe here
-- and nowhere else in this file: an inherited framework is only ever consulted
-- when neither the project nor any nearer props file named one, so the choice
-- is between a candidate and nothing at all -- not between two answers.
local function imports_file_above(root)
  for _, node in ipairs(xml.find_all(root, "Import")) do
    local project = xml.attr_ci(node.attrs, "Project") or ""
    local arg = project:match("GetPathOfFileAbove%s*%(%s*['\"]([^'\"]+)['\"]")
    if arg and arg:lower() == "directory.build.props" then
      return true
    end
  end
  return false
end

-- One props file, parsed once per (path, mtime): the frameworks it names and
-- whether it chains upward.
local function read_props(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local mtime = stat.mtime.sec
  local cached = cache[path]
  if not (cached and cached.mtime == mtime) then
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local content = f:read("*a")
    f:close()
    local root = xml.parse(content)
    cached = { mtime = mtime, frameworks = M.frameworks(root), imports_above = imports_file_above(root) }
    cache[path] = cached
  end
  return cached
end

-- The frameworks inherited by a project in `dir`, from the nearest
-- `Directory.Build.props` at or above it and, when that file only chains
-- upward, from the file it chains to.
--
-- The second return value is a stamp over every props file the walk actually
-- read, path and mtime, so a caller that caches a project can tell when any of
-- them changed underneath it -- adding a props file in a closer directory
-- moves the whole chain. It is nil only when there is no props file above the
-- project at all; the frameworks are nil whenever the chain named none.
--
-- The chain is bounded by the same guard `find_up` uses, and each step looks
-- strictly above the file it came from, so a props file cannot import itself
-- into a loop.
function M.inherited_frameworks(dir)
  local path = M.find_up(dir, "Directory.Build.props")
  local stamp = {}
  local guard = 32
  while path and guard > 0 do
    guard = guard - 1
    path = vim.fs.normalize(path)
    local entry = read_props(path)
    if not entry then
      break
    end
    table.insert(stamp, path .. "@" .. entry.mtime)
    if #entry.frameworks > 0 then
      return vim.deepcopy(entry.frameworks), table.concat(stamp, "|")
    end
    if not entry.imports_above then
      break
    end
    -- Strictly above: start the next lookup in the parent of this file's own
    -- directory, never in it.
    local dir_of_file = vim.fn.fnamemodify(path, ":h")
    local above = vim.fn.fnamemodify(dir_of_file, ":h")
    path = above ~= dir_of_file and M.find_up(above, "Directory.Build.props") or nil
  end
  if #stamp == 0 then
    return nil, nil
  end
  return nil, table.concat(stamp, "|")
end

return M
