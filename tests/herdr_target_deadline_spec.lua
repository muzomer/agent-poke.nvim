-- agent-poke_nvim-0d8.2: one deadline for a poke step through the core API.
-- With herdr as a target, core's poke() lists the target's entries and then
-- calls its deliver(): together these herdr calls block the editor for at
-- most TIMEOUT_MS, not TIMEOUT_MS each. A failure is reported once, with the
-- prompt kept in the " register.
--
-- herdr.TIMEOUT_MS is shortened to 1500 ms. The fake `herdr` sleeps 1.3 s
-- before each answer (list + prompt chained: ~2.6 s). On SIGTERM it kills its
-- sleep and exits, so no child is left behind.
local uv = vim.uv or vim.loop

local TIMEOUT = 1500
local DELAY = "1.3"
local SLACK = 400

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

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("herdr target: one deadline per poke() through core", function()
  local ap, herdr, state, fakes, notes
  local saved_env, old_notify, old_select

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
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    ap.setup({ targets = { herdr = { isolate = false } } })
    state = require("agent-poke.state")
    herdr = require("agent-poke.targets.herdr")
    herdr.TIMEOUT_MS = TIMEOUT
    fakes.agents({
      { pane_id = "w1:p1", agent = "claude", agent_status = "idle", cwd = new_dir(), terminal_title_stripped = "Review PR" },
    })
  end)

  after_each(function()
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
    unload()
  end)

  it("list + deliver for a stored herdr entry block at most TIMEOUT_MS in total; a timeout is one notice", function()
    local r = new_dir()
    state.set(r, "target", { target = "herdr", id = "w1:p1" })
    vim.fn.setreg('"', "something else")
    local t0 = uv.hrtime()
    local status = ap.poke(r, "please check the comments")
    local took = (uv.hrtime() - t0) / 1e6
    assert.is_true(took <= TIMEOUT + SLACK,
      string.format("poke() blocked %d ms, more than TIMEOUT_MS (%d) + %d; notes: %s", took, TIMEOUT, SLACK, vim.inspect(notes)))
    if status then -- only if the step needed a single herdr call
      assert.are.equal("typed", status)
      return
    end
    local errs = vim.tbl_filter(function(n)
      return (n.level or vim.log.levels.INFO) >= vim.log.levels.ERROR
    end, notes)
    assert.are.equal(1, #errs, "one notice per failed delivery; got: " .. vim.inspect(notes))
    assert.are.equal("please check the comments", vim.fn.getreg('"'))
  end)
end)
