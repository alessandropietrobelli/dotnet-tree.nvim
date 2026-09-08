# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version stays below `1.0.0`, breaking changes to configuration and
mappings may land in a minor release; they will always be listed here.

## [Unreleased]

### Changed

- `b`, `B`, `c` and `C` send their diagnostics to the quickfix list instead of
  running in a `:terminal` split, so a failed build is a list you can jump
  through rather than a buffer you have to read. `r`, `t` and `w` still open a
  terminal, where their output is interactive. The quickfix window opens only
  when the command failed; a successful build is a single message.
- The XML reading that `parser/slnx.lua` already did — quote-aware tag
  boundaries, attribute parsing, entity unescaping — now lives in
  `parser/xml.lua` and is shared with the `.csproj` and
  `Directory.Packages.props` readers. No new parser was written: the `.slnx`
  reader has handled this construct correctly since the first release. It now
  also carries element text, which is what lets the package readers see a
  `<Version>` child. MSBuild is still not evaluated: `Version="$(SerilogVersion)"`
  comes back verbatim, as it always has.

### Added

- The `.csproj` reader returns `is_test_project`, and `d` says so before it
  debugs one. `OutputType` cannot answer that question: an xunit v3 test
  project declares `Exe`, because v3 runs each test assembly as its own
  process — all 16 test projects in the jellyfin checkout this was measured
  against do — so a launcher keyed on `OutputType` alone offers every test
  project in a solution as if it were an application. The signals are an
  explicit `<IsTestProject>` and a `PackageReference` to
  `Microsoft.NET.Test.Sdk`, with the property winning over the package as it
  does in MSBuild. Debugging a test project is not refused, because running a
  suite under the debugger is a real thing to want; it is named, in the message
  and in the dap session.
  ([#24](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/24))

- `d` on a project builds it and then starts netcoredbg on what it built,
  through nvim-dap. The debugger is the usual reason to leave Neovim for an
  IDE, and the gesture is the one the tree is built around: cursor on a
  project, one key, no prompt asking which project. The launch is refused with
  the reason rather than attempted when the project is a library, when
  `OutputType` or `AssemblyName` is an MSBuild property this parser cannot
  evaluate, or when the build fails — in which case the quickfix list with the
  compiler errors is what stays on screen. A multi-targeted project asks which
  framework; a project that declares none is resolved from what the build put
  under `bin/Debug/`. nvim-dap and netcoredbg are both optional: without them
  `d` says what is missing and `:checkhealth dotnet-tree` names it.
  ([#18](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/18))

- `lua/dotnet-tree/build.lua`, with an errorformat that covers the diagnostics
  MSBuild reports without a line and column. Neovim's bundled
  `compiler/dotnet.vim` carries only `%E%f(%l\,%c): %trror %m`, which yields
  zero quickfix entries for a restore failure such as `NU1101` — and a failed
  restore masks compilation, so those errors are the only ones the user gets.
  Duplicate entries are collapsed: MSBuild prints each diagnostic inline and
  again under `Build FAILED.`, and once per target framework.

- The `.csproj` reader now returns `output_type` and `assembly_name`, the two
  properties an action needs before it can point at a project's build output:
  without the first, a launcher targets a library that has no entry point and
  the failure arrives as an opaque runtime error; without the second, the guess
  that the output is named after the project file is silently wrong for every
  project that overrides it. Both are `nil` when the project does not say, and
  the defaults — output type `Library`, assembly name = the project file's
  basename — are left to the caller. A value declared only under a `Condition`
  reads as `nil` rather than being guessed at, and a value written as
  `$(Property)` comes back verbatim: reading XML is not evaluating MSBuild.
  ([#16](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/16))

### Fixed

- `d` built the right project and then looked for its assembly in the wrong
  place whenever the repository moves its output — `<ArtifactsPath>`,
  `<UseArtifactsOutput>`, `<OutputPath>`, `<BaseOutputPath>` or
  `<AppendTargetFrameworkToOutputPath>`. `bin/<Configuration>/<tfm>/` is the
  default layout, not the only one, so the path is now asked of MSBuild
  (`-getProperty:TargetPath`) instead of composed, and the composed path stays
  as the fallback for an SDK older than 8, which does not know the switch —
  there only the default layout is found, since a guess is all that is left.
  That costs nothing for the artifacts layout, which is itself .NET 8 and
  later, and it does mean `<OutputPath>` and `<BaseOutputPath>` stay wrong on
  an SDK that old. The
  query stays a second process on purpose: `dotnet build -getProperty:...`
  prints a path and exits 0 even when compilation failed, which would turn a
  broken build into a debug session on a stale assembly.
- `d` refused an ASP.NET Core project as a library. `OutputType` has no single
  default in MSBuild: the SDK sets it, and `Microsoft.NET.Sdk.Web` and
  `Microsoft.NET.Sdk.Worker` set `Exe`, which is why a web project never writes
  `<OutputType>` and is still an application. The parser now reports the SDK a
  project imports, and the default follows it. A Blazor WebAssembly app is an
  `Exe` by that rule and is refused for its own reason: it runs in the browser,
  where netcoredbg cannot start it.

- A package that declares its version as a `<Version>` child element instead of
  an attribute now keeps that version in `.csproj`, and keeps it in
  `Directory.Packages.props` even when a self-closing entry is declared before
  it. Both readers take the two forms from one element tree, so neither the
  ordering bug in `csproj.lua` — which made the branch written for this form
  unreachable — nor the pattern that ran from the first `<PackageVersion` in a
  file to the first `</PackageVersion>` survives.
  ([#9](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/9))
- `TargetFramework` is read in two shapes it used to miss, which together
  accounted for 15 of the 42 projects in a jellyfin checkout rendering with no
  framework at all. A project that declares none of its own now inherits it
  from the nearest `Directory.Build.props` — the same upward walk, and the same
  stopping rule, already used for `Directory.Packages.props` — and an element
  carrying a `Condition`, such as the `<TargetFramework Condition="'$(TargetFramework)' == ''">`
  default guard, is read from the element tree instead of being missed by a
  pattern that required the bare open tag. MSBuild is still not evaluated: a
  framework written as `$(DefaultTfm)` reads as unknown rather than as a guess,
  an `Import` inside a props file is not followed, and no property other than
  the two framework ones is inherited. A conditional branch is a candidate only
  when nothing unconditional names a framework, so a project that answers
  plainly is never widened by a branch we cannot decide.
  ([#23](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/23))
- A literal `>` inside an attribute value no longer truncates a tag in
  `.csproj` and `Directory.Packages.props`. That `>` is valid XML — XML 1.0
  §2.4 forbids `<` and `&` in an attribute value, not `>` — and MSBuild builds
  such a project without a warning, so a project reference or a package whose
  `Include` sat behind an MSBuild `Condition` disappeared from the tree with no
  error at all. Both attribute orders now read the same.
  ([#10](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/10))

## [0.1.2] - 2026-08-18

Documentation only. No plugin code changed between `v0.1.1` and `v0.1.2`.

### Fixed

- `0.1.1` corrected the install snippet and the troubleshooting entry in the
  README but left `doc/dotnet-tree.txt` behind, so the manual shipped inside
  the tag still carried both defects: an install snippet without
  `lazy = false`, and an error string neo-tree does not raise. Someone with a
  working install who opened `:help dotnet-tree-installation` to set up a
  second machine would have copied the broken recipe back out. The two
  documents now agree.

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
  an attribute loses that version in `.csproj`, but **not** in
  `Directory.Packages.props`. `csproj.lua` has a branch written for exactly this
  form, and it is unreachable: the single-line loop matches the opening tag,
  records the package with an empty version and marks it as seen
  (`csproj.lua:57-64`), so the child-element loop skips it (`csproj.lua:66-72`).
  `cpm.lua` is unaffected because its first loop requires both `Include` and
  `Version` and therefore records nothing for this form (`cpm.lua:35-41`),
  leaving its own child-element branch reachable (`cpm.lua:42-49`). Measured:
  `csproj.lua` returns an empty version, `cpm.lua` returns the declared one.
  Recorded as pending tests. Tracked in
  [#9](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/9),
  and fixed after `0.1.2` — see Unreleased.
- A literal `>` inside an attribute value is **valid** XML — XML 1.0 §2.4
  forbids `<` and `&` in attribute values, not `>` — and MSBuild builds such a
  project without a warning. The tag scanners in `csproj.lua` and `cpm.lua` read
  up to the first `>` regardless of quoting, so they truncate the tag and
  degrade asymmetrically: when the `Include` precedes the offending attribute the
  reference survives, when it follows the reference is dropped with no error.
  This is silent data loss on a file the toolchain accepts, not graceful
  degradation on malformed input. `parser/slnx.lua` already handles the same
  construct correctly (`find_tag_end`, `slnx.lua:86-103`). The rest of the file
  still scans correctly. Asserted in the tests as current behaviour. Tracked in
  [#10](https://github.com/alessandropietrobelli/dotnet-tree.nvim/issues/10),
  and fixed after `0.1.2` — see Unreleased.

[Unreleased]: https://github.com/alessandropietrobelli/dotnet-tree.nvim/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/alessandropietrobelli/dotnet-tree.nvim/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/alessandropietrobelli/dotnet-tree.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alessandropietrobelli/dotnet-tree.nvim/releases/tag/v0.1.0
