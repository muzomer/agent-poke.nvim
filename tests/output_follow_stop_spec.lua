-- agent-poke_nvim-ei4.4: the output window follows new runs; stop() keeps the
-- stopped run's text.
--   - an output window opened before a run shows the next run's text as it
--     streams, without reopening;
--   - after stop(root), output(root) still shows the stopped run's lines
--     followed by a "(stopped)" line;
--   - timers still stop when the window closes.
--
-- Fakes (test doubles): `claude` with -p prints "line one from fake run N",
-- waits (at most ~5 s) for <log>/release, prints "after the gate from fake run
-- N" and a result. the fake is first on PATH; herdr is not used.
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

local function active_timers()
  local n = 0
  uv.walk(function(h)
    if h:get_type() == "timer" and h:is_active() and not h:is_closing() then
      n = n + 1
    end
  end)
  return n
end

describe("output window follows runs and keeps stopped text", function()
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

  local function wait_for(what, cond, extra)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; "
      .. (extra and extra() or "") .. "; notes: " .. vim.inspect(notes))
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

  local function win_lines(w)
    if not vim.api.nvim_win_is_valid(w) then
      return {}
    end
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
  end

  local function win_text(w)
    return table.concat(win_lines(w), "\n")
  end

  local function open_output(root)
    local before = vim.api.nvim_list_wins()
    ap.output(root)
    local opened = new_wins(before)
    assert.are.equal(1, #opened)
    return opened[1]
  end

  local function index_of(lines, needle)
    for i, l in ipairs(lines) do
      if l:find(needle, 1, true) then
        return i
      end
    end
  end

  -- "followed by a (stopped) line": a line reading "(stopped)" comes after
  -- the run's text and is the last line.
  local function assert_stopped_after(w, text)
    local lines = win_lines(w)
    local at = index_of(lines, text)
    assert.is_truthy(at, "the stopped run's text is gone: " .. vim.inspect(lines))
    local stopped
    for i = at + 1, #lines do
      if vim.trim(lines[i]) == "(stopped)" then
        stopped = i
      end
    end
    assert.is_truthy(stopped, "no '(stopped)' line after the run's text: " .. vim.inspect(lines))
    assert.are.equal(#lines, stopped, "'(stopped)' is not the last line: " .. vim.inspect(lines))
  end

  it("a window opened before any run shows the next run's text as it streams", function()
    local root = new_dir()
    local w = open_output(root)
    assert.is_false(headless.running(root))

    ap.poke(root, "say something")
    wait_for("the first text in the already open window", function()
      return win_text(w):find("line one from fake run 1", 1, true) ~= nil
    end, function()
      return win_text(w)
    end)
    assert.is_true(vim.api.nvim_win_is_valid(w), "the window was closed")
    assert.is_true(headless.running(root), "the run finished before the window could be judged as streaming")

    fakes.flag("release")
    wait_for("the later text in the already open window", function()
      return win_text(w):find("after the gate from fake run 1", 1, true) ~= nil
    end, function()
      return win_text(w)
    end)
  end)

  it("a window left open after a finished run shows the next run without reopening", function()
    local root = new_dir()
    fakes.flag("release")
    ap.poke(root, "first")
    wait_for("the first run to finish", function()
      return not headless.running(root) and fakes.all_done()
    end)
    local w = open_output(root)
    assert.is_truthy(win_text(w):find("after the gate from fake run 1", 1, true), win_text(w))
    vim.wait(require("agent-poke.output").interval * 2 + 100)

    os.remove(log .. "/release")
    ap.poke(root, "second")
    wait_for("the second run's text in the open window", function()
      return win_text(w):find("line one from fake run 2", 1, true) ~= nil
    end, function()
      return win_text(w)
    end)
    fakes.flag("release")
    wait_for("the second run's later text in the open window", function()
      return win_text(w):find("after the gate from fake run 2", 1, true) ~= nil
    end, function()
      return win_text(w)
    end)
  end)

  it("after stop(root) the open window keeps the run's lines followed by '(stopped)'", function()
    local root = new_dir()
    ap.poke(root, "say more")
    wait_for("the first text of the run in flight", function()
      return table.concat(headless.lines(root), "\n"):find("line one from fake run 1", 1, true) ~= nil
    end)
    local w = open_output(root)
    assert.is_truthy(win_text(w):find("line one from fake run 1", 1, true), win_text(w))

    ap.stop(root)
    wait_for("a '(stopped)' line in the open window", function()
      return vim.iter(win_lines(w)):any(function(l)
        return vim.trim(l) == "(stopped)"
      end)
    end, function()
      return win_text(w)
    end)
    vim.wait(require("agent-poke.output").interval * 2 + 100)
    assert_stopped_after(w, "line one from fake run 1")
  end)

  it("output(root) opened after stop(root) shows the run's lines followed by '(stopped)'", function()
    local root = new_dir()
    ap.poke(root, "say more")
    wait_for("the first text of the run in flight", function()
      return table.concat(headless.lines(root), "\n"):find("line one from fake run 1", 1, true) ~= nil
    end)
    ap.stop(root)
    -- a killed fake never writes its done marker; give the exit a moment
    vim.wait(300)
    assert.is_false(headless.running(root))
    local w = open_output(root)
    assert.is_nil(win_text(w):find("(no output yet)", 1, true), win_text(w))
    assert_stopped_after(w, "line one from fake run 1")
  end)

  it("passes already: timers stop when the output window closes", function()
    local root = new_dir()
    local interval = require("agent-poke.output").interval
    -- vim.wait runs its own timer: measure the baseline from inside one too
    local base
    vim.wait(1000, function()
      base = active_timers()
      return true
    end, 10)

    -- idle window closed by toggling
    open_output(root)
    vim.wait(interval * 2 + 50)
    ap.output(root)
    wait_for("timers back to the baseline after toggling closed", function()
      return active_timers() <= base
    end, function()
      return "active timers " .. active_timers() .. ", baseline " .. base
    end)

    -- idle window closed directly
    local w = open_output(root)
    vim.wait(interval * 2 + 50)
    vim.api.nvim_win_close(w, true)
    wait_for("timers back to the baseline after closing the window", function()
      return active_timers() <= base
    end, function()
      return "active timers " .. active_timers() .. ", baseline " .. base
    end)

    -- window following a run in flight, closed directly while it runs
    ap.poke(root, "say more")
    wait_for("the first text of the run in flight", function()
      return table.concat(headless.lines(root), "\n"):find("line one from fake run 1", 1, true) ~= nil
    end)
    w = open_output(root)
    vim.wait(interval * 2 + 50)
    vim.api.nvim_win_close(w, true)
    fakes.flag("release")
    wait_for("the run to finish", function()
      return not headless.running(root) and fakes.all_done()
    end)
    wait_for("timers back to the baseline after the run and window are gone", function()
      return active_timers() <= base
    end, function()
      return "active timers " .. active_timers() .. ", baseline " .. base
    end)
  end)
end)
