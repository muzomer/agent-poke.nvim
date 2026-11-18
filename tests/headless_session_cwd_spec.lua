-- agent-poke_nvim-suq: a session resumes in the directory it was started in.
--
-- Interface (lua/agent-poke/headless.lua, lua/agent-poke/state.lua):
--   headless.poke(root, prompt, { cwd? }) -- a new session starts in opts.cwd (else root)
--   state.get(root).session = { id, agent, cwd } -- cwd: where the session started
--   a resumed session (poke or chat) runs in its stored cwd.
-- Legacy code-review.nvim sessions (<root>/.code-review/headless.json) resume in
-- code-review's workdir: the `repo` of <root>/.code-review/session.json when its
-- kind is "commits", else root. A lost legacy session whose workdir is unknown
-- (no session.json) is reported once with vim.notify, not silently replaced.
--
-- Fake `claude` (test double, defined here, first on PATH): records argv and
-- `pwd -P` per call. With -p it prints stream-json and exits 0, except when the
-- id given to --resume is listed in <log>/lost: then it prints an error result
-- "No conversation found with session ID: <id>" and exits 1. Without -p
-- (interactive chat) it exits at once.
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

local function arg_after(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

local FAKE = [[#!/bin/sh
log="%s"
n=$(cat "$log/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/n"
d="$log/$n"; mkdir -p "$d"
: > "$d/argv.tmp"
for a in "$@"; do printf '%%s\0' "$a" >> "$d/argv.tmp"; done
mv "$d/argv.tmp" "$d/argv"
pwd -P > "$d/cwd"
sid=fake-session; prev=; p=; resume=
for a in "$@"; do
  if [ "$prev" = "--session-id" ]; then sid=$a; fi
  if [ "$prev" = "--resume" ]; then sid=$a; resume=$a; fi
  if [ "$a" = "-p" ]; then p=1; fi
  prev=$a
done
if [ -n "$p" ]; then
  if [ -n "$resume" ] && [ -f "$log/lost" ] && grep -qx "$resume" "$log/lost"; then
    printf '%%s\n' "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"result\":\"No conversation found with session ID: $resume\"}"
    echo "No conversation found with session ID: $resume" >&2
    touch "$d/done"
    exit 1
  fi
  printf '%%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
  printf '%%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
fi
touch "$d/done"
]]

local function install()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  write(bin .. "/claude", string.format(FAKE, log))
  uv.fs_chmod(bin .. "/claude", tonumber("755", 8))
  local old = vim.env.PATH
  vim.env.PATH = bin .. ":" .. old
  local self = { log = log }
  function self.count()
    return tonumber(vim.trim(read(log .. "/n") or "0")) or 0
  end
  function self.call(i)
    local d = log .. "/" .. i
    local raw = read(d .. "/argv")
    if not raw then
      return nil
    end
    local argv = {}
    for a in raw:gmatch("([^%z]*)%z") do
      argv[#argv + 1] = a
    end
    return { argv = argv, cwd = vim.trim(read(d .. "/cwd") or ""), done = read(d .. "/done") ~= nil }
  end
  function self.lose(id)
    local f = assert(io.open(log .. "/lost", "ab"))
    f:write(id .. "\n")
    f:close()
  end
  function self.all_done()
    for i = 1, self.count() do
      local c = self.call(i)
      if not (c and c.done) then
        return false
      end
    end
    return true
  end
  function self.restore()
    vim.env.PATH = old
  end
  return self
end

describe("agent-poke.headless session cwd", function()
  local headless, state, fake, old_state_home, old_notify, notes, roots

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    roots = {}
    require("agent-poke").config = require("agent-poke.defaults")()
    package.loaded["agent-poke.state"] = nil
    package.loaded["agent-poke.headless"] = nil
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
    fake = install()
  end)

  after_each(function()
    pcall(vim.cmd, "stopinsert")
    for _, r in ipairs(roots) do
      pcall(headless.stop, r)
    end
    vim.wait(5000, function()
      return fake.all_done()
    end, 20)
    fake.restore()
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    require("agent-poke").config = require("agent-poke.defaults")()
  end)

  local function root()
    local r = new_dir()
    roots[#roots + 1] = r
    return r
  end

  ---Wait until root's run has ended and `n` calls of the fake are done.
  local function settle(r, n)
    assert.is_true(vim.wait(10000, function()
      local s = headless.status(r)
      return fake.count() >= n and fake.all_done() and s ~= nil and s.status ~= "working"
    end, 20), string.format("runs did not settle (want %d calls, got %d); notes: %s", n, fake.count(), vim.inspect(notes)))
  end

  local function real(p)
    return p and uv.fs_realpath(p) or p
  end

  local function notes_naming(text)
    return vim.tbl_filter(function(n)
      return n.msg:find(text, 1, true) ~= nil
    end, notes)
  end

  it("a new session started with opts.cwd stores that cwd and later resumes there without opts.cwd", function()
    local r = root()
    local sub = new_dir()
    assert.is_true(headless.poke(r, "first", { cwd = sub }))
    settle(r, 1)
    assert.are.equal(sub, fake.call(1).cwd)
    local s = state.get(r).session
    assert.is_table(s)
    assert.are.equal(sub, real(s.cwd), "session cwd not stored: " .. vim.inspect(s))

    assert.is_true(headless.poke(r, "second"))
    settle(r, 2)
    local second = fake.call(2)
    assert.are.equal(s.id, arg_after(second.argv, "--resume"), vim.inspect(second.argv))
    assert.are.equal(sub, second.cwd, "resume did not run where the session started")
  end)

  it("a new session started without opts.cwd stores root as its cwd", function()
    local r = root()
    assert.is_true(headless.poke(r, "first"))
    settle(r, 1)
    local s = state.get(r).session
    assert.is_table(s)
    assert.are.equal(r, real(s.cwd), "session cwd not stored: " .. vim.inspect(s))
  end)

  it("a stored session resumes in its cwd even when the poke passes another cwd", function()
    local r = root()
    local sub = new_dir()
    local other = new_dir()
    state.set(r, "session", { id = "sess-sub", agent = "claude", cwd = sub })
    assert.is_true(headless.poke(r, "again", { cwd = other }))
    settle(r, 1)
    local c = fake.call(1)
    assert.are.equal("sess-sub", arg_after(c.argv, "--resume"), vim.inspect(c.argv))
    assert.are.equal(sub, c.cwd)
  end)

  it("chat opens the stored session in its cwd", function()
    local r = root()
    local sub = new_dir()
    state.set(r, "session", { id = "sess-chat", agent = "claude", cwd = sub })
    local before = vim.api.nvim_list_wins()
    headless.chat(r)
    assert.is_true(vim.wait(10000, function()
      return fake.count() >= 1 and fake.all_done()
    end, 20), "chat did not start the agent; notes: " .. vim.inspect(notes))
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not vim.tbl_contains(before, w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    local c = fake.call(1)
    assert.are.same({ "--resume", "sess-chat" }, c.argv)
    assert.are.equal(sub, c.cwd)
  end)

  describe("legacy code-review.nvim session", function()
    it("of a commits review resumes in the reviewed repo (session.json's repo)", function()
      local r = root()
      local repo = new_dir()
      write(r .. "/.code-review/headless.json", vim.json.encode({ session_id = "legacy-1", agent = "claude" }) .. "\n")
      write(r .. "/.code-review/session.json", vim.json.encode({ kind = "commits", repo = repo, range = "HEAD~2..HEAD" }))
      assert.is_true(headless.poke(r, "continue"))
      settle(r, 1)
      local c = fake.call(1)
      assert.are.equal("legacy-1", arg_after(c.argv, "--resume"), vim.inspect(c.argv))
      assert.are.equal(repo, c.cwd, "legacy commits session not resumed in its repo")
    end)

    it("of a plain project resumes in root", function()
      local r = root()
      write(r .. "/.code-review/headless.json", vim.json.encode({ session_id = "legacy-2", agent = "claude" }) .. "\n")
      assert.is_true(headless.poke(r, "continue"))
      settle(r, 1)
      local c = fake.call(1)
      assert.are.equal("legacy-2", arg_after(c.argv, "--resume"), vim.inspect(c.argv))
      assert.are.equal(r, c.cwd)
    end)

    it("that is lost and whose workdir is unknown is reported once, not silently replaced", function()
      local r = root()
      write(r .. "/.code-review/headless.json", vim.json.encode({ session_id = "legacy-lost", agent = "claude" }) .. "\n")
      fake.lose("legacy-lost")
      headless.poke(r, "continue")
      settle(r, 1)
      -- whatever happened next (a new session, or none), the run has ended
      vim.wait(3000, function()
        local s = headless.status(r)
        return fake.all_done() and s ~= nil and s.status ~= "working"
      end, 20)
      local n = fake.count()
      headless.poke(r, "and again")
      settle(r, n + 1)
      assert.are.equal(1, #notes_naming("legacy-lost"),
        "the lost legacy session was not reported exactly once; notes: " .. vim.inspect(notes))
    end)
  end)
end)
