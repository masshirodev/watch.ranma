# AGENTS.md

watch.ranma is a ranma plugin in Lua: `plugin/watch.lua` is all of it, and
its header comment is the reference that `README.md` repeats. ranma's API is
https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md (`ranma --dump-types` prints it as LuaLS annotations).

- Push to `main`.
- A change to what it does changes the header comment and `README.md` in the
  same commit, and an option goes in the README's table.
- Keep to the API of the latest ranma release, which CI loads it into.
- The status comes from the `[watch.ranma] start` / `exit N` lines the
  watcher prints; keep the markers and the `pane:watch` pattern together.
- Test each tool you touch (`watch.tool`), in a private server with a
  throwaway repository (a directory with an empty `.git`) and a command like
  `grep -q ok src/a.txt`, flipping the file between ok and bad.
- Check it loads: `ranma --check-config` lists every plugin and why one failed;
  `ranma lua` runs code in the live server. Test behaviour in a private server
  (its own `RANMA_CONFIG_DIR`, `XDG_RUNTIME_DIR` and tmux socket, with
  `RANMA_SOCKET RANMA RANMA_PANE TMUX` unset), never the one you are typing in.
  CI (`.github/workflows/ci.yml`) loads it into the latest ranma release on
  every push and fails if it does not.
- `AGENTS.local.md` (gitignored) carries what is true of one checkout on one
  machine. Never commit it.
