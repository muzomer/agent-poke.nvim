-- agent-poke_nvim-voz: poke(root, prompt, { tools = { ... } }) adds rules to
-- claude's --allowedTools for that run only (and the queued run that resumes
-- the session); other pokes are unaffected; setup's headless.extra_tools stay
-- and are merged without duplicates; backends without per-tool allow lists
-- (gemini, codex, opencode) ignore opts.tools; through a target (herdr, typed
-- or forked) opts.tools has no effect. The README documents opts.tools.
--
-- The fakes and harness below are copied from tests/poke_opts_spec.lua.
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
printf '%%s' "${AP_TEST_VAR-<unset>}" > "$d/ap_test_var"
printf '%%s' "${XDG_STATE_HOME-<unset>}" > "$d/xdg_state_home"
printf '%%s' "${PATH-<unset>}" > "$d/path"
%s
]]

local HERDR_BODY = [[
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  cat "$log/agents.json"
elif [ -f "$log/prompt_error" ]; then
  printf '%s\n' '{"error":{"code":"pane_not_found","message":"no such pane"}}'
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
if [ -f "$log/fail" ]; then
  echo "fake claude exploded" >&2
  touch "$d/done"
  exit 3
fi
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line one from fake"}]}}'
if [ -f "$log/gate" ]; then
  i=0
  while [ ! -f "$log/release" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
fi
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
touch "$d/done"
]]

local GEMINI_BODY = [[
printf '%s\n' '{"type":"init","session_id":"gem-1","model":"x"}'
printf '%s\n' '{"type":"message","role":"assistant","content":"ok"}'
printf '%s\n' '{"type":"result","status":"success"}'
touch "$d/done"
]]

local NAMES = { "herdr", "claude", "gemini" }

local function install()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  for name, body in pairs({ herdr = HERDR_BODY, claude = CLAUDE_BODY, gemini = GEMINI_BODY }) do
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
        list[#list + 1] = {
          argv = argv,
          cwd = vim.trim(read(d .. "/cwd") or ""),
          ap_test_var = read(d .. "/ap_test_var"),
          xdg_state_home = read(d .. "/xdg_state_home"),
          path = read(d .. "/path"),
          done = uv.fs_stat(d .. "/done") ~= nil,
        }
      end
    end
    return list
  end
  function self.agents(list)
    write(log .. "/agents.json", vim.json.encode({ result = { agents = list } }))
  end
  function self.flag(name)
    write(log .. "/" .. name, "")
  end
  return self
end

local OWN = "w1:p5" -- the pane this Neovim runs in

local function pane(id, title, cwd, session)
  return {
    pane_id = id,
    agent = "claude",
    agent_status = "idle",
    cwd = cwd,
    terminal_title_stripped = title,
    agent_session = session and { value = session } or nil,
  }
end

local function arg_after(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

---Values following each occurrence of `flag`, in order.
local function all_after(argv, flag)
  local out = {}
  for i, a in ipairs(argv) do
    if a == flag then
      out[#out + 1] = argv[i + 1]
    end
  end
  return out
end

describe("agent-poke poke() opts.tools", function()
  local ap, state, headless, fakes, notes, selects, choose
  local saved_env, old_notify, old_select

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
      AP_TEST_VAR = vim.env.AP_TEST_VAR,
    }
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    fakes = install()
    vim.env.PATH = fakes.bin .. ":/usr/bin:/bin"
    vim.env.HERDR_SOCKET_PATH = nil -- no herdr unless a test sets it
    vim.env.HERDR_PANE_ID = OWN
    vim.env.CLAUDE_CONFIG_DIR = new_dir()
    vim.env.AP_TEST_VAR = nil

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

    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
  end)

  after_each(function()
    if fakes then
      fakes.flag("release")
    end
    if headless then
      headless.stop_all()
    end
    if fakes then
      vim.wait(6000, function()
        for _, name in ipairs(NAMES) do
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

  local function wait_run(name, n)
    wait_for(n .. " " .. name .. " run(s)", function()
      local calls = fakes.calls(name)
      return #calls >= n and calls[n].done
    end)
    vim.wait(100) -- let on_exit run
  end

  local function wait_started(name, n)
    wait_for(n .. " " .. name .. " run(s) started", function()
      return #fakes.calls(name) >= n
    end)
  end

  local function prompts()
    return vim.tbl_filter(function(c)
      return c.argv[1] == "agent" and c.argv[2] == "prompt"
    end, fakes.calls("herdr"))
  end

  local function with_herdr()
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname() .. ".sock"
  end

  ---A Claude transcript of `session`, started in `dir`, under $CLAUDE_CONFIG_DIR.
  local function transcript(session, dir)
    local project = vim.env.CLAUDE_CONFIG_DIR .. "/projects/" .. dir:gsub("[^%w]", "-")
    write(project .. "/" .. session .. ".jsonl",
      vim.json.encode({ type = "user", cwd = dir, sessionId = session }) .. "\n")
  end

  ---The values of the --allowedTools flag (up to the next --flag), or nil without the flag.
  local function allowed(argv)
    for i, a in ipairs(argv) do
      if a == "--allowedTools" then
        local out = {}
        for j = i + 1, #argv do
          if argv[j]:sub(1, 2) == "--" then
            break
          end
          out[#out + 1] = argv[j]
        end
        return out
      end
    end
  end

  local function count(list, value)
    local n = 0
    for _, v in ipairs(list or {}) do
      if v == value then
        n = n + 1
      end
    end
    return n
  end

  local function has_arg(argv, value)
    return count(argv, value) > 0
  end

  local ASK = "Bash(beads-ask:*)"

  describe("claude", function()
    it("adds opts.tools to the default --allowedTools of that run", function()
      local root = new_dir()
      assert.are.equal("started", ap.poke(root, "hello", { tools = { ASK } }))
      wait_run("claude", 1)
      local argv = fakes.calls("claude")[1].argv
      local list = allowed(argv)
      assert.is_table(list, vim.inspect(argv))
      for _, t in ipairs({ "Read", "Grep", "Glob", ASK }) do
        assert.are.equal(1, count(list, t), t .. " in " .. vim.inspect(argv))
      end
      assert.are.equal("hello", arg_after(argv, "-p"))
    end)

    it("keeps headless.extra_tools and merges without duplicates", function()
      ap.setup({ headless = { extra_tools = { "Bash(bd:*)" } } })
      local root = new_dir()
      ap.poke(root, "hello", { tools = { "Bash(bd:*)", ASK, "Read", ASK } })
      wait_run("claude", 1)
      local argv = fakes.calls("claude")[1].argv
      local list = allowed(argv)
      assert.is_table(list, vim.inspect(argv))
      for _, t in ipairs({ "Read", "Grep", "Glob", "Bash(bd:*)", ASK }) do
        assert.are.equal(1, count(list, t), t .. " once in " .. vim.inspect(argv))
      end
    end)

    it("does not leak into the next poke of the same root (its resume)", function()
      local root = new_dir()
      ap.poke(root, "first", { tools = { ASK } })
      wait_run("claude", 1)
      ap.poke(root, "second")
      wait_run("claude", 2)
      local first, second = fakes.calls("claude")[1].argv, fakes.calls("claude")[2].argv
      assert.is_true(has_arg(first, ASK), vim.inspect(first))
      assert.is_truthy(arg_after(second, "--resume"), vim.inspect(second))
      assert.is_false(has_arg(second, ASK), vim.inspect(second))
      assert.are.same({ "Read", "Grep", "Glob" }, allowed(second))
    end)

    it("does not leak into pokes of other roots", function()
      ap.poke(new_dir(), "with tools", { tools = { ASK } })
      wait_run("claude", 1)
      ap.poke(new_dir(), "without tools")
      wait_run("claude", 2)
      local other = fakes.calls("claude")[2].argv
      assert.are.equal("without tools", arg_after(other, "-p"))
      assert.is_false(has_arg(other, ASK), vim.inspect(other))
    end)

    it("does not change the configured extra_tools", function()
      ap.setup({ headless = { extra_tools = { "Bash(bd:*)" } } })
      local root = new_dir()
      ap.poke(root, "hello", { tools = { ASK } })
      wait_run("claude", 1)
      assert.are.same({ "Bash(bd:*)" }, ap.config.headless.extra_tools)
      ap.poke(root, "again")
      wait_run("claude", 2)
      local second = fakes.calls("claude")[2].argv
      assert.are.same({ "Read", "Grep", "Glob", "Bash(bd:*)" }, allowed(second))
    end)

    it("applies to a queued poke when it resumes from the queue, and only to it", function()
      fakes.flag("gate")
      local root = new_dir()
      assert.are.equal("started", ap.poke(root, "first"))
      wait_started("claude", 1)
      assert.are.equal("queued", ap.poke(root, "second", { tools = { ASK } }))
      fakes.flag("release")
      wait_run("claude", 2)
      local first, second = fakes.calls("claude")[1].argv, fakes.calls("claude")[2].argv
      assert.is_false(has_arg(first, ASK), vim.inspect(first))
      assert.are.equal("second", arg_after(second, "-p"))
      assert.is_truthy(arg_after(second, "--resume"), vim.inspect(second))
      local list = allowed(second)
      assert.is_table(list, vim.inspect(second))
      assert.are.equal(1, count(list, ASK), vim.inspect(second))
      assert.are.equal(1, count(list, "Read"), vim.inspect(second))
    end)

    it("an empty tools list changes nothing (passes already)", function()
      local root = new_dir()
      ap.poke(root, "hello", { tools = {} })
      wait_run("claude", 1)
      assert.are.same({ "Read", "Grep", "Glob" }, allowed(fakes.calls("claude")[1].argv))
    end)
  end)

  describe("backends without per-tool allow lists", function()
    it("gemini ignores opts.tools and still runs (passes already)", function()
      ap.setup({ agent = "headless", headless = { agent = "gemini" } })
      local root = new_dir()
      assert.are.equal("started", ap.poke(root, "hello", { tools = { ASK } }))
      wait_run("gemini", 1)
      local argv = fakes.calls("gemini")[1].argv
      assert.is_false(has_arg(argv, ASK), vim.inspect(argv))
      assert.is_false(has_arg(argv, "--allowedTools"), vim.inspect(argv))
    end)

    it("codex and opencode build no tool flags from opts.tools (passes already)", function()
      local headless_mod = require("agent-poke.headless")
      for _, name in ipairs({ "codex", "opencode", "gemini" }) do
        ap.setup({ agent = "headless", headless = { agent = name } })
        local ok, argv = pcall(headless_mod.args, new_dir(), "hello", { new_id = "x", tools = { ASK } })
        assert.is_true(ok, name .. ": " .. tostring(argv))
        assert.is_false(has_arg(argv, ASK), name .. ": " .. vim.inspect(argv))
      end
    end)
  end)

  describe("through a target", function()
    it("a typed herdr poke is unchanged by opts.tools (passes already)", function()
      with_herdr()
      ap.setup({ targets = { "herdr" }, isolate = false })
      local root = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      state.set(root, "target", { target = "herdr", id = "w1:p1" })
      assert.are.equal("typed", ap.poke(root, "typed prompt", { tools = { ASK } }))
      wait_for("a herdr prompt", function()
        return #prompts() >= 1
      end)
      assert.are.same({ "agent", "prompt", "w1:p1", "typed prompt" }, prompts()[1].argv)
      assert.are.equal(0, #fakes.calls("claude"))
    end)

    it("a forked herdr poke does not get opts.tools (passes already)", function()
      with_herdr()
      ap.setup({ targets = { "herdr" }, isolate = "fork" })
      local sess_dir, root = new_dir(), new_dir()
      transcript("sess-123", sess_dir)
      fakes.agents({ pane("w1:p1", "Review PR", new_dir(), "sess-123") })
      state.set(root, "target", { target = "herdr", id = "w1:p1" })
      assert.are.equal("forked", ap.poke(root, "fork prompt", { tools = { ASK } }))
      wait_run("claude", 1)
      local argv = fakes.calls("claude")[1].argv
      assert.are.equal("sess-123", arg_after(argv, "--resume"))
      assert.is_false(has_arg(argv, ASK), vim.inspect(argv))
    end)
  end)

  describe("README", function()
    local readme = read(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/README.md") or ""

    it("documents opts.tools among the poke options", function()
      local s = readme:find("poke(root, prompt, opts)", 1, true)
      assert.is_truthy(s, "README lacks poke(root, prompt, opts)")
      local item = readme:find("\n%s*%- `tools`", s)
      assert.is_truthy(item, "README lacks a `tools` item in the poke options")
    end)

    it("says backends without per-tool allow lists ignore opts.tools", function()
      local item = readme:find("\n%s*%- `tools`")
      assert.is_truthy(item, "README lacks a `tools` item")
      local text = readme:sub(item, item + 400):lower()
      assert.is_truthy(text:find("ignore", 1, true), "the `tools` item does not say it is ignored elsewhere: " .. text)
    end)
  end)
end)
