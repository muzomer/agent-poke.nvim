-- agent-poke_nvim-wtd.3, review findings: the background agent's run state
-- after non-fatal error events and after a failing state write in the exit
-- callback.
--
-- headless.spawn is replaced by a test double (it is documented as replaceable
-- in tests): it starts no process and hands the test the run's on_line and
-- on_exit callbacks, so the test drives the agent's output and its exit.
local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.fn.fnamemodify(d, ":p"):gsub("/$", ""))
end

describe("agent-poke.headless review findings", function()
  local headless, state, old_state_home, old_notify, old_spawn, old_set, notes, spawns, roots

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    roots = {}
    spawns = {}
    package.loaded["agent-poke.state"] = nil
    package.loaded["agent-poke.headless"] = nil
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
    old_set = state.set
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
    state.set = old_set
    for _, r in ipairs(roots) do
      pcall(headless.stop, r)
    end
    headless.spawn = old_spawn
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    require("agent-poke").setup({})
  end)

  local function root()
    local r = new_root()
    roots[#roots + 1] = r
    return r
  end

  local function errors()
    return vim.tbl_filter(function(n)
      return n.level == vim.log.levels.ERROR
    end, notes)
  end

  local function line(t)
    return vim.json.encode(t)
  end

  -- finding headless.lua:262: a non-fatal error event before a successful end
  it("gemini: a transient 'error' event followed by a successful result and exit 0 is not a failure", function()
    require("agent-poke").setup({ headless = { agent = "gemini" } })
    local r = root()
    assert.is_true(headless.poke(r, "first prompt"))
    assert.are.same(1, #spawns)
    local s = spawns[1]
    s.on_line(line({ type = "init", session_id = "gem-1" }))
    s.on_line(line({ type = "error", message = "rate limited, retrying" }))
    s.on_line(line({ type = "result", status = "success" }))
    s.on_exit(0, "", 0)
    assert.are.same({}, errors(), "run reported as failed: " .. vim.inspect(notes))
  end)

  it("codex: a transient 'error' event followed by turn.completed and exit 0 is not a failure", function()
    require("agent-poke").setup({ headless = { agent = "codex" } })
    local r = root()
    assert.is_true(headless.poke(r, "first prompt"))
    assert.are.same(1, #spawns)
    local s = spawns[1]
    s.on_line(line({ type = "thread.started", thread_id = "codex-1" }))
    s.on_line(line({ type = "error", message = "stream disconnected, reconnecting" }))
    s.on_line(line({ type = "turn.completed" }))
    s.on_exit(0, "", 0)
    assert.are.same({}, errors(), "run reported as failed: " .. vim.inspect(notes))
  end)

  -- finding headless.lua:284: forget(root) throwing inside the exit callback
  it("a lost session whose state write throws in the exit callback does not leave the root stuck in 'working'", function()
    require("agent-poke").setup({ headless = { agent = "claude" } })
    local r = root()
    state.set(r, "session", { id = "gone-session", agent = "claude" })
    assert.is_true(headless.poke(r, "first prompt"))
    assert.are.same(1, #spawns)
    -- the state write fails (e.g. a state-lock timeout) while the session is forgotten
    state.set = function()
      error("agent-poke: timed out waiting for state lock", 0)
    end
    pcall(spawns[1].on_exit, 1, "Error: No conversation found with session ID: gone-session", 0)
    state.set = old_set
    local n = #spawns
    -- the run must have left 'working': this poke starts a run instead of being queued
    assert.is_true(headless.poke(r, "next prompt"), "the poke was queued: the root is stuck in 'working'")
    assert.are.same(n + 1, #spawns)
    assert.is_truthy(vim.tbl_contains(spawns[#spawns].args, "next prompt"), vim.inspect(spawns[#spawns].args))
  end)
end)
