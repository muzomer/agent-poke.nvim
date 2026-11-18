-- agent-poke_nvim-wtd.5, review finding (blocker):
--   output.lua: a refresh tick already queued by the old window's timer that
--   runs after output() was toggled closed and open again must not stop the NEW
--   window's timer; the reopened window keeps following the run in flight.
--
-- Fakes (test doubles): `claude` records argv; with -p it prints one assistant
-- text, waits (at most ~5 s) for <log>/release, prints a second text and a
-- result. PATH holds only the fake and /usr/bin:/bin; herdr is absent.
local uv = vim.uv or vim.loop

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

local CLAUDE = [[#!/bin/sh
log="%s"
n=$(cat "$log/claude.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/claude.n"
d="$log/claude.$n"; mkdir -p "$d"
sid=fake-session; prev=; p=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  if [ "$a" = "-p" ]; then p=1; fi
  prev=$a
done
if [ -n "$p" ]; then
  printf '%%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
  printf '%%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line one from fake"}]}}'
  i=0
  while [ ! -f "$log/release" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  printf '%%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"after the gate from fake"}]}}'
  printf '%%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"RESULT-TEXT\",\"session_id\":\"$sid\"}"
fi
touch "$d/done"
]]

describe("output window (review findings)", function()
  local ap, headless, log, saved_env, old_notify, notes, first_win

  local function runs_done()
    local n = tonumber(vim.trim(read(log .. "/claude.n") or "0")) or 0
    for i = 1, n do
      if not uv.fs_stat(log .. "/claude." .. i .. "/done") then
        return false
      end
    end
    return true
  end

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
    }
    local dir = vim.fn.tempname()
    local bin = dir .. "/bin"
    log = dir .. "/log"
    vim.fn.mkdir(bin, "p")
    vim.fn.mkdir(log, "p")
    write(bin .. "/claude", string.format(CLAUDE, log))
    uv.fs_chmod(bin .. "/claude", tonumber("755", 8))
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    vim.env.PATH = bin .. ":/usr/bin:/bin"
    vim.env.HERDR_SOCKET_PATH = nil
    vim.env.HERDR_PANE_ID = nil
    vim.env.CLAUDE_CONFIG_DIR = new_dir()

    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    first_win = vim.api.nvim_get_current_win()
    ap = require("agent-poke")
    ap.setup({ agent = "headless" })
    headless = require("agent-poke.headless")
  end)

  after_each(function()
    write(log .. "/release", "")
    headless.stop_all()
    vim.wait(6000, runs_done, 20)
    vim.wait(100)
    if vim.api.nvim_win_is_valid(first_win) then
      pcall(vim.api.nvim_set_current_win, first_win)
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.notify = old_notify
    for k, v in pairs(saved_env) do
      vim.env[k] = v
    end
    require("agent-poke").config = require("agent-poke.defaults")()
  end)

  local function wait_for(what, cond)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; notes: " .. vim.inspect(notes))
  end

  local function new_wins(before)
    local seen = {}
    for _, w in ipairs(before) do
      seen[w] = true
    end
    return vim.tbl_filter(function(w)
      return not seen[w]
    end, vim.api.nvim_list_wins())
  end

  local function win_text(w)
    if not vim.api.nvim_win_is_valid(w) then
      return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
  end

  it("a tick queued by the old window does not stop the reopened window from following", function()
    local root = new_dir()
    ap.poke(root, "say more")
    wait_for("the first text of the run in flight", function()
      return table.concat(headless.lines(root), "\n"):find("line one from fake", 1, true) ~= nil
    end)
    assert.is_true(headless.running(root))

    local before = vim.api.nvim_list_wins()
    ap.output(root) -- window 1, its refresh timer starts
    assert.are.equal(1, #new_wins(before))

    -- Let window 1's timer come due and fire (its tick is queued on the main
    -- loop, not run yet), then close and reopen in the same busy stretch.
    uv.sleep(require("agent-poke.output").interval * 2 + 100)
    uv.run("nowait")
    ap.output(root) -- closes window 1
    ap.output(root) -- window 2, its own refresh timer starts
    local opened = new_wins(before)
    assert.are.equal(1, #opened)
    local w = opened[1]
    assert.is_truthy(win_text(w):find("line one from fake", 1, true), win_text(w))

    vim.wait(50) -- the stale tick of window 1 runs now
    write(log .. "/release", "")
    wait_for("the later text in the reopened window", function()
      return win_text(w):find("after the gate from fake", 1, true) ~= nil
    end)
  end)
end)
