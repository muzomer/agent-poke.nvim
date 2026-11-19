-- agent-poke_nvim-4kp: per-poke progress for background runs.
--
-- Interface (lua/agent-poke/init.lua):
--   ap.poke(root, prompt, opts?) -> status, id   -- status as before; id names this poke
--   ap.progress(id) -> stage, err                -- "sent"|"queued"|"working"|"done"|"failed"; nil for an unknown id
--   User autocmd "AgentPokeProgress", data = { id, root, stage, target } on each stage change
--
-- headless.spawn is replaced by a test double (documented as replaceable in
-- tests): it starts no process and hands the test each run's on_exit.
-- Assumptions: a started background poke is "working" at once (no "sent");
-- the background agent's events carry target = "background"; a stopped running
-- poke is "failed" with a reason; a poke that cannot start returns false, id;
-- the handle bound (last 100) is tested on finished runs only.
local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.fn.fnamemodify(d, ":p"):gsub("/$", ""))
end

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("agent-poke progress (background agent)", function()
  local ap, headless, old_state_home, old_notify, old_spawn, notes, spawns, roots, events, group

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    roots, spawns, events = {}, {}, {}
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
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
    group = vim.api.nvim_create_augroup("agent-poke-progress-spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "AgentPokeProgress",
      callback = function(ev)
        events[#events + 1] = vim.deepcopy(ev.data)
      end,
    })
  end)

  after_each(function()
    for _, r in ipairs(roots) do
      pcall(headless.stop, r)
    end
    headless.spawn = old_spawn
    pcall(vim.api.nvim_del_augroup_by_id, group)
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
  end)

  local function root()
    local r = new_root()
    roots[#roots + 1] = r
    return r
  end

  local function finish(i, code, stderr)
    spawns[i].on_exit(code or 0, stderr or "", nil)
  end

  local function stages_of(id)
    local out = {}
    for _, e in ipairs(events) do
      if type(e) == "table" and e.id == id then
        out[#out + 1] = e.stage
      end
    end
    return out
  end

  it("returns the status first and an id second; the id reports working, then done", function()
    local r = root()
    local status, id = ap.poke(r, "first")
    assert.are.equal("started", status)
    assert.is_not_nil(id)
    assert.are.equal("working", (ap.progress(id)))
    finish(1)
    local stage, err = ap.progress(id)
    assert.are.equal("done", stage)
    assert.is_nil(err)
  end)

  it("a run that fails reports failed with the error", function()
    local r = root()
    local _, id = ap.poke(r, "first")
    finish(1, 1, "boom")
    local stage, err = ap.progress(id)
    assert.are.equal("failed", stage)
    assert.is_truthy(err and tostring(err) ~= "", "no error for a failed run")
  end)

  it("a queued poke goes queued -> working -> done", function()
    local r = root()
    local _, a = ap.poke(r, "first")
    local status, b = ap.poke(r, "second")
    assert.are.equal("queued", status)
    assert.is_not_nil(b)
    assert.are.equal("queued", (ap.progress(b)))
    finish(1)
    assert.are.equal("done", (ap.progress(a)))
    assert.are.equal(2, #spawns)
    assert.are.equal("working", (ap.progress(b)))
    finish(2)
    assert.are.equal("done", (ap.progress(b)))
  end)

  it("a queued poke dropped by the queue limit is failed with a reason", function()
    local r = root()
    ap.poke(r, "running")
    local ids = {}
    for i = 1, 11 do
      local _, id = ap.poke(r, "waiting " .. i)
      ids[i] = id
    end
    local stage, err = ap.progress(ids[1])
    assert.are.equal("failed", stage)
    assert.is_truthy(err and tostring(err) ~= "", "no reason for the dropped poke")
    assert.are.equal("queued", (ap.progress(ids[2])))
    assert.are.equal("queued", (ap.progress(ids[11])))
  end)

  it("stop() fails the running and the queued pokes with a reason", function()
    local r = root()
    local _, a = ap.poke(r, "running")
    local _, b = ap.poke(r, "waiting 1")
    local _, c = ap.poke(r, "waiting 2")
    ap.stop(r)
    local ids = { a, b, c }
    for i = 1, 3 do
      local id = ids[i]
      assert.is_not_nil(id, "poke " .. i .. " returned no id")
      local stage, err = ap.progress(id)
      assert.are.equal("failed", stage)
      assert.is_truthy(err and tostring(err) ~= "", "no reason for a stopped/cancelled poke")
    end
    -- the stopped run's late exit does not change it
    finish(1)
    assert.are.equal("failed", (ap.progress(a)))
  end)

  it("a poke that cannot start (missing agent command) is failed with the error", function()
    headless.spawn = old_spawn -- the real spawn: vim.system throws for a missing command, nothing runs
    ap.config.headless.cmd = vim.fn.tempname() .. "/no-such-agent"
    local r = root()
    local status, id = ap.poke(r, "first")
    assert.are.equal(false, status)
    assert.is_not_nil(id)
    local stage, err = ap.progress(id)
    assert.are.equal("failed", stage)
    assert.is_truthy(err and tostring(err) ~= "", "no error for a failed start")
  end)

  it("an unknown id returns nil", function()
    assert.is_nil(ap.progress("no-such-id"))
    assert.is_nil(ap.progress(nil))
  end)

  it("ids are unique per poke, across roots", function()
    local r1, r2 = root(), root()
    local seen = {}
    local ids = {}
    local _, a = ap.poke(r1, "one")
    local _, b = ap.poke(r1, "two") -- queued
    local _, c = ap.poke(r2, "three")
    finish(1)
    finish(2)
    local _, d = ap.poke(r1, "four")
    ids = { a, b, c, d }
    for i = 1, 4 do
      local id = ids[i]
      assert.is_not_nil(id, "poke " .. i .. " returned no id")
      assert.is_nil(seen[id], "id used twice: " .. tostring(id))
      seen[id] = true
    end
  end)

  it("keeps at most the last 100 handles", function()
    local r = root()
    local ids = {}
    for i = 1, 120 do
      local status, id = ap.poke(r, "poke " .. i)
      assert.are.equal("started", status)
      ids[i] = id
      finish(#spawns)
    end
    for i = 1, 20 do
      assert.is_nil(ap.progress(ids[i]), "handle " .. i .. " should be forgotten")
    end
    for i = 21, 120 do
      assert.are.equal("done", (ap.progress(ids[i])), "handle " .. i .. " should be kept")
    end
  end)

  it("fires User AgentPokeProgress on each stage change with { id, root, stage, target }", function()
    local r = root()
    local _, a = ap.poke(r, "first")
    local _, b = ap.poke(r, "second")
    finish(1)
    finish(2)
    assert.is_true(vim.wait(1000, function()
      local s = stages_of(b)
      return #s >= 3 and s[#s] == "done"
    end, 10), "events: " .. vim.inspect(events))
    assert.are.same({ "queued", "working", "done" }, stages_of(b))
    local sa = stages_of(a)
    assert.are.same({ "working", "done" }, { sa[#sa - 1], sa[#sa] })
    for _, id in ipairs({ a, b }) do
      local s = stages_of(id)
      for i = 2, #s do
        assert.are_not.equal(s[i - 1], s[i], "event without a stage change: " .. vim.inspect(s))
      end
    end
    for _, e in ipairs(events) do
      if e.id == a or e.id == b then
        assert.are.equal(r, e.root)
        assert.are.equal("background", e.target)
      end
    end
  end)

  it("fires failed for a dropped queued poke", function()
    local r = root()
    ap.poke(r, "running")
    local first
    for i = 1, 11 do
      local _, id = ap.poke(r, "waiting " .. i)
      first = first or id
    end
    assert.is_true(vim.wait(1000, function()
      local s = stages_of(first)
      return s[#s] == "failed"
    end, 10), "events: " .. vim.inspect(events))
  end)

  it("passes already: callers that ignore the return value keep working", function()
    local r = root()
    ap.poke(r, "first")
    assert.are.equal(1, #spawns)
    assert.are.equal("working", ap.status(r).status)
  end)
end)
