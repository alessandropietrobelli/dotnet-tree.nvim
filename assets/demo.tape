# The README demo, as a script. Regenerate it with:
#
#   brew install vhs                  # or see github.com/charmbracelet/vhs
#   export DEMO_REPO=~/src/jellyfin   # any public .NET solution; see below
#   vhs assets/demo.tape
#
# Recorded against a jellyfin checkout: public, 42 projects, central package
# management, and a solution graph that does not match the directory layout --
# which is the whole point of the tree. It has to be restored *and built*
# beforehand:
#
#   git clone --depth 1 https://github.com/jellyfin/jellyfin "$DEMO_REPO"
#   cd "$DEMO_REPO" && dotnet restore && dotnet build
#
# Without the build, roslyn reports a few thousand CS0246 errors for types it
# cannot resolve yet, and the tree honestly renders every one of them.
#
# assets/demo-config.lua is the Neovim configuration used here: neo-tree with
# this source, plus roslyn so the diagnostics section has something to show.
# Copy it to ~/.config/dotnet-tree-demo/init.lua.
#
# Everything between Hide and Show runs but is not filmed. That is where roslyn
# indexes the solution, which takes minutes of nothing worth watching.

Output "assets/demo.gif"
Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1500
Set Height 860
Set Theme "TokyoNight"
Set Padding 12

Hide
Type `cd "$DEMO_REPO" && clear`
Enter
Type "NVIM_APPNAME=dotnet-tree-demo nvim MediaBrowser.Common/Net/NetworkUtils.cs"
Enter
Sleep 20s
Sleep 60s
Sleep 60s
Sleep 30s
Show

# --- 1. the solution, as the solution declares it --------------------------
Sleep 1500ms
Type " fd"
Sleep 3s

# --- 2. packages, carrying versions ----------------------------------------
Type@140ms "jjjjjjjjj"
Sleep 500ms
Space
Sleep 1500ms
Type "j"
Space
Sleep 1200ms
Type@160ms "jjj"
Space
Sleep 3s

# --- 3. ...versions the csproj never declares ------------------------------
# `,` lists the .NET actions; `e` opens the project file
Type ","
Sleep 2500ms
Type "e"
Sleep 2s
Type "/PackageReference"
Enter
Type "zz"
Sleep 3500ms
Ctrl+w
Type "h"
Sleep 800ms

# --- 4. project references, crossing folder boundaries ---------------------
Type "gg"
Type "z"
Sleep 1200ms
Type@140ms "jjjjjjjjj"
Space
Sleep 1000ms
Type "j"
Space
Sleep 1000ms
Type@160ms "jj"
Space
Sleep 3s

# --- 5. diagnostics on files nobody opened ---------------------------------
Type "gg"
Type "z"
Sleep 1000ms
Type@140ms "jjjjjjjjjjj"
Sleep 500ms
Space
Sleep 3s
Type@140ms "jjjjjjjjjjj"
Sleep 800ms
Enter
Sleep 3500ms
Ctrl+w
Type "h"
Sleep 800ms

# --- 6. files, on neo-tree's own keys --------------------------------------
Type "a"
Sleep 1200ms
Type@90ms "appsettings.Local.json"
Sleep 700ms
Enter
Sleep 3s
Type "r"
Sleep 1s
Ctrl+u
Type@90ms "appsettings.Demo.json"
Sleep 700ms
Enter
Sleep 3s
Type "d"
Sleep 1500ms
Type "y"
Sleep 400ms
Enter
Sleep 3s

# --- 7. the mappings -------------------------------------------------------
Type "?"
Sleep 3s
Escape
Sleep 2s
