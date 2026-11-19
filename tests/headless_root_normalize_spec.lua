-- agent-poke_nvim-5h5 (nit 1): runs, chats and the FIFO queue of the background
-- agent use the normalized root (trailing slashes removed, symlinks resolved, as
-- in agent-poke.state), so /a/b, /a/b/ and a symlink to /a/b share one run and
-- one queue and never resume the same session at once.
--
-- Runs use a slow fake `claude` (test double built on tests/helpers.install_fakes)
-- that appends "start N" / "end N" to <log>/events and sleeps <log>/delay
-- seconds in between. The chat test replaces headless.spawn (documented as
-- replaceable in tests) as in tests/headless_chat_poke_spec.lua.
local helpers = require("tests.helpers")

local uv = vim.uv or vim.loop

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return assert(uv.fs_realpath(d))
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

local SLOW_BODY = [[
echo $$ > "$d/pid"
echo "start $n" >> "$log/events"
sid=fake-session; prev=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  prev=$a
done
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
delay=$(cat "$log/delay" 2>/dev/null || echo 0)
trap 'kill $! 2>/dev/null; echo "killed $n" >> "$log/events"; exit 143' TERM
sleep "$delay" &
echo $! > "$d/sleep_pid"
wait $!
echo "end $n" >> "$log/events"
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
]]

describe("agent-poke.headless with different spellings of one root", function()
  local headless, fakes, old_state_home, old_notify, notes, roots

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    roots = {}
    package.loaded["agent-poke.state"] = nil
    package.loaded["agent-poke.headless"] = nil
    require("agent-poke").config = require("agent-poke.defaults")()
    headless = require("agent-poke.headless")
  end)

  after_each(function()
    for _, r in ipairs(roots) do
      pcall(headless.stop, r)
    end
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    require("agent-poke").config = require("agent-poke.defaults")()
  end)

  local function root()
    local r = new_root()
    roots[#roots + 1] = r
    return r
  end

  describe("with a slow fake claude", function()
    before_each(function()
      fakes = helpers.install_fakes({ bodies = { claude = SLOW_BODY } })
    end)

    after_each(function()
      for _, r in ipairs(roots) do
        pcall(headless.stop, r)
      end
      fakes.restore()
      local n = #fakes.calls("claude")
      for i = 1, n do
        for _, f in ipairs({ "pid", "sleep_pid" }) do
          local pid = tonumber(vim.trim(read(fakes.log .. "/claude." .. i .. "/" .. f) or ""))
          if pid then
            pcall(uv.kill, pid, "sigkill")
          end
        end
      end
    end)

    local function events()
      local out = {}
      for l in (read(fakes.log .. "/events") or ""):gmatch("[^\n]+") do
        out[#out + 1] = l
      end
      return out
    end

    local function set_delay(secs)
      write(fakes.log .. "/delay", tostring(secs))
    end

    local function wait_events(n)
      assert(vim.wait(10000, function()
        return #events() >= n
      end, 20), "timed out waiting for " .. n .. " events: " .. vim.inspect(events()) .. "; notes: " .. vim.inspect(notes))
    end

    ---Poke through `first`, then through `second` while the first run is busy:
    ---the second waits in the same queue and runs after the first.
    local function assert_serialized(first, second)
      set_delay(1)
      local s1, how1 = headless.poke(first, "prompt one")
      assert.is_true(s1, "notes: " .. vim.inspect(notes))
      assert.are.equal("started", how1)
      wait_events(1)

      local s2, how2 = headless.poke(second, "prompt two")
      assert.is_false(s2, "the second spelling started its own run at once")
      assert.are.equal("queued", how2, "the second spelling was not queued behind the first run")

      vim.wait(300)
      assert.are.equal(1, #fakes.calls("claude"), "two runs of one root at once: " .. vim.inspect(events()))

      wait_events(4)
      assert.are.same({ "start 1", "end 1", "start 2", "end 2" }, events())
      assert.are.equal(2, #fakes.calls("claude"))
    end

    it("pokes through /a/b and /a/b/ run one after the other, not at once", function()
      local r = root()
      assert_serialized(r, r .. "/")
    end)

    it("pokes through /a/b/ and /a/b run one after the other, not at once", function()
      local r = root()
      roots[#roots + 1] = r .. "/"
      assert_serialized(r .. "/", r)
    end)

    it("pokes through /a/b and a symlink to it run one after the other, not at once", function()
      local r = root()
      local link = vim.fn.tempname()
      assert(uv.fs_symlink(r, link))
      roots[#roots + 1] = link
      assert_serialized(r, link)
    end)

    it("stop() through /a/b/ stops the run started through /a/b", function()
      local r = root()
      set_delay(30)
      assert.is_true((headless.poke(r, "long prompt")), "notes: " .. vim.inspect(notes))
      wait_events(1)
      assert.are.equal("working", (headless.status(r .. "/") or {}).status,
        "status() through /a/b/ does not see the run of /a/b")

      assert.is_true(headless.stop(r .. "/"), "stop() through /a/b/ found no run")
      assert.are.equal("stopped", (headless.status(r) or {}).status)
      local pid = tonumber(vim.trim(read(fakes.log .. "/claude.1/pid") or ""))
      assert.is_not_nil(pid, "the fake claude recorded no pid")
      assert.is_true(vim.wait(5000, function()
        return not pcall(function()
          assert(uv.kill(pid, 0) == 0)
        end)
      end, 20), "the run's process is still alive after stop() through /a/b/")
      assert.is_nil(vim.tbl_contains(events(), "end 1") or nil, "the run ended on its own: " .. vim.inspect(events()))
    end)
  end)

  describe("with an open chat", function()
    local old_spawn, spawns, chat

    before_each(function()
      fakes = helpers.install_fakes() -- the chat's claude reads the pty: it stays open
      spawns = {}
      old_spawn = headless.spawn
      headless.spawn = function(args, cwd, on_line, on_exit)
        spawns[#spawns + 1] = { args = args, cwd = cwd }
        return { kill = function() end }
      end
      vim.fn.setreg('"', "")
    end)

    after_each(function()
      if chat then
        pcall(vim.fn.jobstop, chat.job)
        pcall(vim.fn.jobwait, { chat.job }, 2000)
        pcall(vim.api.nvim_win_close, chat.win, true)
        pcall(vim.api.nvim_buf_delete, chat.buf, { force = true })
        vim.wait(100)
        chat = nil
      end
      vim.cmd("stopinsert")
      headless.spawn = old_spawn
      fakes.restore()
    end)

    it("a chat opened through /a/b refuses a poke through /a/b/ (prompt to the \" register)", function()
      local r = root()
      require("agent-poke.state").set(r, "session", { id = "sess-norm", agent = "claude" })
      local before = {}
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        before[w] = true
      end
      headless.chat(r)
      vim.cmd("stopinsert")
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if not before[w] and vim.bo[b].buftype == "terminal" then
          chat = { win = w, buf = b, job = vim.b[b].terminal_job_id }
        end
      end
      assert.is_not_nil(chat, "chat opened no terminal; notes: " .. vim.inspect(notes))
      assert.is_true(vim.wait(5000, function()
        return #fakes.calls("claude") >= 1
      end, 20), "the chat's fake claude never started")

      local started = headless.poke(r .. "/", "through the slash")
      assert.is_false(started, "a run was started on the session the chat has open")
      assert.are.equal(0, #spawns)
      assert.are.equal("through the slash", vim.fn.getreg('"'))
    end)
  end)
end)
