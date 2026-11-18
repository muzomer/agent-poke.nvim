-- agent-poke_nvim-wtd.3: the background agent (start, resume, queue, stop).
--
-- Interface (lua/agent-poke/headless.lua):
--   headless.poke(root, prompt) -- run the background agent for root: start a
--                                  session, resume it later, queue while busy
--   headless.stop(root)         -- stop the running process; a queued prompt is
--                                  reported (vim.notify) as cancelled
-- The session is stored with agent-poke.state: state.get(root).session = { id, agent }.
local helpers = require("tests.helpers")

local REPO = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local uv = vim.uv or vim.loop

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.fn.fnamemodify(d, ":p"):gsub("/$", ""))
end

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
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function arg_after(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

-- A slow fake `claude` (test double): records argv, cwd and pids per call,
-- appends "start N" / "end N" to an events file, echoes the session id it was
-- given (--session-id / --resume, else "fake-session") in its stream-json and
-- sleeps <log>/delay seconds in between. It does not read stdin.
local SLOW = [[#!/bin/sh
log="%s"
n=$(cat "$log/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/n"
d="$log/$n"; mkdir -p "$d"
: > "$d/argv.tmp"
for a in "$@"; do printf '%%s\0' "$a" >> "$d/argv.tmp"; done
mv "$d/argv.tmp" "$d/argv"
pwd -P > "$d/cwd"
echo $$ > "$d/pid"
echo "start $n" >> "$log/events"
sid=fake-session; prev=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  prev=$a
done
printf '%%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
delay=$(cat "$log/delay" 2>/dev/null || echo 0)
trap 'kill $! 2>/dev/null; exit 143' TERM
sleep "$delay" &
echo $! > "$d/sleep_pid"
wait $!
echo "end $n" >> "$log/events"
printf '%%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
]]

local function install_slow()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  write(bin .. "/claude", string.format(SLOW, log))
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
    return { argv = argv, cwd = vim.trim(read(d .. "/cwd") or ""), pid = tonumber(vim.trim(read(d .. "/pid") or "")) }
  end
  function self.events()
    local out = {}
    for l in (read(log .. "/events") or ""):gmatch("[^\n]+") do
      out[#out + 1] = l
    end
    return out
  end
  function self.delay(secs)
    write(log .. "/delay", tostring(secs))
  end
  function self.cleanup()
    vim.env.PATH = old
    for i = 1, self.count() do
      for _, f in ipairs({ "pid", "sleep_pid" }) do
        local pid = tonumber(vim.trim(read(log .. "/" .. i .. "/" .. f) or ""))
        if pid then
          pcall(uv.kill, pid, "sigkill")
        end
      end
    end
  end
  return self
end

local function alive(pid)
  local ok = pcall(function()
    assert(uv.kill(pid, 0) == 0)
  end)
  return ok
end

describe("agent-poke.headless", function()
  local headless, state, old_state_home, old_notify, notes, roots

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    roots = {}
    require("agent-poke").setup({})
    package.loaded["agent-poke.state"] = nil
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
  end)

  after_each(function()
    if headless then
      for _, r in ipairs(roots) do
        pcall(headless.stop, r)
      end
    end
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
  end)

  local function root()
    local r = new_root()
    roots[#roots + 1] = r
    return r
  end

  describe("with the helpers' fake claude", function()
    local fake

    before_each(function()
      fake = helpers.install_fakes()
    end)

    after_each(function()
      fake.restore()
    end)

    it("first poke starts without --resume and stores the session id; the second resumes it", function()
      local r = root()
      headless.poke(r, "first prompt")
      local stored
      assert.is_true(vim.wait(10000, function()
        stored = (state.get(r).session or {}).id
        return #fake.calls("claude") >= 1 and stored ~= nil and fake.calls("claude")[1].argv[1] ~= nil
      end, 20), "first run did not start or store a session")
      local first = fake.calls("claude")[1].argv
      assert.is_nil(arg_after(first, "--resume"), vim.inspect(first))
      assert.are.same("-p", first[1])
      assert.are.same("stream-json", arg_after(first, "--output-format"))
      -- the id the stream reported, or the one claude was told to use (it echoes it back)
      assert.is_truthy(stored == "fake-session" or stored == arg_after(first, "--session-id"), tostring(stored))
      assert.are.same("claude", state.get(r).session.agent)

      headless.poke(r, "second prompt")
      local calls
      assert.is_true(vim.wait(10000, function()
        calls = fake.calls("claude")
        return #calls >= 2 and vim.tbl_contains(calls[2].argv, "--resume")
      end, 20), "second poke did not resume: " .. vim.inspect(fake.calls("claude")))
      assert.are.same(stored, arg_after(calls[2].argv, "--resume"))
      assert.is_nil(arg_after(calls[2].argv, "--session-id"))
      assert.are.same("second prompt", arg_after(calls[2].argv, "-p"))
    end)

    it("the session id survives a new nvim process (state file)", function()
      local r = root()
      headless.poke(r, "first prompt")
      local stored
      assert.is_true(vim.wait(10000, function()
        stored = (state.get(r).session or {}).id
        return stored ~= nil and #fake.calls("claude") >= 1 and read(fake.dir:gsub("/bin$", "/log") .. "/claude.1/stdin") ~= nil
      end, 20), "first run did not store a session")

      local log = fake.dir:gsub("/bin$", "/log")
      local script = vim.fn.tempname() .. ".lua"
      write(script, string.format(
        [[
local repo, root, log = %q, %q, %q
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
require("agent-poke.headless").poke(root, "from a new nvim")
local ok = vim.wait(15000, function()
  return io.open(log .. "/claude.2/stdin", "r") ~= nil
end, 20)
vim.wait(200)
os.exit(ok and 0 or 3)
]],
        REPO,
        r,
        log
      ))
      local res = vim.system({ "nvim", "--headless", "-u", "NONE", "-i", "NONE", "-l", script }, { text = true }):wait(30000)
      assert.are.same(0, res.code, "child nvim: " .. tostring(res.stderr) .. tostring(res.stdout))
      local calls = fake.calls("claude")
      assert.are.same(2, #calls)
      assert.are.same(stored, arg_after(calls[2].argv, "--resume"), vim.inspect(calls[2].argv))
      assert.are.same("from a new nvim", arg_after(calls[2].argv, "-p"))
    end)
  end)

  describe("with a slow fake claude", function()
    local slow

    before_each(function()
      slow = install_slow()
    end)

    after_each(function()
      slow.cleanup()
    end)

    it("two pokes in quick succession run one after the other, each with its own prompt, in root", function()
      local r = root()
      slow.delay(0.5)
      headless.poke(r, "first prompt")
      headless.poke(r, "second prompt")
      assert.is_true(vim.wait(15000, function()
        return vim.tbl_contains(slow.events(), "end 2")
      end, 20), "second run did not finish: " .. vim.inspect(slow.events()))
      assert.are.same({ "start 1", "end 1", "start 2", "end 2" }, slow.events())
      assert.are.same("first prompt", arg_after(slow.call(1).argv, "-p"))
      assert.are.same("second prompt", arg_after(slow.call(2).argv, "-p"))
      assert.are.same(uv.fs_realpath(r), slow.call(1).cwd)
      assert.are.same(uv.fs_realpath(r), slow.call(2).cwd)
    end)

    it("stop(root) terminates the running process and reports the queued prompt as cancelled", function()
      local r = root()
      slow.delay(30)
      headless.poke(r, "first prompt")
      assert.is_true(vim.wait(10000, function()
        return vim.tbl_contains(slow.events(), "start 1") and slow.call(1) ~= nil and slow.call(1).pid ~= nil
      end, 20), "first run did not start")
      headless.poke(r, "queued prompt")
      local pid = slow.call(1).pid
      assert.is_true(alive(pid))
      headless.stop(r)
      assert.is_true(vim.wait(5000, function()
        return not alive(pid)
      end, 20), "the running process was not terminated")
      assert.is_true(vim.wait(2000, function()
        return vim.iter(notes):any(function(n)
          return n.msg:lower():find("cancel", 1, true) ~= nil
        end)
      end, 20), "queued prompt not reported as cancelled: " .. vim.inspect(notes))
      vim.wait(1500)
      assert.are.same(1, slow.count(), "the queued prompt ran after stop")
      assert.is_false(vim.tbl_contains(slow.events(), "end 1"))
    end)
  end)
end)
