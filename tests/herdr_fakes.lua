-- Test doubles and harness for the herdr target specs (not a spec itself).
--
-- Fakes: `herdr` answers `agent list` from <log>/agents.json (or fails with
-- exit 1 while <log>/list_fail exists) and `agent prompt` from
-- <log>/prompt.json (default {"result":{"ok":true}}); it records argv and cwd
-- per call, and can sleep `delay` seconds first (on SIGTERM it kills the sleep
-- and exits). `claude` records argv and cwd, prints stream-json and exits.
-- PATH holds only the fakes and /usr/bin:/bin, so the real herdr / claude are
-- never reached.
--
-- harness() registers before_each/after_each in the calling describe and
-- returns a table `h` filled in for each test:
--   h.ap, h.state, h.fakes, h.notes ({msg, level}), h.selects (one entry per
--   vim.ui.select: { labels, mode, at }), h.choose (substring of the label to
--   choose; nil dismisses), h.on_select (called before the choice).
local uv = vim.uv or vim.loop

local M = {}

M.OWN = "w1:p5" -- the pane this Neovim runs in

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end
M.write = write

function M.new_dir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return uv.fs_realpath(d)
end

local RECORD = [[#!/bin/sh
log="%s"
name="%s"
delay="%s"
n=$(cat "$log/$name.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/$name.n"
d="$log/$name.$n"; mkdir -p "$d"
: > "$d/argv.tmp"
for a in "$@"; do printf '%%s\0' "$a" >> "$d/argv.tmp"; done
mv "$d/argv.tmp" "$d/argv"
pwd -P > "$d/cwd"
%s
]]

local HERDR_BODY = [[
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null; fi; touch "$d/done"; exit 143' TERM INT
if [ "$delay" != "0" ]; then
  sleep "$delay" &
  pid=$!
  wait "$pid"
  pid=
fi
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  if [ -e "$log/list_fail" ]; then
    echo "herdr: connection refused" >&2
    touch "$d/done"
    exit 1
  fi
  cat "$log/agents.json"
elif [ -f "$log/prompt.json" ]; then
  cat "$log/prompt.json"
  touch "$d/done"
  exit 1
else
  printf '%s\n' '{"result":{"ok":true}}'
fi
touch "$d/done"
]]

local CLAUDE_BODY = [[
sid=fake-session; prev=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  prev=$a
done
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
touch "$d/done"
]]

---@param opts? { delay?: string } seconds the fake herdr sleeps before answering
function M.install(opts)
  opts = opts or {}
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  for name, body in pairs({ herdr = HERDR_BODY, claude = CLAUDE_BODY }) do
    write(bin .. "/" .. name, string.format(RECORD, log, name, name == "herdr" and (opts.delay or "0") or "0", body))
    uv.fs_chmod(bin .. "/" .. name, tonumber("755", 8))
  end
  local self = { bin = bin, log = log }
  function self.calls(name)
    local list = {}
    local n = tonumber(vim.trim(read(log .. "/" .. name .. ".n") or "0")) or 0
    for i = 1, n do
      local d = log .. "/" .. name .. "." .. i
      local raw = read(d .. "/argv")
      if raw then
        local argv = {}
        for a in raw:gmatch("([^%z]*)%z") do
          argv[#argv + 1] = a
        end
        list[#list + 1] = { argv = argv, cwd = vim.trim(read(d .. "/cwd") or ""), done = uv.fs_stat(d .. "/done") ~= nil }
      else
        list[#list + 1] = { argv = {}, cwd = "", done = uv.fs_stat(d .. "/done") ~= nil }
      end
    end
    return list
  end
  function self.pending()
    for _, name in ipairs({ "herdr", "claude" }) do
      for _, c in ipairs(self.calls(name)) do
        if not c.done then
          return true
        end
      end
    end
    return false
  end
  function self.prompts()
    return vim.tbl_filter(function(c)
      return c.argv[1] == "agent" and c.argv[2] == "prompt"
    end, self.calls("herdr"))
  end
  function self.agents(list)
    write(log .. "/agents.json", vim.json.encode({ result = { agents = list } }))
  end
  function self.list_fails(on)
    if on then
      write(log .. "/list_fail", "")
    else
      os.remove(log .. "/list_fail")
    end
  end
  function self.prompt_fails(message)
    write(log .. "/prompt.json", vim.json.encode({ error = { code = "pane_not_found", message = message } }) .. "\n")
  end
  function self.remove_herdr()
    os.remove(bin .. "/herdr")
  end
  return self
end

function M.pane(id, title, cwd, session)
  return {
    pane_id = id,
    agent = "claude",
    agent_status = "idle",
    cwd = cwd,
    terminal_title_stripped = title,
    agent_session = session and { value = session } or nil,
  }
end

function M.arg_after(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

function M.unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

---A Claude transcript of `session`, started in `dir`, under $CLAUDE_CONFIG_DIR.
function M.transcript(session, dir)
  local project = vim.env.CLAUDE_CONFIG_DIR .. "/projects/" .. dir:gsub("[^%w]", "-")
  write(project .. "/" .. session .. ".jsonl", vim.json.encode({ type = "user", cwd = dir, sessionId = session }) .. "\n")
end

function M.contains(labels, text)
  for _, l in ipairs(labels or {}) do
    if l:find(text, 1, true) then
      return true
    end
  end
  return false
end

---@param opts? { delay?: string }
function M.harness(opts)
  local h = {}
  local saved_env, old_notify, old_select

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
    }
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    h.fakes = M.install(opts)
    vim.env.PATH = h.fakes.bin .. ":/usr/bin:/bin"
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname() .. ".sock"
    vim.env.HERDR_PANE_ID = M.OWN
    vim.env.CLAUDE_CONFIG_DIR = M.new_dir()

    old_notify = vim.notify
    h.notes = {}
    vim.notify = function(msg, level)
      h.notes[#h.notes + 1] = { msg = tostring(msg), level = level }
    end
    old_select = vim.ui.select
    h.selects, h.choose, h.on_select = {}, nil, nil
    vim.ui.select = function(items, o, cb)
      local labels, picked = {}, nil
      for _, item in ipairs(items) do
        local label = tostring(o and o.format_item and o.format_item(item)
          or (type(item) == "table" and (item.title or item.label)) or item)
        labels[#labels + 1] = label
        if not picked and h.choose and label:find(h.choose, 1, true) then
          picked = item
        end
      end
      h.selects[#h.selects + 1] = { labels = labels, mode = vim.api.nvim_get_mode().mode, at = uv.hrtime() }
      if h.on_select then
        h.on_select()
      end
      cb(picked)
    end

    M.unload()
    h.ap = require("agent-poke")
    h.ap.config = require("agent-poke.defaults")()
    h.state = require("agent-poke.state")
  end)

  after_each(function()
    local headless = package.loaded["agent-poke.headless"]
    if headless then
      pcall(headless.stop_all)
    end
    if h.fakes then
      vim.wait(8000, function()
        return not h.fakes.pending()
      end, 20)
      vim.wait(100)
    end
    vim.notify = old_notify
    vim.ui.select = old_select
    for k, v in pairs(saved_env) do
      vim.env[k] = v
    end
    M.unload()
  end)

  function h.wait_for(what, cond)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; notes: " .. vim.inspect(h.notes))
  end

  function h.wait_claude(n)
    h.wait_for(n .. " claude run(s)", function()
      local calls = h.fakes.calls("claude")
      return #calls >= n and calls[n].done
    end)
    vim.wait(100) -- let on_exit run
  end

  function h.wait_prompt(n)
    h.wait_for(n .. " herdr prompt(s)", function()
      return #h.fakes.prompts() >= n
    end)
  end

  function h.errors()
    return vim.tbl_filter(function(n)
      return (n.level or vim.log.levels.INFO) >= vim.log.levels.ERROR
    end, h.notes)
  end

  return h
end

return M
