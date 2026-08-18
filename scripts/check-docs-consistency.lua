-- Keep the install instructions in README.md and doc/dotnet-tree.txt from drifting apart.
--
-- Both documents describe the same lazy.nvim spec, and nothing but attention has been
-- keeping them in agreement. Twice in one day that attention was not enough: v0.1.1
-- shipped a README with `lazy = false` and a manual without it, and a troubleshooting
-- entry quoting an error neo-tree does not raise.
--
-- This compares substance, not bytes. The two files wrap differently -- the manual is
-- held to 78 columns and the README is not -- so a textual diff would fail on a line
-- break and get switched off within a fortnight. Instead it asserts a short list of
-- claims that must hold in both, and a short list of strings that must appear in
-- neither. Add to those lists when a future fix has to land in both places.
--
-- Run: nvim -l scripts/check-docs-consistency.lua

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

if #failures > 0 then
  io.stderr:write("README.md and doc/dotnet-tree.txt document the same install, and they disagree.\n\n")
  for _, message in ipairs(failures) do
    io.stderr:write("  - " .. message .. "\n")
  end
  io.stderr:write("\nFix the document named above, then re-run: nvim -l scripts/check-docs-consistency.lua\n")
  os.exit(1)
end

print(("install instructions agree across %d documents"):format(#DOCS))
