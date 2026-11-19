-- agent-poke_nvim-wtd.5, review finding (blocker):
--   output.lua: a refresh tick already queued by the old window's timer that
--   runs after output() was toggled closed and open again must not stop the NEW
--   window's timer; the reopened window keeps following the run in flight.
--
-- Fakes (test doubles): `claude` records argv; with -p it prints one assistant
-- text, waits (at most ~5 s) for <log>/release, prints a second text and a
-- result. The fake is first on PATH; herdr is not used.
local helpers = require("tests.helpers")
local uv = vim.uv or vim.loop

local function new_dir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return uv.fs_realpath(d)
end

-- Body of the fake `claude` (runs after the install_fakes prelude, which
-- sets $log, $d and $n): with -p it prints "line one from fake run N", waits
-- (at most ~5 s) for <log>/release, prints "after the gate from fake run N" and
-- a result, then touches $d/done.
local CLAUDE_BODY = [[
sid=fake-session; prev=; p=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  if [ "$a" = "-p" ]; then p=1; fi
  prev=$a
done
if [ -n "$p" ]; then
  printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one from fake run $n\"}]}}"
  i=0
  while [ ! -f "$log/release" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"after the gate from fake run $n\"}]}}"
  printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"RESULT-TEXT\",\"session_id\":\"$sid\"}"
fi
touch "$d/done"
]]

describe("output window: a stale refresh tick after reopening", function()
  local ap, headless, fakes, log, saved_env, old_notify, notes, first_win

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
    }
    fakes = helpers.install_fakes({ bodies = { claude = CLAUDE_BODY } })
    log = fakes.log
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
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
    fakes.flag("release")
    headless.stop_all()
    vim.wait(6000, fakes.all_done, 20)
    vim.wait(100)
    if vim.api.nvim_win_is_valid(first_win) then
      pcall(vim.api.nvim_set_current_win, first_win)
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    fakes.restore()
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
    fakes.flag("release")
    wait_for("the later text in the reopened window", function()
      return win_text(w):find("after the gate from fake", 1, true) ~= nil
    end)
  end)
end)

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
-- N" and a result (the shared CLAUDE_BODY above); the fake is first on PATH.

describe("output window idle refresh leaves the user's cursor alone", function()
  local ap, headless, fakes, log, saved_env, old_notify, notes, first_win

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
    }
    fakes = helpers.install_fakes({ bodies = { claude = CLAUDE_BODY } })
    log = fakes.log
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
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
    fakes.flag("release")
    headless.stop_all()
    vim.wait(6000, fakes.all_done, 20)
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
    fakes.restore()
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
    fakes.flag("release")
    ap.poke(root, "first")
    wait_for("the first run to finish", function()
      return not headless.running(root) and fakes.all_done()
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
    fakes.flag("release")
    wait_for("the later text in the open window", function()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
      return table.concat(lines, "\n"):find("after the gate from fake run 1", 1, true) ~= nil
    end)
  end)
end)
