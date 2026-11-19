-- agent-poke_nvim-4kp findings: run state must leave 'working'/'queued' on every
-- exit path, and a new target delivery must survive 100 live background handles.
--
-- state.get is replaced by a throwing double (as a legacy-state migration whose
-- lock times out or whose write fails); headless.spawn by a double that starts
-- no process and hands the test each run's on_exit.
local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.uv.fs_realpath(d) or d)
end

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("agent-poke progress findings", function()
  local ap, headless, state, old_get, old_state_home, old_notify, spawns, events, group

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    vim.notify = function() end
    spawns, events = {}, {}
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    headless = require("agent-poke.headless")
    state = require("agent-poke.state")
    old_get = state.get
    headless.spawn = function(args, cwd, on_line, on_exit)
      local s = { args = args, cwd = cwd, on_line = on_line, on_exit = on_exit }
      spawns[#spawns + 1] = s
      return { kill = function() end }
    end
    group = vim.api.nvim_create_augroup("agent-poke-progress-findings-spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "AgentPokeProgress",
      callback = function(ev)
        events[#events + 1] = vim.deepcopy(ev.data)
      end,
    })
  end)

  after_each(function()
    state.get = old_get
    pcall(headless.stop_all)
    pcall(vim.api.nvim_del_augroup_by_id, group)
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
  end)

  local function throwing_state()
    state.get = function()
      error("could not migrate the legacy state: lock timed out")
    end
  end

  local function flush()
    vim.wait(50, function()
      return false
    end)
  end

  -- the poke's id: its return value, else (it threw) the first event of root
  local function poke_id(r, ok, a, b, c)
    if ok then
      return c
    end
    flush()
    for _, e in ipairs(events) do
      if e.root == r then
        return e.id
      end
    end
  end

  it("a poke whose start throws in state.get ends 'failed', not 'working'", function()
    local r = new_root()
    throwing_state()
    local ok, a, b, c = pcall(headless.poke, r, "hello")
    local id = poke_id(r, ok, a, b, c)
    assert.is_not_nil(id, "no handle was created for the poke")
    local stage, err = ap.progress(id)
    assert.are.equal("failed", stage)
    assert.is_not_nil(err)
    assert.are_not.equal("working", headless.status(r) and headless.status(r).status)
  end)

  it("a poke whose session_cwd throws ends 'failed', not 'working'", function()
    local r = new_root()
    headless.session_id = function()
      return "saved-session"
    end
    headless.session_cwd = function()
      error("could not migrate the legacy state: write failed")
    end
    local ok, a, b, c = pcall(headless.poke, r, "hello")
    local id = poke_id(r, ok, a, b, c)
    assert.is_not_nil(id, "no handle was created for the poke")
    local stage, err = ap.progress(id)
    assert.are.equal("failed", stage)
    assert.is_not_nil(err)
  end)

  it("pokes queued behind a fork run do not stay 'queued' when their start throws", function()
    local r = new_root()
    local _, status, fork_id = headless.poke(r, "fork it", { fork = { id = "other-session", cwd = r } })
    assert.are.equal("started", status)
    local ids = {}
    for i = 1, 3 do
      local _, st, id = headless.poke(r, "next " .. i)
      assert.are.equal("queued", st)
      ids[#ids + 1] = id
    end
    assert.are.equal(1, #spawns)
    throwing_state()
    spawns[1].on_exit(0, "", 0)
    flush()
    assert.are.equal("done", (ap.progress(fork_id)))
    for i, id in ipairs(ids) do
      local stage = ap.progress(id)
      assert.are_not.equal("queued", stage, "queued poke " .. i .. " stays queued forever")
      if stage == "working" then
        assert.is_true(#spawns > 1, "queued poke " .. i .. " is 'working' but no run was started")
      else
        assert.are.equal("failed", stage)
      end
    end
  end)

  it("a target delivery is tracked even with 100 live background runs", function()
    for _ = 1, 100 do
      local _, st = headless.poke(new_root(), "busy")
      assert.are.equal("started", st)
    end
    ap.setup({
      targets = {
        {
          name = "fake",
          list = function()
            return { { id = "e1", title = "Entry one" } }
          end,
          deliver = function()
            return "typed"
          end,
        },
      },
    })
    local r = new_root()
    state.set(r, "target", { target = "fake", id = "e1" })
    local ok, status, id = pcall(ap.poke, r, "hello")
    assert.is_true(ok, "poke threw: " .. tostring(status))
    assert.are.equal("typed", status)
    assert.is_not_nil(id)
    local pok, stage = pcall(ap.progress, id)
    assert.is_true(pok, "progress threw: " .. tostring(stage))
    assert.are.equal("sent", stage)
  end)
end)
