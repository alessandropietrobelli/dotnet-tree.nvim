-- Keep the documentation from drifting away from what the project actually does.
--
-- Two independent checks, both of the same shape: a fact is written down in more than
-- one place, and nothing but attention keeps the copies in agreement.
--
--   1. The install instructions in README.md and doc/dotnet-tree.txt
--   2. The commands CONTRIBUTING.md tells you to run, against the ones CI runs
--
-- On the first: both documents describe the same lazy.nvim spec, and twice in one day
-- attention was not enough. v0.1.1 shipped a README with `lazy = false` and a manual
-- without it, plus a troubleshooting entry quoting an error neo-tree does not raise.
--
-- Throughout, this compares substance, not bytes. The two files wrap differently -- the manual is
-- held to 78 columns and the README is not -- so a textual diff would fail on a line
-- break and get switched off within a fortnight. Instead it asserts a short list of
-- claims that must hold in both, and a short list of strings that must appear in
-- neither. Add to those lists when a future fix has to land in both places.
--
-- Run: nvim -l scripts/check-docs-consistency.lua

local CI = ".github/workflows/ci.yml"
local CONTRIBUTING = "CONTRIBUTING.md"

local DOCS = { "README.md", "doc/dotnet-tree.txt" }

-- Present in both documents, or the install instructions are wrong somewhere.
local REQUIRED = {
  {
    text = "lazy = false",
    why = "without it neo-tree is deferred, nothing is on the runtimepath, and "
      .. ":checkhealth, :help and :Neotree all fail on a fresh install",
  },
  {
    text = 'branch = "v3.x"',
    why = "pins neo-tree to the major version this source is written against",
  },
  {
    text = '"dotnet-tree"',
    why = "the source has to be registered in neo-tree's sources; installing the plugin is not enough",
  },
}

-- Retired strings. Each one was published, turned out to be wrong, and was corrected;
-- this stops it coming back in either document.
local RETIRED = {
  {
    text = "Source dotnet-tree not found",
    why = 'neo-tree never emits this. The real error is "Invalid argument: dotnet-tree", '
      .. "from its command parser, and a reader searching for the real text found nothing",
  },
}

-- Every dependency the lazy.nvim spec declares, in both documents.
local DEPENDENCIES = {
  "nvim-lua/plenary.nvim",
  "MunifTanjim/nui.nvim",
  "nvim-tree/nvim-web-devicons",
  "alessandropietrobelli/dotnet-tree.nvim",
}

local failures = {}

local function fail(fmt, ...)
  table.insert(failures, string.format(fmt, ...))
end

local function read(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

for _, path in ipairs(DOCS) do
  local body = read(path)
  if not body then
    fail("%s: cannot be read", path)
  else
    for _, claim in ipairs(REQUIRED) do
      if not body:find(claim.text, 1, true) then
        fail("%s: missing %s\n    %s", path, claim.text, claim.why)
      end
    end

    for _, dead in ipairs(RETIRED) do
      if body:find(dead.text, 1, true) then
        fail("%s: still contains the retired string %q\n    %s", path, dead.text, dead.why)
      end
    end

    for _, dep in ipairs(DEPENDENCIES) do
      if not body:find(dep, 1, true) then
        fail("%s: install snippet does not list %s", path, dep)
      end
    end
  end
end

-- The commands CONTRIBUTING.md documents have to be the ones CI actually runs.
--
-- CONTRIBUTING said `stylua lua/ tests/` and `luacheck lua/` for a month after CI had
-- been widened to cover scripts/ too, so anyone following it to the letter formatted
-- less than CI checked and got a red build for doing as they were told.
--
-- The paths are read out of ci.yml rather than written down here on purpose. A third
-- hardcoded list would be a third copy, free to drift exactly like the two this script
-- already exists to police. Widen a CI job and this fails until CONTRIBUTING catches up.
local function paths_in(argline)
  local paths = {}
  for token in argline:gmatch("%S+") do
    if not token:match("^%-") then
      table.insert(paths, token)
    end
  end
  return paths
end

local ci = read(CI)
local contributing = read(CONTRIBUTING)

if not ci then
  fail("%s: cannot be read", CI)
elseif not contributing then
  fail("%s: cannot be read", CONTRIBUTING)
else
  -- an array, not a hash: the same breakage should always print the same way
  local ci_commands = {
    { tool = "stylua", argline = ci:match("args:%s*([^\n]*)") },
    { tool = "luacheck", argline = ci:match("run:%s*luacheck([^\n]*)") },
  }

  for _, command in ipairs(ci_commands) do
    local tool, argline = command.tool, command.argline
    if not argline then
      fail("%s: cannot find how CI invokes %s -- this script needs updating", CI, tool)
    else
      local documented = contributing:match("\n(" .. tool .. "[^\n]*)")
      if not documented then
        fail("%s: does not tell contributors to run %s, but CI does", CONTRIBUTING, tool)
      else
        for _, path in ipairs(paths_in(argline)) do
          if not documented:find(path, 1, true) then
            fail(
              "%s: documents `%s` but CI runs %s over %s as well\n    "
                .. "a contributor following this file gets a red build for doing as they were told",
              CONTRIBUTING,
              documented:gsub("%s*#.*$", ""),
              tool,
              path
            )
          end
        end
      end
    end
  end

  -- every script CI runs through `nvim -l` should be runnable locally too
  for script in ci:gmatch("run:%s*nvim %-l%s+(%S+)") do
    if not contributing:find(script, 1, true) then
      fail("%s: does not mention `nvim -l %s`, which CI runs on every pull request", CONTRIBUTING, script)
    end
  end
end

if #failures > 0 then
  io.stderr:write("The documentation disagrees with itself, or with what CI does.\n\n")
  for _, message in ipairs(failures) do
    io.stderr:write("  - " .. message .. "\n")
  end
  io.stderr:write("\nFix the document named above, then re-run: nvim -l scripts/check-docs-consistency.lua\n")
  os.exit(1)
end

print(("install instructions agree across %d documents, and CONTRIBUTING matches CI"):format(#DOCS))
