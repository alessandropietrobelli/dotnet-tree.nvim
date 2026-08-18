# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version stays below `1.0.0`, breaking changes to configuration and
mappings may land in a minor release; they will always be listed here.

## [Unreleased]

## [0.1.1] - 2026-08-18

Documentation only. No plugin code changed between `v0.1.0` and `v0.1.1`.

### Fixed

- The lazy.nvim install snippet in the README gave neo-tree only a `keys`
  handler, so on a cold install neither plugin was on the `runtimepath` until
  the mapping was pressed: `:checkhealth dotnet-tree` reported no healthcheck
  found, `:help dotnet-tree` reported `E149`, and `:Neotree` was not yet a
  command — exactly the two steps the README tells you to run first. The
  snippet now sets `lazy = false`, as neo-tree's own README recommends, and
  pins `branch = "v3.x"`.
- The troubleshooting entry quoted an error neo-tree does not raise. Omitting
  `"dotnet-tree"` from `opts.sources` produces
  `neo-tree/command/parser.lua:199: Invalid argument: dotnet-tree`, which is
  what someone searching the error text will have in their clipboard.

## [0.1.0] - 2026-08-18

First public release. Extracted, with its history, from the author's Neovim
configuration, where it had been in daily use on .NET solutions of up to ~200
projects.

### Added

- A neo-tree source, `dotnet-tree`, that renders a solution as the solution
  declares it — solution folders, projects, project references and package
  references — rather than as the files sit on disk.
- Both solution formats: legacy `.sln` and the newer XML `.slnx`. Discovery
  walks the working directory and prefers `.slnx` when a directory holds both.
- Central Package Management: package versions are resolved from the nearest
  `Directory.Packages.props`, found by walking up from the project.
- LSP diagnostics and git status propagated onto tree nodes. With a language
  server doing background analysis over the whole solution, markers appear on
  files that have never been opened, and project rows carry the error and
  warning counts underneath them.
- `dotnet` CLI actions on the node under the cursor: build, clean, run, test,
  watch, add package reference, add project reference, and new file from a
  template with the namespace inferred from the folder.
- Multiple solutions in one repository: pick one with `s`. The choice is
  remembered per working directory in
  `stdpath("state")/dotnet-tree/solutions.json`.
- Auto refresh on `DiagnosticChanged` and on writing `*.csproj`, `*.sln`,
  `*.slnx` or `Directory.Packages.props`.
- `:checkhealth dotnet-tree` — verifies that neo-tree is installed, that the
  source is registered in `opts.sources`, and that `dotnet` is on the `PATH`.
- `:help dotnet-tree` (`doc/dotnet-tree.txt`), with tags regenerated in CI.
- A plenary test suite over the parsers, with fixtures covering the path styles
  and tag shapes real projects contain.
- CI on Neovim stable and nightly: `stylua --check`, `luacheck`, a load check of
  every module, the test suite, and doc tag generation.

### Fixed

- Project references written with forward slashes were silently dropped. The tag
  patterns captured their attribute blob with a negated class that stopped at
  the first slash, so any `Include` holding a POSIX path never matched and the
  reference vanished with no error, leaving `Dependencies > Projects` empty or
  truncated. Forward slashes are what `dotnet add reference` writes on macOS and
  Linux, so this affected most cross-platform repositories. Measured against a
  Jellyfin checkout (42 `.csproj`, 93 declared references): 63 found before, all
  93 after. ([#1](https://github.com/alessandropietrobelli/dotnet-tree.nvim/pull/1))
- References and packages inside XML comments were reported as real
  dependencies. `parser/slnx.lua` stripped comments before scanning;
  `csproj.lua` and `cpm.lua` did not, so the tree could show a package that is
  not there and, under Central Package Management, quote a version that is not
  in force. ([#1](https://github.com/alessandropietrobelli/dotnet-tree.nvim/pull/1))
- Diagnostics were recomputed once per rendered line. The cost of a redraw was
  the product of visible lines and active diagnostics, so on a 50-project
  solution with 300 diagnostics an expand-all cost about 7 s, repeated on every
  `DiagnosticChanged`. Diagnostics are now indexed once per change, keyed by
  path and invalidated by `DiagnosticChanged`. Measured on a deterministic
  50-project / 3000-file corpus: expand-all with 300 diagnostics 7076 ms ->
  910 ms; 600 visible lines with 1000 diagnostics 2828 ms -> 4 ms. The
  component's return values are unchanged, verified by a 414-assertion
  before/after snapshot.
  ([#2](https://github.com/alessandropietrobelli/dotnet-tree.nvim/pull/2))

### Known limitations

- A package that declares its version as a `<Version>` child element instead of
  an attribute loses that version, in both `.csproj` and
  `Directory.Packages.props`. Recorded as pending tests.
- An unescaped `>` inside an attribute value is not valid XML, and the scanner
  degrades asymmetrically on it: when the `Include` precedes the offending
  attribute the reference survives, when it follows the reference is dropped.
  The rest of the file still scans correctly. Asserted in the tests as a
  limitation rather than fixed.

[Unreleased]: https://github.com/alessandropietrobelli/dotnet-tree.nvim/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alessandropietrobelli/dotnet-tree.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alessandropietrobelli/dotnet-tree.nvim/releases/tag/v0.1.0
