-- agent-poke_nvim-3am, review finding (blocker, herdr.lua:355): with
-- config.agent = "herdr" and the remembered pane gone, poke() lists the agents,
-- finds the pane missing and opens the picker. The editor must be blocked at
-- most TIMEOUT_MS in total before the picker opens (not one list per step with
-- a fresh TIMEOUT_MS each), and the picker must offer the agents herdr listed.
--
-- herdr.TIMEOUT_MS is shortened to 1500 ms here. The fake `herdr` sleeps 1.3 s
-- (just under the timeout) before each answer, so two chained calls take ~2.6 s.
-- On SIGTERM it kills its sleep and exits, so no child is left behind.
local uv = vim.uv or vim.loop

local TIMEOUT = 1500
local DELAY = "1.3"
local SLACK = 400 -- ms allowed beyond TIMEOUT for process start and bookkeeping

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

local function new_dir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return uv.fs_realpath(d)
end

local HERDR = [[#!/bin/sh
log="%s"
n=$(cat "$log/herdr.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/herdr.n"
d="$log/herdr.$n"; mkdir -p "$d"
printf '%%s ' "$@" > "$d/argv"
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null; fi; touch "$d/done"; exit 143' TERM INT
sleep %s &
pid=$!
wait "$pid"
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  cat "$log/agents.json"
else
  printf '%%s\n' '{"result":{"ok":true}}'
fi
touch "$d/done"
]]

local CLAUDE = [[#!/bin/sh
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake-session"}'
printf '%s\n' '{"type":"result","subtype":"success","result":"ok","session_id":"fake-session"}'
]]

local function install()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  write(bin .. "/herdr", string.format(HERDR, log, DELAY))
  write(bin .. "/claude", CLAUDE)
  uv.fs_chmod(bin .. "/herdr", tonumber("755", 8))
  uv.fs_chmod(bin .. "/claude", tonumber("755", 8))
  local self = { bin = bin, log = log }
  function self.pending()
    local n = tonumber(vim.trim(read(log .. "/herdr.n") or "0")) or 0
    for i = 1, n do
      if not uv.fs_stat(log .. "/herdr." .. i .. "/done") then
        return true
      end
    end
    return false
  end
  function self.agents(list)
    write(log .. "/agents.json", vim.json.encode({ result = { agents = list } }))
  end
  return self
end

local function ms_since(t0)
  return (uv.hrtime() - t0) / 1e6
end

describe("agent-poke.herdr re-pick when the remembered pane is gone (agent = herdr)", function()
  local herdr, state, headless, fakes, notes, offered, selected_at
  local saved_env, old_notify, old_select, old_timeout

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
    }
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    fakes = install()
    vim.env.PATH = fakes.bin .. ":/usr/bin:/bin"
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname() .. ".sock"
    vim.env.HERDR_PANE_ID = "w1:p5"

    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    old_select = vim.ui.select
    offered, selected_at = nil, nil
    vim.ui.select = function(items, opts, cb)
      selected_at = uv.hrtime()
      offered = {}
      for _, item in ipairs(items) do
        local label = opts and opts.format_item and opts.format_item(item) or tostring(item.title)
        offered[#offered + 1] = tostring(label)
      end
      cb(nil) -- cancel: no further herdr call is started
    end

    require("agent-poke").setup({ isolate = false, agent = "herdr" })
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
    herdr = require("agent-poke.herdr")
    old_timeout = herdr.TIMEOUT_MS
    herdr.TIMEOUT_MS = TIMEOUT

    fakes.agents({
      {
        pane_id = "w1:p1",
        agent = "claude",
        agent_status = "idle",
        cwd = new_dir(),
        terminal_title_stripped = "Review PR",
      },
    })
  end)

  after_each(function()
    if herdr then
      herdr.TIMEOUT_MS = old_timeout
    end
    if headless then
      headless.stop_all()
    end
    if fakes then
      vim.wait(5000, function()
        return not fakes.pending()
      end, 20)
      vim.wait(100)
    end
    vim.notify = old_notify
    vim.ui.select = old_select
    for k, v in pairs(saved_env) do
      vim.env[k] = v
    end
    require("agent-poke").setup()
  end)

  it("at most TIMEOUT_MS before the picker opens, and it offers the listed agents", function()
    local root = new_dir()
    state.set(root, "target", { pane_id = "w1:p9", title = "Gone agent" }) -- not in herdr's list
    local t0 = uv.hrtime()
    local res = herdr.poke(root, "please check the comments")
    local took = ms_since(t0)
    assert.is_not_nil(selected_at, string.format("the picker did not open (poke() returned %s after %d ms); notes: %s",
      tostring(res), took, vim.inspect(notes)))
    local before = (selected_at - t0) / 1e6
    assert.is_true(before <= TIMEOUT + SLACK,
      string.format("picker opened after %d ms, more than TIMEOUT_MS (%d) + %d; notes: %s",
        before, TIMEOUT, SLACK, vim.inspect(notes)))
    local found = false
    for _, label in ipairs(offered) do
      if label:find("Review PR", 1, true) then
        found = true
      end
    end
    assert.is_true(found, "the picker did not offer the listed agent; offered: " .. vim.inspect(offered))
  end)
end)
