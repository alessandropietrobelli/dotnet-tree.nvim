local common = require("neo-tree.sources.common.components")

local M = {}
for k, v in pairs(common) do
  M[k] = v
end

local KIND_ICONS = {
  solution = { "󰘐", "Special" },
  project = { "󰏗", "Function" },
  dependencies = { "", "Type" },
  projrefs = { "", "Function" },
  packages = { "", "Statement" },
  frameworks = { "", "Constant" },
  package = { "󰏗", "String" },
  project_reference = { "󰘐", "Function" },
  framework = { "", "Constant" },
}

function M.icon(config, node, state)
  local kind = node.extra and node.extra.kind
  local mapping = KIND_ICONS[kind]

  if mapping then
    return {
      text = mapping[1] .. " ",
      highlight = mapping[2],
    }
  end

  if kind == "folder" or kind == "sln_folder" then
    local saved_type = node.type
    node.type = "directory"
    local res = common.icon(config, node, state)
    node.type = saved_type
    return res
  end

  return common.icon(config, node, state)
end

function M.name(config, node, state)
  local kind = node.extra and node.extra.kind
  local hl = "NeoTreeFileName"
  if kind == "solution" then
    hl = "NeoTreeRootName"
  elseif kind == "project" or kind == "project_reference" then
    hl = "Function"
  elseif kind == "sln_folder" or kind == "dependencies" or kind == "projrefs" or kind == "packages" or kind == "frameworks" then
    hl = "NeoTreeDirectoryName"
  elseif kind == "package" then
    hl = "String"
  elseif kind == "framework" then
    hl = "Constant"
  elseif kind == "folder" then
    hl = "NeoTreeDirectoryName"
  end
  return { text = node.name, highlight = hl }
end

return M
