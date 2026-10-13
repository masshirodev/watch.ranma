-- watch: rerun a command when the repository's files change, out of sight,
-- with the result as a badge on the repository's panes.
--
-- leader W   (shift+w) is a which-key folder, watch:
--   w   start a watcher for the focused pane's repository: asks for the
--       command (the last one used there, else a guess: cargo test, the
--       package's test script, go test ./..., make), then runs it in a pane
--       parked on a hidden workspace (watch.workspace) and again whenever a
--       file in the repository changes. With one running: stop it.
--   s   show the watcher's pane, floating over this workspace; again, park it.
--   e   change the command, and start again with it.
--   l   the watchers running, in a picker: Enter shows one.
-- In the palette (leader :): `watch [start|stop|show|edit|list]`; `watch
-- start CMD` starts with that command without asking.
-- Another key: ranma.bind(KEY, function() ranma.emit("watch", "show") end).
--
-- Every pane whose directory is in the repository gets a badge: `● watch`
-- while a run goes, `✓ watch` after one passed, `✗ watch` after one failed.
-- The watcher pane prints `[watch.ranma] start` and `[watch.ranma] exit N`
-- around each run, and the badges follow those lines (a pane:watch); the
-- command runs inside watchexec, entr or an inotifywait loop, not at a
-- shell prompt, so the shell's command_finished never sees it.
--
-- The tool (watch.tool): watchexec, else entr (fed `git ls-files`, so
-- ignored files never trigger), else inotifywait (inotify-tools; changes
-- made while a run goes are not seen until the next one), whichever is
-- installed first; or one named. .git, node_modules, target, build, dist and
-- .svelte-kit never trigger a run.
--
-- Unlike gate.ranma, which runs a repository's checks once on a key, this
-- keeps running until stopped (or its pane is closed). The watchers survive
-- a config reload; a server upgrade keeps their panes, and the badges come
-- back from what the panes last printed.
--
-- Needs ranma 0.2.2 or newer, the first with hide_workspace.
--
-- ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Actions",
-- "Pane handles", "Pickers and prompts", "A plugin's state", "Hooks").

ranma.option("watch.tool", {
  type = "enum", choices = { "auto", "watchexec", "entr", "inotifywait" }, default = "auto",
  name = "Tool", desc = "What watches the files: the first installed of watchexec, entr and inotifywait, or one named.",
})
ranma.option("watch.workspace", {
  type = "int", min = 11, max = 99, default = 98, slider = false,
  name = "Workspace", desc = "The hidden workspace watchers are parked on (scratch.ranma parks on 99).",
})
ranma.option("watch.badges", {
  type = "bool", default = true,
  name = "Badges", desc = "Mark the repository's panes with the last run's result.",
})

local OWNER = "watch"
local store = ranma.store("watch")   -- watchers: root -> { pane, command }; commands: root -> command

local function fail(err)
  ranma.toast("watch: " .. tostring(err), { urgent = true })
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function sh(word)
  return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function root_of(cwd)
  local dir = cwd
  while dir and dir ~= "" do
    if exists(dir .. "/.git") then return dir end
    dir = dir:match("^(.*)/[^/]*$")
  end
end

local function name_of(root)
  return root:match("[^/]+$") or root
end

local function under(path, root)
  return path and (path == root or path:sub(1, #root + 1) == root .. "/")
end

-- The tool -------------------------------------------------------------------

local function on_path(cmd)
  for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
    if exists(dir .. "/" .. cmd) then return true end
  end
  return false
end

local function tool()
  local want = ranma.get("watch.tool")
  if want ~= "auto" then return on_path(want) and want or nil, want end
  for _, t in ipairs({ "watchexec", "entr", "inotifywait" }) do
    if on_path(t) then return t end
  end
  return nil, "watchexec, entr or inotifywait"
end

local IGNORE = { ".git", "node_modules", "target", "build", "dist", ".svelte-kit" }

-- The shell line the watcher pane runs: one run is the command between two
-- markers, on a cleared screen.
local function line_for(root, cmd, t)
  local run = [[printf '\033[H\033[2J[watch.ranma] start\n'; ]] .. cmd
    .. "\n" .. [[s=$?; printf '\n[watch.ranma] exit %s\n' "$s"]]
  local body
  if t == "watchexec" then
    local ignores = {}
    for _, d in ipairs(IGNORE) do ignores[#ignores + 1] = "-i " .. sh(d .. "/**") end
    body = "watchexec --shell=none " .. table.concat(ignores, " ") .. " -- sh -c " .. sh(run)
  elseif t == "entr" then
    -- entr -d ends when a file is added to a watched directory: the loop
    -- lists the files again and goes on.
    body = "while :; do { git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path './.git/*'; }"
      .. " | entr -d sh -c " .. sh(run) .. "; [ $? -eq 2 ] || break; done"
  else
    local ex = {}
    for _, d in ipairs(IGNORE) do ex[#ex + 1] = (d:gsub("%.", "\\.")) end
    body = "while :; do sh -c " .. sh(run) .. "; inotifywait -qq -r -e close_write,move,create,delete --exclude "
      .. sh("/(" .. table.concat(ex, "|") .. ")(/|$)") .. " . || break; done"
  end
  return "cd -- " .. sh(root) .. " && " .. body
end

-- A guess at the command, from what the repository has.
local function guess(root)
  if exists(root .. "/Cargo.toml") then return "cargo test" end
  local pkg = read(root .. "/package.json")
  if pkg then
    local pm = exists(root .. "/yarn.lock") and "yarn" or exists(root .. "/pnpm-lock.yaml") and "pnpm" or "npm"
    if pkg:find('"test"%s*:') then return pm .. " run test" end
    if pkg:find('"check"%s*:') then return pm .. " run check" end
  end
  if exists(root .. "/go.mod") then return "go test ./..." end
  if exists(root .. "/Makefile") then return "make" end
  return ""
end

-- Watchers -----------------------------------------------------------------------

local status = {}   -- root -> "running" | "pass" | "fail"
local watches = {}  -- pane id -> watch id

local function watchers() return store:get("watchers") or {} end

local function title_of(root) return "watch:" .. name_of(root) end

-- A root's watcher pane, while it is still the one we started.
local function pane_of(root)
  local w = watchers()[root]
  local p = w and ranma.pane(w.pane)
  if p and p:alive() and p.title == title_of(root) then return p end
end

local function forget(root)
  local all = watchers()
  all[root] = nil
  store:set("watchers", all)
  status[root] = nil
end

local BADGE = {
  running = { "●", "watch", "accent" },
  pass = { "✓", "watch", "normal" },
  fail = { "✗", "watch", "urgent" },
}

local function badge(p)
  if not ranma.get("watch.badges") then return end
  local cwd = p:cwd()
  for root, st in pairs(status) do
    local w = watchers()[root]
    if under(cwd, root) and not (w and w.pane == p.id) then
      local b = BADGE[st]
      return p:badge(OWNER, b[1], b[2], b[3])
    end
  end
  p:badge(OWNER)
end

local function badge_all()
  for _, p in ipairs(ranma.panes()) do badge(p) end
end

local function hear(root, p)
  if watches[p.id] then return end
  watches[p.id] = p:watch("\\[watch\\.ranma\\] (start|exit [0-9]+)", function(ev)
    local what = ev.text:match("%] (.*)$") or ""
    local before = status[root]
    if what == "start" then
      status[root] = "running"
    else
      status[root] = what == "exit 0" and "pass" or "fail"
      if before == "running" and status[root] == "fail" and not p.visible then
        ranma.toast("watch: " .. name_of(root) .. " failed (" .. what .. ")", { urgent = true })
      end
    end
    badge_all()
  end)
end

-- What a pane last printed, for watchers found again after a reload.
local function recover(root, p)
  local hits = p:search("\\[watch\\.ranma\\] (start|exit [0-9]+)", { limit = 1 })
  local h = hits[1]
  if h then
    local what = h.text:match("%] (.*)$") or ""
    status[root] = what == "start" and "running" or (what == "exit 0" and "pass" or "fail")
  end
end

-- Park the focused pane, or show a parked one -------------------------------

local function contains(list, v)
  for _, x in ipairs(list or {}) do if x == v then return true end end
  return false
end

local function park()
  local n = ranma.get("watch.workspace")
  ranma.action("move_to_workspace_silent " .. n)
  if not contains(ranma.state().hidden, n) then ranma.action("hide_workspace " .. n) end
end

local function show(p)
  local st = ranma.state()
  local here = st.workspace
  if here == 0 or here == ranma.get("watch.workspace") then here = 1 end
  if st.workspace == 0 then ranma.action("scratchpad_toggle") end
  p:focus()
  ranma.action("move_to_workspace " .. here)
  ranma.action("float_size 80 70")
  ranma.action("snap center")
end

-- Starting and stopping ------------------------------------------------------

local pending = nil   -- the root whose watcher pane is about to open

local function start(root, cmd)
  if cmd == "" then return fail("no command") end
  local t, want = tool()
  if not t then return fail("none of " .. want .. " is installed") end
  local cmds = store:get("commands") or {}
  cmds[root] = cmd
  store:set("commands", cmds)
  pending = { root = root, cmd = cmd }
  ranma.defer(3000, function() pending = nil end)
  if ranma.state().workspace == 0 then ranma.action("scratchpad_toggle") end
  ranma.action("exec " .. line_for(root, cmd, t))
end

ranma.on("pane_open", function(ev)
  local p = ranma.pane(ev.pane)
  if not p then return end
  if pending then
    local job = pending
    pending = nil
    local all = watchers()
    all[job.root] = { pane = p.id, command = job.cmd }
    store:set("watchers", all)
    p:rename(title_of(job.root))
    status[job.root] = "running"
    hear(job.root, p)
    p:focus()
    park()
    ranma.toast("watch: " .. name_of(job.root) .. " · " .. job.cmd .. " (leader W s shows it)")
    badge_all()
    return
  end
  badge(p)
end)

ranma.on("pane_close", function(ev)
  if watches[ev.pane] then
    ranma.unwatch(watches[ev.pane])
    watches[ev.pane] = nil
  end
  for root, w in pairs(watchers()) do
    if w.pane == ev.pane then
      forget(root)
      badge_all()
      ranma.toast("watch: stopped watching " .. name_of(root))
    end
  end
end)

ranma.on("cwd_change", function(ev)
  local p = ranma.pane(ev.pane)
  if p then badge(p) end
end)

local function stop(root)
  local p = pane_of(root)
  if p then p:close() else forget(root) badge_all() end
end

local function ask(root, text, then_)
  ranma.input {
    title = "watch " .. name_of(root) .. ": the command to rerun",
    text = text,
    on_submit = function(cmd)
      cmd = cmd:gsub("^%s+", ""):gsub("%s+$", "")
      then_(cmd)
    end,
  }
end

local function focused_root()
  local p = ranma.pane()
  local root = p and root_of(p:cwd() or "")
  -- In the watcher's own pane, its repository.
  if not root and p then
    for r, w in pairs(watchers()) do
      if w.pane == p.id then return r end
    end
  end
  if not root then fail("the focused pane is not in a repository") end
  return root
end

local ACTIONS = {}

function ACTIONS.start(arg)
  local root = focused_root()
  if not root then return end
  if pane_of(root) then
    return ranma.picker {
      title = "watch · " .. name_of(root) .. " is being watched",
      items = { { label = "stop", detail = watchers()[root].command }, { label = "show", detail = "its pane" } },
      on_select = function(item)
        if item.label == "stop" then stop(root) else show(pane_of(root)) end
      end,
    }
  end
  if arg and arg ~= "" then return start(root, arg) end
  local last = (store:get("commands") or {})[root]
  ask(root, last or guess(root), function(cmd) start(root, cmd) end)
end

function ACTIONS.stop()
  local root = focused_root()
  if not root then return end
  if not pane_of(root) then return ranma.toast("watch: nothing watches " .. name_of(root)) end
  stop(root)
end

function ACTIONS.show()
  local root = focused_root()
  if not root then return end
  local p = pane_of(root)
  if not p then return ranma.toast("watch: nothing watches " .. name_of(root) .. " (leader W w starts it)") end
  local st = ranma.state()
  if p.visible and st.focused == p.id then
    return park()
  end
  if p.visible then return p:focus() end
  show(p)
end

function ACTIONS.edit()
  local root = focused_root()
  if not root then return end
  local w = watchers()[root]
  local last = w and w.command or (store:get("commands") or {})[root] or guess(root)
  ask(root, last, function(cmd)
    local p = pane_of(root)
    if p then
      -- The old pane closes first; its close forgets the old watcher.
      p:close()
      ranma.defer(300, function() start(root, cmd) end)
    else
      start(root, cmd)
    end
  end)
end

function ACTIONS.list()
  local items = {}
  for root, w in pairs(watchers()) do
    if pane_of(root) then
      local mark = ({ running = "●", pass = "✓", fail = "✗" })[status[root] or ""] or ""
      items[#items + 1] = { label = name_of(root) .. "  " .. mark,
                            detail = w.command, root = root }
    end
  end
  if #items == 0 then return ranma.toast("watch: nothing is being watched") end
  ranma.picker {
    title = "watchers",
    items = items,
    on_select = function(item) show(pane_of(item.root)) end,
  }
end

-- Watchers that outlived a reload: hear them again, and say what they last said.
ranma.defer(0, function()
  local all = watchers()
  for root in pairs(all) do
    local p = pane_of(root)
    if p then
      hear(root, p)
      recover(root, p)
    else
      all[root] = nil
    end
  end
  store:set("watchers", all)
  badge_all()
end)

local WORDS = { "start", "stop", "show", "edit", "list" }

local function run(arg)
  local verb, rest = (arg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  if verb == "" then verb = "start" end
  local fn = ACTIONS[verb]
  if not fn then return fail("watch [" .. table.concat(WORDS, "|") .. "]") end
  fn(rest)
end

ranma.command("watch", run, {
  desc = "rerun a command when the repository's files change",
  args = "[start [cmd]|stop|show|edit|list]",
  complete = WORDS,
})
ranma.on("user:watch", function(data) run(type(data) == "string" and data or nil) end)

ranma.bind("shift+w", { folder = "watch", group = "plugins" })
ranma.bind("shift+w w", function() ACTIONS.start() end, { desc = "start / stop", exit = true })
ranma.bind("shift+w s", ACTIONS.show, { desc = "show / park", exit = true })
ranma.bind("shift+w e", ACTIONS.edit, { desc = "change command", exit = true })
ranma.bind("shift+w l", ACTIONS.list, { desc = "watchers", exit = true })
