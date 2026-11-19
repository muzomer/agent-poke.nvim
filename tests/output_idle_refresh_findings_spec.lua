-- agent-poke_nvim-ei4.4, review finding (blocker):
--   output.lua: the follow timer re-renders every interval while the window is
--   open; with a finished (or stopped) run it must not rewrite the buffer or
--   move the cursor when nothing changed, so a user scrolling up / selecting
--   earlier text in the output window is not snapped back to the bottom.
--   Rule: a periodic refresh only rewrites the buffer or moves the cursor
--   when the content changed.
--
-- Fakes (test doubles): `claude` with -p prints "line one from fake run N",
-- waits (at most ~5 s) for <log>/release, prints "after the gate from fake run
-- N" and a result. PATH holds only the fake and /usr/bin:/bin; herdr is absent.
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
  printf '%%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one from fake run $n\"}]}}"
  i=0
  while [ ! -f "$log/release" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  printf '%%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"after the gate from fake run $n\"}]}}"
  printf '%%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"RESULT-TEXT\",\"session_id\":\"$sid\"}"
fi
touch "$d/done"
]]

describe("output window idle refresh leaves the user's cursor alone", function()
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
    -- let any output timer notice its window is gone
    vim.wait(require("agent-poke.output").interval * 3 + 100)
    vim.notify = old_notify
    for k, v in pairs(saved_env) do
      vim.env[k] = v
    end
    require("agent-poke").config = require("agent-poke.defaults")()
  end)

  local function wait_for(what, cond)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; notes: " .. vim.inspect(notes))
  end

  local function open_output(root)
    local before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      before[w] = true
    end
    ap.output(root)
    local opened = vim.tbl_filter(function(w)
      return not before[w]
    end, vim.api.nvim_list_wins())
    assert.are.equal(1, #opened)
    return opened[1]
  end

  -- The user moves into the output window and up to line 1; several refresh
  -- intervals later neither the cursor nor the buffer may have been touched.
  local function assert_idle_window_left_alone(w)
    local b = vim.api.nvim_win_get_buf(w)
    local count = vim.api.nvim_buf_line_count(b)
    assert.is_true(count >= 2, "need at least two lines to scroll: "
      .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false)))
    -- let the window settle after any last content change
    vim.wait(require("agent-poke.output").interval * 2 + 100)
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { 1, 0 })
    local tick = vim.api.nvim_buf_get_changedtick(b)
    vim.wait(require("agent-poke.output").interval * 4 + 100)
    assert.is_true(vim.api.nvim_win_is_valid(w), "the window was closed")
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(w),
      "the refresh moved the cursor although nothing changed")
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(b),
      "the refresh rewrote the buffer although nothing changed")
  end

  it("a finished run's open window keeps the cursor where the user put it", function()
    local root = new_dir()
    write(log .. "/release", "")
    ap.poke(root, "first")
    wait_for("the first run to finish", function()
      return not headless.running(root) and runs_done()
    end)
    local w = open_output(root)
    assert_idle_window_left_alone(w)
  end)

  it("a stopped run's open window keeps the cursor where the user put it", function()
    local root = new_dir()
    ap.poke(root, "say more")
    wait_for("the first text of the run in flight", function()
      return table.concat(headless.lines(root), "\n"):find("line one from fake run 1", 1, true) ~= nil
    end)
    ap.stop(root)
    vim.wait(300)
    assert.is_false(headless.running(root))
    local w = open_output(root)
    assert_idle_window_left_alone(w)
  end)

  it("passes already: a window still follows new text after the user scrolled up", function()
    local root = new_dir()
    ap.poke(root, "say more")
    wait_for("the first text of the run in flight", function()
      return table.concat(headless.lines(root), "\n"):find("line one from fake run 1", 1, true) ~= nil
    end)
    local w = open_output(root)
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { 1, 0 })
    write(log .. "/release", "")
    wait_for("the later text in the open window", function()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
      return table.concat(lines, "\n"):find("after the gate from fake run 1", 1, true) ~= nil
    end)
  end)
end)
