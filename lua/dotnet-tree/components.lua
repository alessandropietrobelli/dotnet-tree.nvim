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

local DEFAULT_SYMBOLS = {
  added = "✚",
  modified = "",
  deleted = "✖",
  renamed = "󰁕",
  untracked = "",
  ignored = "",
  unstaged = "󰄱",
  staged = "",
  conflict = "",
}

local function resolve_symbols(state, config)
  local cfg = state and state.config and state.config.default_component_configs
  local from_state = cfg and cfg.git_status and cfg.git_status.symbols or {}
  local from_config = config and config.symbols or {}
  return vim.tbl_extend("force", DEFAULT_SYMBOLS, from_state, from_config)
end

function M.git_status(config, node, state)
  local code = node.extra and node.extra.git_status
  if not code or code == "" then
    return { text = "" }
  end
  local rolled_up = node.extra.git_rolled_up

  local symbols = resolve_symbols(state, config)
  local staged = code:sub(1, 1)
  local unstaged = code:sub(2, 2)

  local change_sym, change_hl
  if code == "??" then
    change_sym, change_hl = symbols.untracked, "NeoTreeGitUntracked"
  elseif code == "!!" then
    change_sym, change_hl = symbols.ignored, "NeoTreeGitIgnored"
  elseif
    staged == "U"
    or unstaged == "U"
    or (staged == "A" and unstaged == "A")
    or (staged == "D" and unstaged == "D")
  then
    change_sym, change_hl = symbols.conflict, "NeoTreeGitConflict"
  elseif staged == "R" or unstaged == "R" then
    change_sym, change_hl = symbols.renamed, "NeoTreeGitRenamed"
  elseif staged == "A" or unstaged == "A" then
    change_sym, change_hl = symbols.added, "NeoTreeGitAdded"
  elseif staged == "D" or unstaged == "D" then
    change_sym, change_hl = symbols.deleted, "NeoTreeGitDeleted"
  elseif staged == "M" or unstaged == "M" or staged == "T" or unstaged == "T" then
    change_sym, change_hl = symbols.modified, "NeoTreeGitModified"
  end

  local state_sym, state_hl
  if not rolled_up and code ~= "??" and code ~= "!!" then
    if unstaged ~= " " and unstaged ~= "" then
      state_sym, state_hl = symbols.unstaged, "NeoTreeGitUnstaged"
    elseif staged ~= " " and staged ~= "" then
      state_sym, state_hl = symbols.staged, "NeoTreeGitStaged"
    end
  end

  local parts = {}
  if change_sym and change_sym ~= "" then
    table.insert(parts, { text = " " .. change_sym, highlight = change_hl or "NeoTreeGitModified" })
  end
  if state_sym and state_sym ~= "" then
    table.insert(parts, { text = " " .. state_sym, highlight = state_hl or change_hl or "NeoTreeGitModified" })
  end

  if #parts == 0 then
    return { text = "" }
  end
  if #parts == 1 then
    return parts[1]
  end
  return parts
end

local function git_name_hl(code)
  if not code or code == "" then
    return nil
  end
  if code == "??" then
    return "NeoTreeFileNameUntracked"
  elseif code == "!!" then
    return "NeoTreeFileNameIgnored"
  end
  local s, u = code:sub(1, 1), code:sub(2, 2)
  if s == "U" or u == "U" or (s == "A" and u == "A") or (s == "D" and u == "D") then
    return "NeoTreeGitConflict"
  elseif s == "R" or u == "R" then
    return "NeoTreeGitRenamed"
  elseif s == "A" or u == "A" then
    return "NeoTreeGitAdded"
  elseif s == "D" or u == "D" then
    return "NeoTreeGitDeleted"
  elseif s == "M" or u == "M" or s == "T" or u == "T" then
    return "NeoTreeGitModified"
  end
  return nil
end

local SEVERITY_HL = {
  [vim.diagnostic.severity.ERROR] = "DiagnosticError",
  [vim.diagnostic.severity.WARN] = "DiagnosticWarn",
  [vim.diagnostic.severity.INFO] = "DiagnosticInfo",
  [vim.diagnostic.severity.HINT] = "DiagnosticHint",
}

function M.diagnostics(config, node, state)
  local kind = node.extra and node.extra.kind

  if kind == "project" then
    local proj = node.extra.project
    if not proj or not proj.path then
      return { text = "" }
    end
    local dir = vim.fs.normalize(vim.fn.fnamemodify(proj.path, ":h")) .. "/"
    local errors, warnings = 0, 0
    for _, d in ipairs(vim.diagnostic.get(nil) or {}) do
      if d.bufnr then
        local bufname = vim.api.nvim_buf_get_name(d.bufnr)
        if bufname ~= "" then
          local nbuf = vim.fs.normalize(bufname)
          if nbuf:sub(1, #dir) == dir then
            if d.severity == vim.diagnostic.severity.ERROR then
              errors = errors + 1
            elseif d.severity == vim.diagnostic.severity.WARN then
              warnings = warnings + 1
            end
          end
        end
      end
    end
    if errors == 0 and warnings == 0 then
      return { text = "" }
    end
    local parts = {}
    if errors > 0 then
      table.insert(parts, { text = "  " .. errors, highlight = "DiagnosticError" })
    end
    if warnings > 0 then
      table.insert(parts, { text = "  " .. warnings, highlight = "DiagnosticWarn" })
    end
    return parts
  end

  if (kind == "file" or kind == nil) and node.path then
    local present = {}
    local target = vim.fs.normalize(node.path)
    for _, d in ipairs(vim.diagnostic.get(nil) or {}) do
      if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
        local bufname = vim.api.nvim_buf_get_name(d.bufnr)
        if bufname ~= "" then
          local nbuf = vim.fs.normalize(bufname)
          if nbuf == target or nbuf:sub(-#target) == target or target:sub(-#nbuf) == nbuf then
            present[d.severity] = true
          end
        end
      end
    end
    if not next(present) then
      return { text = "" }
    end
    local SEV_ICON = {
      [vim.diagnostic.severity.ERROR] = "",
      [vim.diagnostic.severity.WARN] = "",
      [vim.diagnostic.severity.INFO] = "",
      [vim.diagnostic.severity.HINT] = "",
    }
    local parts = {}
    for _, sev in ipairs({
      vim.diagnostic.severity.ERROR,
      vim.diagnostic.severity.WARN,
      vim.diagnostic.severity.INFO,
      vim.diagnostic.severity.HINT,
    }) do
      if present[sev] then
        table.insert(parts, { text = " " .. SEV_ICON[sev], highlight = SEVERITY_HL[sev] })
      end
    end
    return parts
  end

  return { text = "" }
end

function M.name(config, node, state)
  local kind = node.extra and node.extra.kind
  local hl = "NeoTreeFileName"
  if kind == "solution" then
    hl = "NeoTreeRootName"
  elseif kind == "project" or kind == "project_reference" then
    hl = "Function"
  elseif
    kind == "sln_folder"
    or kind == "dependencies"
    or kind == "projrefs"
    or kind == "packages"
    or kind == "frameworks"
  then
    hl = "NeoTreeDirectoryName"
  elseif kind == "package" then
    hl = "String"
  elseif kind == "framework" then
    hl = "Constant"
  elseif kind == "folder" then
    hl = "NeoTreeDirectoryName"
  end

  local git_hl = git_name_hl(node.extra and node.extra.git_status)
  if git_hl then
    hl = git_hl
  end

  return { text = node.name, highlight = hl }
end

return M
