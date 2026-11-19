-- agent-poke_nvim-wtd.5: the public entry points of require("agent-poke").
--
-- Interface (lua/agent-poke/init.lua), ported from code-review.nvim's
-- poke.lua / progress.lua / headless.lua:
--   poke(root, prompt)  -- the picked herdr pane gets it, else the background agent
--   pick(root)          -- choose root's agent (herdr panes + background)
--   output(root)        -- toggle a window following the current/last run's output,
--                          stream-json rendered as text
--   chat(root)          -- a terminal running the backend's interactive resume
--                          command (`claude --resume <id>`) on the stored session
--   stop(root)          -- stop the background run
--
-- Fakes (test doubles, defined here): `herdr` answers `agent list` from a
-- per-test agents.json and records argv; `claude` records argv and cwd; with
-- `-p` it prints stream-json (an assistant text event, then a result) and exits,
-- without `-p` (interactive) it exits at once. PATH holds only the fakes and
-- /usr/bin:/bin, so the real herdr / claude are never reached.
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

local RECORD = [[#!/bin/sh
log="%s"
name="%s"
n=$(cat "$log/$name.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/$name.n"
d="$log/$name.$n"; mkdir -p "$d"
: > "$d/argv.tmp"
for a in "$@"; do printf '%%s\0' "$a" >> "$d/argv.tmp"; done
mv "$d/argv.tmp" "$d/argv"
pwd -P > "$d/cwd"
%s
]]

local HERDR_BODY = [[
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  cat "$log/agents.json"
else
  printf '%s\n' '{"result":{"ok":true}}'
fi
touch "$d/done"
]]

-- With "$log/gate" present, a -p run waits (at most ~5 s) for "$log/release"
-- before printing its second message: a run that is still in flight.
local CLAUDE_BODY = [[
sid=fake-session; prev=; p=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  if [ "$a" = "-p" ]; then p=1; fi
  prev=$a
done
if [ -n "$p" ]; then
  printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line one from fake\nline two from fake"}]}}'
  if [ -f "$log/gate" ]; then
    i=0
    while [ ! -f "$log/release" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"after the gate from fake"}]}}'
  fi
  printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"RESULT-TEXT\",\"session_id\":\"$sid\"}"
fi
touch "$d/done"
]]

local function install()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  for name, body in pairs({ herdr = HERDR_BODY, claude = CLAUDE_BODY }) do
    write(bin .. "/" .. name, string.format(RECORD, log, name, body))
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
      end
    end
    return list
  end
  function self.agents(list)
    write(log .. "/agents.json", vim.json.encode({ result = { agents = list } }))
  end
  return self
end

local OWN = "w1:p5" -- the pane this Neovim runs in

local function pane(id, title, cwd)
  return { pane_id = id, agent = "claude", agent_status = "idle", cwd = cwd, terminal_title_stripped = title }
end

local function arg_after(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

describe("agent-poke public API", function()
  local ap, state, headless, fakes, notes, selects, choose
  local saved_env, old_notify, old_select, first_win

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
    }
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    fakes = install()
    vim.env.PATH = fakes.bin .. ":/usr/bin:/bin"
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname() .. ".sock"
    vim.env.HERDR_PANE_ID = OWN
    vim.env.CLAUDE_CONFIG_DIR = new_dir()

    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    old_select = vim.ui.select
    selects = 0
    choose = nil
    vim.ui.select = function(items, opts, cb)
      selects = selects + 1
      local picked
      for _, item in ipairs(items) do
        local label = opts and opts.format_item and opts.format_item(item)
          or (type(item) == "table" and (item.title or item.pane_id))
          or tostring(item)
        if choose and tostring(label):find(choose, 1, true) then
          picked = item
          break
        end
      end
      cb(picked)
    end

    first_win = vim.api.nvim_get_current_win()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
  end)

  after_each(function()
    pcall(vim.cmd, "stopinsert")
    if fakes then
      write(fakes.log .. "/release", "")
    end
    if headless then
      headless.stop_all()
    end
    if fakes then
      vim.wait(6000, function()
        for _, name in ipairs({ "herdr", "claude" }) do
          for _, c in ipairs(fakes.calls(name)) do
            if not c.done then
              return false
            end
          end
        end
        return true
      end, 20)
      vim.wait(100)
    end
    -- no terminal or extra window left behind
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
        pcall(vim.fn.jobstop, vim.b[buf].terminal_job_id)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    if vim.api.nvim_win_is_valid(first_win) then
      pcall(vim.api.nvim_set_current_win, first_win)
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.notify = old_notify
    vim.ui.select = old_select
    for k, v in pairs(saved_env) do
      vim.env[k] = v
    end
    require("agent-poke").config = require("agent-poke.defaults")()
  end)

  local function wait_for(what, cond)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; notes: " .. vim.inspect(notes))
  end

  local function wait_claude(n)
    wait_for(n .. " claude run(s)", function()
      local calls = fakes.calls("claude")
      return #calls >= n and calls[n].done
    end)
    vim.wait(100) -- let on_exit run
  end

  local function prompts()
    return vim.tbl_filter(function(c)
      return c.argv[1] == "agent" and c.argv[2] == "prompt"
    end, fakes.calls("herdr"))
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

  ---The window output() opened: a new window that shows `text`.
  local function output_win(before, text)
    local found
    wait_for("an output window showing " .. text, function()
      for _, w in ipairs(new_wins(before)) do
        if win_text(w):find(text, 1, true) then
          found = w
          return true
        end
      end
      return false
    end)
    return found
  end

  describe("exports", function()
    it("are exactly setup, register_target, poke, progress, pick, output, chat, stop, status, lines", function()
      local fns = {}
      for k, v in pairs(require("agent-poke")) do
        if type(v) == "function" then
          fns[#fns + 1] = k
        end
      end
      table.sort(fns)
      assert.are.same({ "chat", "lines", "output", "pick", "poke", "progress", "register_target", "setup", "status", "stop" }, fns)
    end)
  end)

  describe("poke", function()
    it("goes to the herdr pane that was picked", function()
      ap.setup({ targets = { "herdr" }, isolate = false }) -- typed into the pane, not forked
      local d, root = new_dir(), new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", d), pane(OWN, "This nvim", d) })
      choose = "Review PR"
      ap.pick(root)
      wait_for("the picked target", function()
        return state.get(root).target ~= nil
      end)
      choose = nil
      ap.poke(root, "hello agent")
      wait_for("a herdr prompt", function()
        return #prompts() >= 1
      end)
      vim.wait(200)
      assert.are.same({ "agent", "prompt", "w1:p1", "hello agent" }, prompts()[1].argv)
      assert.are.equal(0, #fakes.calls("claude"))
      assert.are.equal(1, selects)
    end)

    it("goes to the background agent when herdr is not there", function()
      vim.env.HERDR_SOCKET_PATH = nil
      local root = new_dir()
      ap.poke(root, "hello background")
      wait_claude(1)
      local run = fakes.calls("claude")[1]
      assert.are.equal("hello background", arg_after(run.argv, "-p"))
      assert.are.equal(root, run.cwd)
      assert.are.equal(0, #prompts())
    end)

    it("goes to the background agent when it was picked", function()
      local d, root = new_dir(), new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", d) })
      choose = "(background)"
      ap.pick(root)
      wait_for("the picked target", function()
        return state.get(root).target ~= nil
      end)
      ap.poke(root, "hello picked background")
      wait_claude(1)
      assert.are.equal("hello picked background", arg_after(fakes.calls("claude")[1].argv, "-p"))
      assert.are.equal(0, #prompts())
    end)
  end)

  describe("output", function()
    it("shows the last run's streamed text, rendered, and closes on a second call", function()
      ap.setup({ agent = "headless" })
      local root = new_dir()
      ap.poke(root, "say something")
      wait_claude(1)

      local before = vim.api.nvim_list_wins()
      ap.output(root)
      local w = output_win(before, "line one from fake")
      local text = win_text(w)
      assert.is_truthy(text:find("line two from fake", 1, true), text)
      assert.is_falsy(text:find('{"type"', 1, true), "raw stream-json shown:\n" .. text)

      ap.output(root)
      wait_for("the output window to close", function()
        return not vim.api.nvim_win_is_valid(w)
      end)
      assert.are.same({}, new_wins(before))
    end)

    it("follows a run that is still in flight", function()
      ap.setup({ agent = "headless" })
      write(fakes.log .. "/gate", "")
      local root = new_dir()
      ap.poke(root, "say more")
      wait_for("the run to start", function()
        return #fakes.calls("claude") >= 1
      end)

      local before = vim.api.nvim_list_wins()
      ap.output(root)
      local w = output_win(before, "line one from fake")
      assert.is_falsy(win_text(w):find("after the gate from fake", 1, true))

      write(fakes.log .. "/release", "")
      wait_for("the later text in the same window", function()
        return win_text(w):find("after the gate from fake", 1, true) ~= nil
      end)
      wait_claude(1)
      ap.output(root)
      wait_for("the output window to close", function()
        return not vim.api.nvim_win_is_valid(w)
      end)
    end)
  end)

  describe("chat", function()
    it("opens a terminal running `claude --resume <stored id>` in root", function()
      ap.setup({ agent = "headless" })
      local root = new_dir()
      state.set(root, "session", { id = "sess-abc", agent = "claude" })

      local before = vim.api.nvim_list_wins()
      ap.chat(root)
      -- checked at once, before the fake's exit can close anything
      local terms = vim.tbl_filter(function(w)
        return vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "terminal"
      end, new_wins(before))
      assert.are.equal(1, #terms, "no terminal window; notes: " .. vim.inspect(notes))

      wait_claude(1)
      local run = fakes.calls("claude")[1]
      assert.are.same({ "--resume", "sess-abc" }, run.argv)
      assert.are.equal(root, run.cwd)
    end)

    it("opens nothing without a stored session", function()
      local root = new_dir()
      local before = vim.api.nvim_list_wins()
      ap.chat(root)
      vim.wait(200)
      assert.are.same({}, new_wins(before))
      assert.are.equal(0, #fakes.calls("claude"))
      assert.is_true(#notes >= 1)
    end)
  end)
end)
