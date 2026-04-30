local cc = require("neo-tree.sources.common.commands")

local M = {}
for k, v in pairs(cc) do
  M[k] = v
end

local NON_OPENABLE = {
  package = true,
  framework = true,
  packages = true,
  frameworks = true,
  projrefs = true,
  dependencies = true,
  sln_folder = true,
  solution = true,
}

function M.refresh(state)
  require("dotnet-tree").navigate(state)
end

function M.open(state)
  local node = state.tree:get_node()
  if not node then
    return
  end
  local kind = node.extra and node.extra.kind

  if NON_OPENABLE[kind] or node.type == "directory" then
    if node:has_children() then
      cc.toggle_node(state)
    end
    return
  end

  if kind == "project_reference" or kind == "project" then
    if node.path then
      cc.open(state)
    end
    return
  end

  if node.path then
    cc.open(state)
  end
end

function M.select_solution(state)
  local cwd = state.path or vim.fn.getcwd()
  local slns = vim.fn.globpath(cwd, "*.sln", false, true)
  if #slns == 0 then
    slns = vim.fn.globpath(cwd, "**/*.sln", false, true)
  end
  if #slns == 0 then
    vim.notify("[dotnet-tree] no .sln found", vim.log.levels.WARN)
    return
  end
  if #slns == 1 then
    state.dotnet_sln = slns[1]
    require("dotnet-tree").navigate(state)
    return
  end
  vim.ui.select(slns, { prompt = "Select solution:" }, function(choice)
    if not choice then
      return
    end
    state.dotnet_sln = choice
    require("dotnet-tree").navigate(state)
  end)
end

function M.toggle_node(state)
  cc.toggle_node(state)
end

function M.close_node(state)
  cc.close_node(state)
end

function M.close_all_nodes(state)
  cc.close_all_nodes(state)
end

function M.expand_all_nodes(state)
  cc.expand_all_nodes(state)
end

local function find_project_node(state)
  local node = state.tree:get_node()
  while node do
    if node.extra and node.extra.kind == "project" then
      return node
    end
    local parent_id = node:get_parent_id()
    if not parent_id then
      return nil
    end
    node = state.tree:get_node(parent_id)
  end
  return nil
end

local function run_in_terminal(cmd)
  vim.cmd("botright 15split")
  vim.cmd("terminal " .. cmd)
  vim.cmd("startinsert")
end

function M.build(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet build " .. vim.fn.shellescape(node.extra.project.path))
end

function M.run_project(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet run --project " .. vim.fn.shellescape(node.extra.project.path))
end

function M.build_solution(state)
  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no solution loaded", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet build " .. vim.fn.shellescape(state.dotnet_sln))
end

function M.test(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet test " .. vim.fn.shellescape(node.extra.project.path))
end

return M
