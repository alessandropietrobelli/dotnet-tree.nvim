-- Optional integration with nuget.nvim (https://github.com/alessandropietrobelli/nuget.nvim).
--
-- When it is installed, adding a package opens its window instead of asking for a name, and the
-- tree reloads after it changes packages. Without it nothing here does anything. Kept apart from
-- commands.lua, which needs neo-tree, so it can be tested on its own.
local M = {}

--- nuget.nvim's module, when it is installed and recent enough to take these options.
---@return table?
function M.module()
  local ok, nuget = pcall(require, "nuget")
  if ok and type(nuget) == "table" and type(nuget.open) == "function" then
    return nuget
  end
end

--- Open nuget.nvim for a node of the tree. Returns false when it is not installed, so the caller
--- can fall back to its own prompt.
---@param kind "packages"|"package" the node under the cursor
---@param opts {project: string, solution: string?, package: string?}
---@return boolean
function M.open(kind, opts)
  local nuget = M.module()
  if not nuget then
    return false
  end
  if kind == "package" and opts.package then
    -- The package's row: its versions per project, updates, advisories
    nuget.open({ package = opts.package, project = opts.project, solution = opts.solution })
  else
    -- Search and install, with this project already picked
    nuget.open({ tab = "browse", project = opts.project, solution = opts.solution })
  end
  return true
end

--- Call `refresh` after nuget.nvim changes packages: it rewrote project and props files outside
--- Neovim, so the tree has to read them again.
---@param group integer augroup
---@param refresh fun()
function M.watch(group, refresh)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NugetPackagesChanged",
    callback = function()
      require("dotnet-tree.parser.csproj").invalidate()
      require("dotnet-tree.parser.cpm").invalidate()
      require("dotnet-tree.parser.props").invalidate()
      refresh()
    end,
  })
end

return M
