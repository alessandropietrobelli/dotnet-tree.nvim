# dotnet-tree.nvim

A .NET solution explorer for Neovim, built as a [neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)
source. Browse your `.sln` / `.slnx` the way the solution is actually structured — solution folders,
projects, project references, packages — instead of the way the files happen to sit on disk. Then
build, run, test and watch straight from the tree.

> **Status:** early. The feature set below works day to day, but the API and mappings may still move
> before `v1.0.0`. Changes are listed in [CHANGELOG.md](CHANGELOG.md). Feedback and issues very
> welcome.

![dotnet-tree.nvim rendering the jellyfin solution: packages with the versions
central package management resolved for them, project references, and
diagnostics on files that were never opened](assets/demo.gif)

<sub>Recorded on a [jellyfin](https://github.com/jellyfin/jellyfin) checkout —
42 projects, central package management. The demo is a script:
[`assets/demo.tape`](assets/demo.tape).</sub>

## Why

`nvim-tree` and neo-tree's `filesystem` source show you directories. A .NET repository is not a
directory tree: it is a solution graph. `Directory.Packages.props` centralises versions somewhere
else, project references cross folder boundaries, and solution folders exist only inside the `.sln`.
This source renders that graph.

## Features

- **Both solution formats** — legacy `.sln` and the newer XML `.slnx`
- **Solution folders** rendered as real nodes, nested as declared
- **Projects** with their `.csproj` pinned on top, package references and project references
- **Central Package Management** — resolves versions from the `Directory.Packages.props`
  nearest to each project, following the import that chains a nested one to the root one;
  central versions are marked `ⓒ`, a project's `VersionOverride` is marked `override`
- **LSP diagnostics** and **git status** propagated onto tree nodes — with a language server
  configured for background analysis over the whole solution (for example roslyn.nvim's
  `dotnet_analyzer_diagnostics_scope = "fullSolution"`), markers appear on files you have not
  opened, and project rows carry the error and warning counts underneath them
- **dotnet CLI actions** on the node under the cursor: build, clean, run, test, watch, add
  package / project reference, new file from template (with namespace inferred from the folder)
- **Debug the project under the cursor** with `d`: it builds first, then starts netcoredbg
  through nvim-dap on that project's own assembly — no prompt asking which project, and no
  stale binary, because a failed build stops the launch and shows the compiler errors instead.
  The launch profile in `Properties/launchSettings.json` is read, so a web project is debugged
  in Development on the port the profile names rather than in Production on port 5000
- **Build errors in the quickfix list**, deduplicated and jumpable — including the ones no
  language server can see, such as a failed restore, which stops compilation before any
  compiler error is reported. `run`, `test` and `watch` stay in a terminal, where their
  output is interactive. Each one is labelled in its own winbar with what it runs (`run Api`,
  `watch test Api.Tests`), and stays out of a bufferline, so clicking a tab never opens a
  terminal in the editor window
- **Multiple solutions** — pick one with `s`; the choice is remembered per working directory
  in `stdpath("state")/dotnet-tree/solutions.json`
- **Follow the current file** — `:Neotree dotnet-tree reveal` puts the cursor on the file you
  are editing, expanding the project and folders above it, and `follow_current_file` does it
  on every buffer switch without leaving the editor, as the filesystem source does. Folders
  you open or close yourself are left alone
- **Auto refresh** without stalling the editor: diagnostics redraw the tree, writing a
  project, solution or `Directory.Packages.props` rebuilds it, writing a new file in a project
  adds it, and git status is read in the background, also after a commit or checkout done
  outside Neovim
- **Works with [nuget.nvim](https://github.com/alessandropietrobelli/nuget.nvim)** when it is
  installed: `a` on a project's Packages opens its window to search and install, with that
  project picked; `a` on a package opens it on that package — versions per project, updates,
  advisories. The tree reloads after nuget.nvim changes packages. Without it, `a` asks for a
  package name as before

## Requirements

- Neovim >= 0.9
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) — this plugin is a neo-tree
  source, not a standalone tree
- The `dotnet` CLI on your `PATH` (only needed for the build/run/test/watch/add actions)

Optional, and only for `d` (debug project):

- [nvim-dap](https://github.com/mfussenegger/nvim-dap)
- [netcoredbg](https://github.com/Samsung/netcoredbg) on your `PATH`, or installed with
  mason (`:MasonInstall netcoredbg`)

Without them the tree works exactly as before; `d` says what is missing, and
`:checkhealth dotnet-tree` names it.

## Installation

> [!IMPORTANT]
> This is a **neo-tree source**. Installing the plugin is not enough — you must add
> `"dotnet-tree"` to neo-tree's `sources`. neo-tree resolves external sources by calling
> `require("dotnet-tree")`, so nothing else needs wiring up.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  lazy = false, -- neo-tree lazy-loads itself; see the note below
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

`lazy = false` is what neo-tree's own README recommends, and this source needs it too: with
neo-tree deferred behind a key mapping, `dotnet-tree.nvim` is not on the `runtimepath` yet, so
`:checkhealth dotnet-tree` reports *no healthcheck found*, `:help dotnet-tree` reports `E149`, and
`:Neotree` is not a command until you have pressed the mapping once. neo-tree does its own lazy
loading internally, so this costs you nothing at startup.

`branch = "v3.x"` pins neo-tree to the major version this source is written against.

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
| `a` | add package or project reference — with [nuget.nvim](https://github.com/alessandropietrobelli/nuget.nvim) installed, packages open its window |
| `n` | new file from template |
| `b` / `B` | build project / build solution — to the quickfix list |
| `c` / `C` | clean project / clean solution — to the quickfix list |
| `r` | run project — in a terminal split |
| `d` | debug project — builds first, then netcoredbg via nvim-dap |
| `t` | test project — in a terminal split |
| `w` | watch (run / test / build) — in a terminal split |

`r`, `t` and `w` start in the project's folder, not in Neovim's working directory, so an
ASP.NET Core app finds its `appsettings.json` wherever Neovim was opened. An Azure Functions
app (its `.csproj` sets `<AzureFunctionsVersion>`, references `Microsoft.NET.Sdk.Functions` or
`Microsoft.Azure.Functions.Worker.Sdk`, or its folder has a `host.json`) needs
[Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
(`func`) on `PATH`: `r` runs `dotnet run` on `Microsoft.Azure.Functions.Worker.Sdk` 2.x, which
starts the host itself, and `func start` on an in-process app or Worker SDK 1.x, which `w` →
run cannot start and refuses. When `local.settings.json` sets
`"AzureWebJobsStorage": "UseDevelopmentStorage=true"`, `r` and `w` → run check that Azurite is
listening on `127.0.0.1:10000` and warn if it is not; the app starts anyway.

`d` resolves the project's own output — `OutputType` decides whether there is anything to
launch, and when the project does not declare one its SDK does (`Microsoft.NET.Sdk.Web` and
`Microsoft.NET.Sdk.Worker` build applications, which is why an ASP.NET Core project has no
`<OutputType>` in it) — builds it, and then asks MSBuild where the build put the assembly
(`dotnet msbuild -getProperty:TargetPath`) rather than composing a path. `bin/Debug/<tfm>/` is
only the default layout: `<ArtifactsPath>` puts every project under one `artifacts/` tree and
leaves no `bin/` at all, and `<OutputPath>`, `<BaseOutputPath>` and
`<AppendTargetFrameworkToOutputPath>` each move it somewhere else again. MSBuild is the only
thing that knows. `-getProperty` needs the .NET 8 SDK or newer; on an older one the default
layout is composed as before. A library is refused with the reason rather than launched;
a multi-targeted project asks which framework; a failed build leaves the quickfix list on
screen and never starts the debugger. A Blazor WebAssembly app is refused too: MSBuild calls
it an `Exe`, but it runs in the browser and netcoredbg cannot start it. A project that declares
no `TargetFramework` of its own inherits it from the nearest `Directory.Build.props`, the way
MSBuild does — and when that file only chains to the one above it with
`$([MSBuild]::GetPathOfFileAbove(...))`, as a `src/Directory.Build.props` usually does, that
chain is followed. If the framework is still
unknown — a framework written as `$(SomeProperty)`, which only MSBuild can expand — MSBuild is
asked instead, and a single-targeted project needs no framework at all for that: it names its
one output directly.

A test project is a runnable assembly too — xunit v3 test projects declare
`<OutputType>Exe</OutputType>` — so `d` debugs one rather than refusing it, and says that
is what it is before launching: what you get is the whole test suite under the debugger.
A project counts as a test project when it declares `<IsTestProject>` or references
`Microsoft.NET.Test.Sdk`. To debug a single test rather than the whole assembly, use
[neotest-dotnet](https://github.com/Issafalcon/neotest-dotnet).

A failed build fills the quickfix list and opens it; a successful one is a single
message and no window. MSBuild prints every diagnostic twice, and once per target
framework on a multi-targeted project — those copies are collapsed into one entry per
source position. Lists made by other plugins are not overwritten: a build replaces the
list it made itself, and otherwise pushes a new one.

## Configuration

Configure it as a neo-tree source — the table is merged over
`require("dotnet-tree").default_config`:

```lua
opts = {
  sources = { "filesystem", "dotnet-tree" },
  ["dotnet-tree"] = {
    -- reveal the current file on every buffer switch, as the filesystem source does
    follow_current_file = {
      enabled = false,
      leave_dirs_open = false, -- close the folders a previous reveal or follow opened
    },
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

**`Invalid argument: dotnet-tree`** (from `neo-tree/command/parser.lua`) — `"dotnet-tree"` is
missing from `opts.sources`. See the callout in [Installation](#installation).

**`No healthcheck found for "dotnet-tree"`, `E149: No help for dotnet-tree`, or `:Neotree` is not
an editor command** — neo-tree is being lazy-loaded, so neither plugin is on the `runtimepath`
yet. Set `lazy = false` on the neo-tree spec as shown in [Installation](#installation).

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

## See also

Two more plugins for .NET in Neovim, by the same author:

- [dotnet-counters.nvim](https://github.com/alessandropietrobelli/dotnet-counters.nvim) — live .NET runtime metrics (CPU, memory, GC, exceptions, HTTP latency) in a side panel next to the debugger
- [nuget.nvim](https://github.com/alessandropietrobelli/nuget.nvim) — a NuGet package manager: browse, update, consolidate and audit the packages of the whole solution in one window

## Trademarks

dotnet-tree.nvim is an independent project. It is not affiliated with, endorsed or sponsored by
Microsoft or the .NET Foundation. .NET, Visual Studio and NuGet are trademarks of their respective
owners, used here only to say what the plugin works with.

## License

[Apache-2.0](LICENSE)
