# dotnet-tree.nvim

A .NET solution explorer for Neovim, built as a [neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)
source. Browse your `.sln` / `.slnx` the way the solution is actually structured — solution folders,
projects, project references, packages — instead of the way the files happen to sit on disk. Then
build, run, test and watch straight from the tree.

> **Status:** early. The feature set below works day to day, but the API and mappings may still move
> before `v1.0.0`. Changes are listed in [CHANGELOG.md](CHANGELOG.md). Feedback and issues very
> welcome.

<!-- TODO(demo): replace with a GIF or asciinema cast of the tree in action.
     This is the single highest-impact thing in this README — do not publish without it. -->

## Why

`nvim-tree` and neo-tree's `filesystem` source show you directories. A .NET repository is not a
directory tree: it is a solution graph. `Directory.Packages.props` centralises versions somewhere
else, project references cross folder boundaries, and solution folders exist only inside the `.sln`.
This source renders that graph.

## Features

- **Both solution formats** — legacy `.sln` and the newer XML `.slnx`
- **Solution folders** rendered as real nodes, nested as declared
- **Projects** with their `.csproj` pinned on top, package references and project references
- **Central Package Management** — resolves versions from `Directory.Packages.props`
- **LSP diagnostics** and **git status** propagated onto tree nodes — with a language server
  configured for background analysis over the whole solution (for example roslyn.nvim's
  `dotnet_analyzer_diagnostics_scope = "fullSolution"`), markers appear on files you have not
  opened, and project rows carry the error and warning counts underneath them
- **dotnet CLI actions** on the node under the cursor: build, clean, run, test, watch, add
  package / project reference, new file from template (with namespace inferred from the folder)
- **Multiple solutions** — pick one with `s`; the choice is remembered per working directory
  in `stdpath("state")/dotnet-tree/solutions.json`
- **Auto refresh** on `DiagnosticChanged` and on writing `*.csproj`, `*.sln`, `*.slnx`,
  `Directory.Packages.props`

## Requirements

- Neovim >= 0.9
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) — this plugin is a neo-tree
  source, not a standalone tree
- The `dotnet` CLI on your `PATH` (only needed for the build/run/test/watch/add actions)

## Installation

> [!IMPORTANT]
> This is a **neo-tree source**. Installing the plugin is not enough — you must add
> `"dotnet-tree"` to neo-tree's `sources`. neo-tree resolves external sources by calling
> `require("dotnet-tree")`, so nothing else needs wiring up.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nvim-neo-tree/neo-tree.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-tree/nvim-web-devicons",
    "alessandropietrobelli/dotnet-tree.nvim",
  },
  opts = {
    sources = { "filesystem", "buffers", "git_status", "dotnet-tree" },
  },
  keys = {
    { "<leader>fd", "<cmd>Neotree dotnet-tree reveal<cr>", desc = "Dotnet solution explorer" },
  },
}
```

Then open it with `:Neotree dotnet-tree reveal`.

### Optional: make it the default source in .NET repositories

This is the setup the author uses — the .NET tree takes over automatically when the working
directory contains a solution, and a winbar lets you flip back to files:

```lua
{
  "nvim-neo-tree/neo-tree.nvim",
  opts = function(_, opts)
    local cwd = vim.fn.getcwd()
    local has_sln = #vim.fn.globpath(cwd, "*.sln", false, true) > 0
      or #vim.fn.globpath(cwd, "*.slnx", false, true) > 0
    if not has_sln then
      return
    end

    opts.sources = opts.sources or { "filesystem", "buffers", "git_status" }
    if not vim.tbl_contains(opts.sources, "dotnet-tree") then
      table.insert(opts.sources, "dotnet-tree")
    end
    opts.default_source = "dotnet-tree"

    opts.source_selector = opts.source_selector or {}
    opts.source_selector.winbar = opts.source_selector.winbar ~= false
    opts.source_selector.sources = {
      { source = "dotnet-tree", display_name = " 󰘐 .NET" },
      { source = "filesystem", display_name = "  Files" },
    }
  end,
}
```

## Mappings

Defaults inside the `dotnet-tree` window. `?` shows this list in Neovim.

| Key | Action |
|---|---|
| `<cr>` / `o` / double-click | open node |
| `<space>` | toggle node |
| `R` | refresh tree |
| `z` / `Z` | close all / expand all |
| `?` | show help |
| `s` | select solution (when the repo has more than one) |
| `e` | edit the project's `.csproj` |
| `a` | add package or project reference |
| `n` | new file from template |
| `b` / `B` | build project / build solution |
| `c` / `C` | clean project / clean solution |
| `r` | run project |
| `t` | test project |
| `w` | watch (run / test / build) |

## Configuration

Configure it as a neo-tree source — the table is merged over
`require("dotnet-tree").default_config`:

```lua
opts = {
  sources = { "filesystem", "dotnet-tree" },
  ["dotnet-tree"] = {
    window = {
      position = "left",
      width = 40,
      mappings = {
        ["<2-LeftMouse>"] = "noop", -- override or drop any default
      },
    },
  },
}
```

## Troubleshooting

Run `:checkhealth dotnet-tree` first — it verifies neo-tree is installed, that the source is
registered, and that `dotnet` is on your `PATH`.

**`Source dotnet-tree not found`** — `"dotnet-tree"` is missing from `opts.sources`. See the
callout in [Installation](#installation).

**`no .sln/.slnx found under <path>`** — the source looks for a solution under the current working
directory. Open Neovim at the repository root, or press `s` to pick one explicitly.

**Only one file in the whole tree shows a diagnostic marker** — the solution has not been restored,
so the language server cannot load the project graph and only reports on the file you have open.
Run `dotnet restore` and give the server time to finish indexing; on a solution of a few dozen
projects that took a couple of minutes here, and the count climbs in steps rather than appearing
all at once.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports should include your Neovim version, neo-tree
version and the output of `:checkhealth dotnet-tree`.

## License

[Apache-2.0](LICENSE)
