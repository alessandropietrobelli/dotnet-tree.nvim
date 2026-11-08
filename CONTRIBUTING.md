# Contributing

Thanks for taking a look. Issues and pull requests are both welcome.

## Reporting a bug

Please include:

- Neovim version (`nvim --version`)
- neo-tree.nvim commit or tag
- The output of `:checkhealth dotnet-tree`
- Whether the solution is `.sln` or `.slnx`, and whether the repository uses
  Central Package Management (`Directory.Packages.props`)
- The exact XML that renders wrong — the smallest fragment from the `.sln`,
  `.slnx`, `.csproj` or `Directory.Packages.props`, pasted verbatim and
  sanitised. The `.csproj` and `.props` readers now read an element tree, and
  `TargetFramework`/`TargetFrameworks` are also read from the nearest
  `Directory.Build.props` and from the file it chains to with
  `GetPathOfFileAbove` (package versions likewise from the nearest
  `Directory.Packages.props` and the file it chains to), but MSBuild is still
  not evaluated — a `$(Property)`
  comes back as written, a `Condition` is not decided, no other `Import` is
  followed, and no other property is inherited. The one property that *is*
  evaluated is the output path: `d` asks
  `dotnet msbuild -getProperty:TargetPath` where the build put the assembly,
  so a report about `d` launching the wrong file should say what that command
  prints for the project. The `.sln` reader is still line-based, so
  a retyped or reformatted fragment usually hides the bug

The [bug report form](.github/ISSUE_TEMPLATE/bug_report.yml) asks for all of
this. Usage questions belong in
[Discussions](https://github.com/alessandropietrobelli/dotnet-tree.nvim/discussions)
rather than in an issue.

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
stylua lua/ tests/ scripts/   # formatting is enforced in CI, over all three
luacheck lua/ scripts/
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
nvim -l scripts/check-docs-consistency.lua
```

CI additionally loads every module against Neovim stable and nightly, runs the
test suite, and regenerates the help tags. Keep `doc/dotnet-tree.txt` in sync
when you change behaviour or mappings, and add a line to the `Unreleased`
section of [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.

The install instructions live in two places — `README.md` and
`doc/dotnet-tree.txt` — and `check-docs-consistency.lua` fails if they disagree.
If it stops you, edit whichever file it names rather than relaxing the check.

## Commit messages

Pull requests are squash-merged, so the pull request title becomes the commit
title on `main`. Write it the way the history already reads:

- An imperative sentence, capitalised, with no trailing period:
  *Add…*, *Fix…*, *Read…*, *Say…*.
- Say what changes for someone using the plugin, not which file you touched:
  *Debug the project under the cursor with `d`* rather than *Update debug.lua*.
- End with the issue it closes and then the pull request, in parentheses:
  `(#41) (#42)`. A pull request with no issue gets just its own number.
- A release is its own commit, titled `Release X.Y.Z` and nothing else.

The body, when there is one, explains why the change is needed; what changed is
in the diff. Close the issue in the last line, as `Closes #41`.

## Code layout

| Path | Responsibility |
|---|---|
| `lua/dotnet-tree/init.lua` | the neo-tree source: `default_config`, `setup`, `navigate` |
| `lua/dotnet-tree/tree.lua` | builds the node list from a parsed solution |
| `lua/dotnet-tree/commands.lua` | window mappings and dotnet CLI actions |
| `lua/dotnet-tree/debug.lua` | `d`: build, then netcoredbg through nvim-dap |
| `lua/dotnet-tree/build.lua` | `dotnet build` / `clean` into the quickfix list |
| `lua/dotnet-tree/components.lua` | renderer components |
| `lua/dotnet-tree/git.lua` | git status per node |
| `lua/dotnet-tree/store.lua` | remembers the selected solution per cwd |
| `lua/dotnet-tree/parser/` | `sln`, `slnx`, `csproj`, `cpm`, `props` (the `Directory.Build.props` above a project), `launch_settings` (the launch profile `d` starts with), the shared `xml` reader, and discovery |
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
