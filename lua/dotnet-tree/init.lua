local M = {
  name = "dotnet-tree",
  display_name = " 󰘐 .NET ",
}

M.default_config = {
  window = {
    position = "left",
    width = 40,
    mappings = {
      ["<cr>"] = "open",
      ["<2-LeftMouse>"] = "open",
      ["o"] = "open",
      ["R"] = "refresh",
      ["s"] = "select_solution",
      ["z"] = "close_all_nodes",
      ["Z"] = "expand_all_nodes",
      ["<space>"] = "toggle_node",
      ["b"] = "build",
      ["B"] = "build_solution",
      ["r"] = "run_project",
      ["t"] = "test",
    },
  },
  renderers = {
    directory = {
      { "indent", with_expanders = false },
      { "icon" },
      { "name" },
    },
    file = {
      { "indent", with_expanders = false },
      { "icon" },
      { "name" },
    },
  },
}

local function find_default_sln(cwd)
  local results = vim.fn.globpath(cwd, "*.sln", false, true)
  if #results == 0 then
    results = vim.fn.globpath(cwd, "**/*.sln", false, true)
  end
  return results[1]
end

function M.setup(_, _)
  local group = vim.api.nvim_create_augroup("DotnetTreeAutoRefresh", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.csproj", "*.fsproj", "*.vbproj", "*.sln" },
    callback = function(args)
      local path = vim.fs.normalize(args.file)
      if path:match("%.sln$") then
        require("dotnet-tree.parser.sln").invalidate(path)
        require("dotnet-tree.parser.csproj").invalidate()
      else
        require("dotnet-tree.parser.csproj").invalidate(path)
      end
      pcall(function()
        require("neo-tree.sources.manager").refresh("dotnet-tree")
      end)
    end,
  })
end

function M.navigate(state, path, path_to_reveal, callback, async)
  local renderer = require("neo-tree.ui.renderer")
  state.path = state.path or vim.fn.getcwd()

  if not state.dotnet_sln then
    state.dotnet_sln = find_default_sln(state.path)
  end

  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no .sln found under " .. state.path, vim.log.levels.WARN)
    renderer.show_nodes({}, state)
    if callback then
      callback()
    end
    return
  end

  local tree = require("dotnet-tree.tree")
  local items, err = tree.build(state.dotnet_sln)
  if not items then
    vim.notify("[dotnet-tree] " .. tostring(err), vim.log.levels.ERROR)
    renderer.show_nodes({}, state)
    if callback then
      callback()
    end
    return
  end

  renderer.show_nodes(items, state)

  if not path_to_reveal then
    local bufname = vim.api.nvim_buf_get_name(0)
    if bufname ~= "" and vim.fn.filereadable(bufname) == 1 then
      path_to_reveal = vim.fs.normalize(bufname)
    end
  end
  if path_to_reveal then
    pcall(renderer.focus_node, state, path_to_reveal)
  end

  if callback then
    callback()
  end
end

return M
