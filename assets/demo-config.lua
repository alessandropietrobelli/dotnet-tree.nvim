-- The Neovim configuration used to record assets/demo.gif. Copy it to
-- ~/.config/dotnet-tree-demo/init.lua and run:
--
--   NVIM_APPNAME=dotnet-tree-demo nvim
--
-- NVIM_APPNAME moves config, data and state into their own dotnet-tree-demo
-- directories, so this touches nothing in ~/.config/nvim.
--
-- It is deliberately not a minimal reproduction of the README install snippet:
-- it is dressed for the camera (colorscheme, no line numbers, a wider tree) and
-- it adds roslyn, without which the diagnostics section of the demo has nothing
-- to show.
--
-- Two paths to point at your machine:

-- where this repository is checked out
local PLUGIN_DIR = vim.env.DOTNET_TREE_DIR or vim.fn.expand("~/src/dotnet-tree.nvim")
-- a roslyn language server binary; this is where mason installs one
local ROSLYN_CMD = vim.env.ROSLYN_CMD or vim.fn.expand("~/.local/share/nvim/mason/bin/roslyn")

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

vim.opt.termguicolors = true
vim.opt.number = false
vim.opt.signcolumn = "yes"
-- the demo jumps with / to reach a line; the highlight afterwards is noise
vim.opt.hlsearch = false
-- VHS emits a frame when the screen changes, so a long Sleep over a still
-- screen shortens in the recording -- the 24 s of demo.gif come out of a tape
-- asking for about 40 s. A blinking cursor gives the still frames something to
-- differ by. It does not fully close the gap: tune the Sleeps by looking at the
-- output, not by adding up the tape.
vim.opt.guicursor = "n-v-c:block-blinkwait200-blinkon450-blinkoff450,i:ver25-blinkwait200-blinkon450-blinkoff450"
vim.opt.laststatus = 0
vim.opt.cmdheight = 1
vim.opt.showmode = false
vim.opt.fillchars = { eob = " " }

require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = { style = "night" },
    config = function(_, opts)
      require("tokyonight").setup(opts)
      vim.cmd.colorscheme("tokyonight")
    end,
  },
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-tree/nvim-web-devicons",
      { "dotnet-tree.nvim", dir = PLUGIN_DIR },
    },
    opts = {
      sources = { "filesystem", "buffers", "git_status", "dotnet-tree" },
      default_source = "dotnet-tree",
      source_selector = {
        winbar = true,
        sources = {
          { source = "dotnet-tree", display_name = " 󰘐 .NET" },
          { source = "filesystem", display_name = "  Files" },
        },
      },
      ["dotnet-tree"] = {
        window = { width = 58 },
      },
    },
    keys = {
      { "<leader>fd", "<cmd>Neotree dotnet-tree reveal<cr>", desc = "Dotnet solution explorer" },
    },
  },
  {
    "seblyng/roslyn.nvim",
    ft = { "cs", "razor", "cshtml" },
    opts = { broad_search = true },
    init = function()
      vim.lsp.config("roslyn", {
        cmd = {
          ROSLYN_CMD,
          "--logLevel=Information",
          -- vim.lsp.get_log_path() is deprecated and prints a warning on
          -- startup, which would land in the recording.
          "--extensionLogDirectory=" .. vim.fn.stdpath("log"),
          "--stdio",
        },
        -- Without fullSolution the server only reports on open buffers, and the
        -- whole point of the diagnostics beat is markers on files nobody opened.
        settings = {
          ["csharp|background_analysis"] = {
            dotnet_analyzer_diagnostics_scope = "fullSolution",
            dotnet_compiler_diagnostics_scope = "fullSolution",
          },
        },
      })
    end,
  },
}, {
  install = { colorscheme = { "tokyonight" } },
  change_detection = { notify = false },
  ui = { backdrop = 100 },
})
