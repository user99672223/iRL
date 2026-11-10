# Rocket League main-menu subset for CI

CI boots Rocket League to the main menu on an ARM64 Linux runner. Its game files come from the
**private** repo `user99672223/irl-assets`, read through a read-only deploy key (secret `IRL_ASSETS_KEY`).
Game files never go into this public repo, its artifacts or its logs.

**CI launch line, verified on the laptop:** CI can't get a fresh Epic exchange code, so it passes
Legendary's argument set with a dummy code:
`RocketLeague.exe -AUTH_LOGIN=unused -AUTH_PASSWORD=00000000000000000000000000000000 -AUTH_TYPE=exchangecode -epicapp=Sugar -epicenv=Prod -EpicPortal -epiclocale=en -epicsandboxid=9773aa1aa54f4f7b80e44bef04986cea`
The game boots, Epic login fails (`EOS_Auth_ExchangeCodeNotFound`), and it stays on the main menu
offline (`Game class is 'GameInfo_GFxMenu_TA'`, `Startup_Total` ≈ 121–132 s on the laptop). With **no**
Epic arguments at all, the game boots but then calls `LaunchURL` (hand-off to the Epic launcher) and exits.

**Files (menu-v2):** `menu-files.txt` lists 220 files (21.91 GiB). That's the union of Wine's own file channel (`WINEDEBUG=+file`: every path the game tried to open, which caught `Core.upk` and 3 more that the strace/openat list missed, because Wine opens names relative to directory handles), the old strace list, and a guard of every small .ini/.bin/.cfg/.txt/.json under TAGame/ and Engine/. The startup-package scan of the .ini files found no `Package=` entries (RL keeps those lists elsewhere), so the Wine trace is what covers packages. Almost all
of that is the seven `Textures*.tfc` caches, of which the menu reads only 61 MiB. The package stores
them as sparse files (real size, read ranges only, 1 MiB-aligned), plus every other menu file and all
of `Binaries/Win64` (281 files). It's 538 MiB compressed in 6 chunks of 95 MB, and restores to 22 GB apparent, 686 MB on disk. Texture read ranges are the union of two traced runs, which were identical.

**CI fetch:**
```
mkdir -p ~/.ssh && echo "$IRL_ASSETS_KEY" > ~/.ssh/irl_assets && chmod 600 ~/.ssh/irl_assets
GIT_SSH_COMMAND='ssh -i ~/.ssh/irl_assets -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
  git clone --depth 1 git@github.com:user99672223/irl-assets.git irl-assets
bash irl-assets/restore.sh irl-assets "$HOME/rocketleague"     # verifies chunk and file hashes
```
The plain executables and DLLs are also in `irl-assets/game/Binaries/Win64/` (no unpacking needed for AOT tests).

**Rebuild after a game patch:** `WINE_FILE_TRACE=1 TRACE_READS=1 trace-menu.sh dummy 300` (Wine file log plus texture read
ranges), then `wine_file_paths.py --old <previous menu-files.txt>`, then `package.py --reads <straces...>`, then commit to irl-assets and tag `menu-vN`.

**Caveat:** the read ranges come from one laptop run. If CI's run reads a texture range the laptop
didn't, it gets zeros there (a broken texture, or a decompression error in the log). Re-trace and repack.
