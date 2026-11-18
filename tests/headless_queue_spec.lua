-- agent-poke_nvim-ei4.1: pokes on a busy root wait in a FIFO queue (at most 10
-- waiting; beyond that the oldest waiting prompt is dropped with a one-line
-- notification), and stop(root) reports every cancelled prompt.
--
-- Interface (lua/agent-poke/headless.lua):
--   headless.poke(root, prompt, opts?) -> started, "started"|"queued"|false
--   headless.stop(root)                -> stopped (reports cancelled prompts)
--
-- headless.spawn is replaced by a test double (documented as replaceable in
-- tests): it starts no process and hands the test each run's on_exit, so the
-- test ends runs itself. The exit handler starts the next queued run at once.
local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.fn.fnamemodify(d, ":p"):gsub("/$", ""))
end

local function arg_after(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

describe("agent-poke.headless poke queue", function()
  local headless, old_state_home, old_notify, old_spawn, notes, spawns, roots

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    roots, spawns = {}, {}
    -- reset by reloading: setup() no longer resets the config
    package.loaded["agent-poke"] = nil
    package.loaded["agent-poke.state"] = nil
    package.loaded["agent-poke.headless"] = nil
    headless = require("agent-poke.headless")
    old_spawn = headless.spawn
    headless.spawn = function(args, cwd, on_line, on_exit)
      local s = { args = args, cwd = cwd, on_line = on_line, on_exit = on_exit, killed = false }
      spawns[#spawns + 1] = s
      return {
        kill = function()
          s.killed = true
        end,
      }
    end
  end)

  after_each(function()
    for _, r in ipairs(roots) do
      pcall(headless.stop, r)
    end
    headless.spawn = old_spawn
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    package.loaded["agent-poke"] = nil
  end)

  local function root()
    local r = new_root()
    roots[#roots + 1] = r
    return r
  end

  local function prompt_of(i)
    return arg_after(spawns[i].args, "-p")
  end

  -- end the newest run successfully; the next queued prompt starts at once
  local function finish_last()
    spawns[#spawns].on_exit(0, "", nil)
  end

  local function prompts()
    local out = {}
    for i = 1, #spawns do
      out[i] = prompt_of(i)
    end
    return out
  end

  it("pokes on a busy root run one after the other in the order they came (FIFO)", function()
    local r = root()
    assert.is_true((headless.poke(r, "prompt a")))
    for _, p in ipairs({ "prompt b", "prompt c", "prompt d" }) do
      local started, status = headless.poke(r, p)
      assert.is_false(started)
      assert.are.equal("queued", status)
    end
    assert.are.equal(1, #spawns)
    for _ = 1, 3 do
      finish_last()
    end
    assert.are.same({ "prompt a", "prompt b", "prompt c", "prompt d" }, prompts())
    finish_last()
    assert.are.equal(4, #spawns, "a run started after the queue was empty")
  end)

  it("each queued poke keeps its own options: its own on_start fires when its own run starts", function()
    local r = root()
    local fired = {}
    local function opts(name)
      return {
        on_start = function()
          fired[#fired + 1] = name
        end,
      }
    end
    headless.poke(r, "prompt a", opts("a"))
    headless.poke(r, "prompt b", opts("b"))
    headless.poke(r, "prompt c", opts("c"))
    assert.are.same({ "a" }, fired)
    finish_last()
    assert.are.same({ "a", "b" }, fired)
    assert.are.equal("prompt b", prompt_of(2))
    finish_last()
    assert.are.same({ "a", "b", "c" }, fired)
    assert.are.equal("prompt c", prompt_of(3))
  end)

  it("a failed run still hands over to the next queued prompt, in order", function()
    local r = root()
    headless.poke(r, "prompt a")
    headless.poke(r, "prompt b")
    headless.poke(r, "prompt c")
    spawns[1].on_exit(1, "boom", nil)
    assert.are.equal(2, #spawns)
    assert.are.equal("prompt b", prompt_of(2))
    finish_last()
    assert.are.same({ "prompt a", "prompt b", "prompt c" }, prompts())
  end)

  it("keeps exactly 10 waiting prompts without dropping any", function()
    local r = root()
    headless.poke(r, "running")
    for i = 1, 10 do
      local _, status = headless.poke(r, "q" .. i)
      assert.are.equal("queued", status)
    end
    for _, n in ipairs(notes) do
      assert.is_nil(n.msg:lower():find("drop", 1, true), "a prompt was dropped at 10 waiting: " .. n.msg)
      assert.is_nil(n.msg:lower():find("discard", 1, true), "a prompt was dropped at 10 waiting: " .. n.msg)
    end
    for _ = 1, 10 do
      finish_last()
    end
    local want = { "running" }
    for i = 1, 10 do
      want[#want + 1] = "q" .. i
    end
    assert.are.same(want, prompts())
  end)

  it("an 11th waiting prompt drops the oldest waiting one, with a one-line notification", function()
    local r = root()
    local q1_started = false
    headless.poke(r, "running")
    headless.poke(r, "q1", {
      on_start = function()
        q1_started = true
      end,
    })
    for i = 2, 10 do
      headless.poke(r, "q" .. i)
    end
    local before = #notes
    local _, status = headless.poke(r, "q11")
    assert.are.equal("queued", status)
    local drops = {}
    for i = before + 1, #notes do
      local m = notes[i].msg:lower()
      if m:find("drop", 1, true) or m:find("discard", 1, true) then
        drops[#drops + 1] = notes[i].msg
      end
    end
    assert.are.equal(1, #drops, "want one drop notification, got: " .. vim.inspect(vim.list_slice(notes, before + 1)))
    assert.is_nil(drops[1]:find("\n", 1, true), "the drop notification is not one line: " .. drops[1])
    for _ = 1, 11 do
      finish_last()
    end
    local want = { "running" }
    for i = 2, 11 do
      want[#want + 1] = "q" .. i
    end
    assert.are.same(want, prompts())
    assert.is_false(q1_started, "the dropped prompt's on_start ran")
  end)

  it("stop(root) reports every cancelled prompt and none of them runs", function()
    local r = root()
    headless.poke(r, "running")
    local queued = { "queued-alpha", "queued-bravo", "queued-charlie" }
    for _, p in ipairs(queued) do
      headless.poke(r, p)
    end
    local before = #notes
    assert.is_true(headless.stop(r))
    assert.is_true(spawns[1].killed)
    local text = {}
    for i = before + 1, #notes do
      text[#text + 1] = notes[i].msg
    end
    local all = table.concat(text, "\n")
    assert.is_truthy(all:lower():find("cancel", 1, true), "no cancel report: " .. all)
    local names_all = true
    for _, p in ipairs(queued) do
      if not all:find(p, 1, true) then
        names_all = false
      end
    end
    local counts = all:find("%f[%d]3%f[%D]") ~= nil
    assert.is_true(names_all or counts, "stop did not report all 3 cancelled prompts: " .. all)
    -- the run's exit after the kill must not start any of them
    spawns[1].on_exit(143, "", 15)
    assert.are.equal(1, #spawns, "a cancelled prompt ran after stop")
    -- and the root takes a fresh poke at once
    assert.is_true((headless.poke(r, "after stop")))
    assert.are.equal("after stop", prompt_of(2))
  end)
end)
