# watch.ranma

A plugin for [ranma](https://github.com/masshirodev/ranma), the terminal tiling window manager: rerun a command (tests, a type check, a build) whenever the repository's files change, in a pane parked out of sight, with the last run's result as a badge on every pane in that repository.

Needs ranma v0.2.2 or newer.

## Install

With [hako](https://github.com/masshirodev/hako.ranma), in `~/.config/ranma/lua/plugins/watch.lua`:

```lua
return { "masshirodev/watch.ranma" }
```

Or by hand, as ranma loads any package under `pack/*/start/`:

```sh
git clone https://github.com/masshirodev/watch.ranma ~/.config/ranma/pack/plugins/start/watch.ranma
```

Needs one of: [watchexec](https://github.com/watchexec/watchexec), [entr](https://eradman.com/entrproject/) (with `git`), or `inotifywait` (inotify-tools).

## What it does

```text
watch: rerun a command when the repository's files change, out of sight,
with the result as a badge on the repository's panes.

leader W   (shift+w) is a which-key folder, watch:
  w   start a watcher for the focused pane's repository: asks for the
      command (the last one used there, else a guess: cargo test, the
      package's test script, go test ./..., make), then runs it in a pane
      parked on a hidden workspace (watch.workspace) and again whenever a
      file in the repository changes. With one running: stop it.
  s   show the watcher's pane, floating over this workspace; again, park it.
  e   change the command, and start again with it.
  l   the watchers running, in a picker: Enter shows one.
In the palette (leader :): `watch [start|stop|show|edit|list]`; `watch
start CMD` starts with that command without asking.
Another key: ranma.bind(KEY, function() ranma.emit("watch", "show") end).

Every pane whose directory is in the repository gets a badge: `● watch`
while a run goes, `✓ watch` after one passed, `✗ watch` after one failed.
The watcher pane prints `[watch.ranma] start` and `[watch.ranma] exit N`
around each run, and the badges follow those lines (a pane:watch); the
command runs inside watchexec, entr or an inotifywait loop, not at a
shell prompt, so the shell's command_finished never sees it.

The tool (watch.tool): watchexec, else entr (fed `git ls-files`, so
ignored files never trigger), else inotifywait (inotify-tools; changes
made while a run goes are not seen until the next one), whichever is
installed first; or one named. .git, node_modules, target, build, dist and
.svelte-kit never trigger a run.

Unlike gate.ranma, which runs a repository's checks once on a key, this
keeps running until stopped (or its pane is closed). The watchers survive
a config reload; a server upgrade keeps their panes, and the badges come
back from what the panes last printed.

Needs ranma 0.2.2 or newer, the first with hide_workspace.

ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Actions",
"Pane handles", "Pickers and prompts", "A plugin's state", "Hooks").
```

## Binds and commands

| Key / command | |
| --- | --- |
| `leader W w` | Start watching the focused pane's repository (asks for the command); with a watcher running, stop or show it. |
| `leader W s` | Show the watcher's pane floating over this workspace; again (focused), park it. |
| `leader W e` | Change the command and start again. |
| `leader W l` | The running watchers. |
| `watch [start [CMD]\|stop\|show\|edit\|list]` in the palette | The same; `watch start CMD` does not ask. |

`leader W` is shift+w, a folder in the which-key hint's plugins group. Another key, in `init.lua` after the plugin loads:

```lua
ranma.bind("<key>", function() ranma.emit("watch", "show") end, { desc = "watcher", exit = true })
```

## Options

In ranma's settings panel under `watch`, or with hako's `opts`, or `ranma.set { watch = { ... } }`.

| Option | Default | |
| --- | --- | --- |
| `watch.tool` | `"auto"` | `watchexec`, `entr` or `inotifywait`; `auto` takes the first installed, in that order. |
| `watch.workspace` | `98` | The hidden workspace watchers are parked on. scratch.ranma parks on 99. |
| `watch.badges` | `true` | Mark the repository's panes with the last run's result. |

## How it works

The watcher is an ordinary pane running `cd <root> && <tool> … sh -c '<markers>; <command>; <markers>'`, renamed `watch:<repo>`, moved to `watch.workspace` and that workspace hidden (`hide_workspace`). Each run clears the screen and prints `[watch.ranma] start`, then `[watch.ranma] exit N`; a `pane:watch` on those lines sets the status, and every pane whose directory is inside the repository is badged. A failed run in a watcher you are not looking at also toasts. Which pane watches which repository is kept in `ranma.store("watch")`, so a config reload finds the watchers again and reads their last marker back off the screen. The commands you used are kept per repository and offered next time.

## Limits

- With `inotifywait`, a change made while a run is going is not seen until the next change (the loop is not listening then). watchexec and entr queue it.
- Badges cover panes whose directory is in the repository (by `pane:cwd()`); a pane `ssh`ed elsewhere or in a worktree of the same repository is another directory.
- A server restarted from scratch (not upgraded) does not have the watcher's pane any more; start it again.

## License

MIT or Apache-2.0, as ranma.
