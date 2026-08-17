# Contributing

Thanks for taking a look. Issues and pull requests are both welcome.

## Reporting a bug

Please include:

- Neovim version (`nvim --version`)
- neo-tree.nvim commit or tag
- The output of `:checkhealth dotnet-tree`
- Whether the solution is `.sln` or `.slnx`, and whether the repository uses
  Central Package Management (`Directory.Packages.props`)
- A minimal reproduction if you can manage one — a tiny solution that triggers
  the problem is worth a lot more than a description

The most common report is *"the source doesn't appear"*. That is almost always
`"dotnet-tree"` missing from neo-tree's `opts.sources`; `:checkhealth
dotnet-tree` will say so directly.

## Development setup

Point your plugin manager at a local checkout instead of the GitHub repo. With
lazy.nvim:

```lua
{ "alessandropietrobelli/dotnet-tree.nvim", dir = "~/src/dotnet-tree.nvim" }
```

Reload with `:Neotree close` then `:Neotree dotnet-tree reveal` — the source is
re-required on navigate, so most changes show up without restarting Neovim.

## Before opening a pull request

```sh
stylua lua/ tests/   # formatting is enforced in CI, over both directories
luacheck lua/
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

CI additionally loads every module against Neovim stable and nightly, runs the
test suite, and regenerates the help tags. Keep `doc/dotnet-tree.txt` in sync
when you change behaviour or mappings, and add a line to the `Unreleased`
section of [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.

## Code layout

| Path | Responsibility |
|---|---|
| `lua/dotnet-tree/init.lua` | the neo-tree source: `default_config`, `setup`, `navigate` |
| `lua/dotnet-tree/tree.lua` | builds the node list from a parsed solution |
| `lua/dotnet-tree/commands.lua` | window mappings and dotnet CLI actions |
| `lua/dotnet-tree/components.lua` | renderer components |
| `lua/dotnet-tree/git.lua` | git status per node |
| `lua/dotnet-tree/store.lua` | remembers the selected solution per cwd |
| `lua/dotnet-tree/parser/` | `sln`, `slnx`, `csproj`, `cpm`, and discovery |
| `lua/dotnet-tree/health.lua` | `:checkhealth dotnet-tree` |

Parsers are the place where most contributions will land — the `.sln` and
`.slnx` formats both have corners this plugin has not met yet. If you have a
solution file that renders wrong, attaching it (sanitised) to an issue is the
single most useful thing you can do.

## Scope

This is a *solution explorer*. Things that belong here: reading and rendering
the solution graph, and acting on nodes through the `dotnet` CLI. Things that
do not: LSP configuration, debugging (use `nvim-dap`), test result UIs (use
`neotest`).

## License

By contributing you agree that your contributions are licensed under the
[Apache-2.0](LICENSE) license that covers this project.
