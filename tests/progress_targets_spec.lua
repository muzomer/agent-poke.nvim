-- agent-poke_nvim-4kp: per-poke progress for target deliveries.
--
-- Target interface: deliver(root, entry, prompt, opts, ctx) -> status, err, handle?;
-- an optional progress(handle) -> stage?, err? reports how a delivered prompt
-- is doing. Core asks it only when ap.progress(id) is called (core never polls);
-- without it, or when it returns nil, a delivered prompt stays "sent".
--
-- Assumptions: the target's progress is called with a non-nil handle (what it
-- is - deliver's third value or core's own - is the implementation's choice);
-- a failed delivery is "failed" with an error; a delivery fires
-- AgentPokeProgress with stage "sent" and the target's name; a change seen by
-- ap.progress(id) fires the event too.
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

describe("agent-poke progress (targets)", function()
  local ap, state, old_state_home, old_notify, notes, events, group, script, handles

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes, events, handles = {}, {}, {}
    script = { stage = "sent" }
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    group = vim.api.nvim_create_augroup("agent-poke-progress-targets-spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "AgentPokeProgress",
      callback = function(ev)
        events[#events + 1] = vim.deepcopy(ev.data)
      end,
    })
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
  end)

  local function list()
    return { { id = "e1", title = "Entry one" } }
  end

  local function with_progress()
    return {
      name = "fake",
      list = list,
      deliver = function()
        return "typed", nil, { n = #handles + 1 }
      end,
      progress = function(handle)
        handles[#handles + 1] = handle
        if script.throw then
          error("progress exploded")
        end
        return script.stage, script.err
      end,
    }
  end

  local function stored(name)
    local r = new_root()
    state.set(r, "target", { target = name, id = "e1" })
    return r
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

  it("maps the target's progress(handle) through", function()
    ap.setup({ targets = { with_progress() } })
    local r = stored("fake")
    local status, id = ap.poke(r, "hello")
    assert.are.equal("typed", status)
    assert.is_not_nil(id)
    assert.are.equal("sent", (ap.progress(id)))
    script.stage = "working"
    assert.are.equal("working", (ap.progress(id)))
    script.stage = "done"
    assert.are.equal("done", (ap.progress(id)))
    assert.is_true(#handles > 0, "the target's progress was never asked")
    for _, h in ipairs(handles) do
      assert.is_not_nil(h)
    end
  end)

  it("reports a failed stage and its error from the target", function()
    ap.setup({ targets = { with_progress() } })
    local r = stored("fake")
    local _, id = ap.poke(r, "hello")
    script.stage, script.err = "failed", "pane closed"
    local stage, err = ap.progress(id)
    assert.are.equal("failed", stage)
    assert.are.equal("pane closed", err)
  end)

  it("progress(handle) returning nil leaves the poke 'sent'", function()
    ap.setup({ targets = { with_progress() } })
    local r = stored("fake")
    local _, id = ap.poke(r, "hello")
    script.stage = nil
    assert.are.equal("sent", (ap.progress(id)))
  end)

  it("a target without progress stays 'sent'", function()
    ap.setup({
      targets = {
        { name = "plain", list = list, deliver = function()
          return "typed"
        end },
      },
    })
    local r = stored("plain")
    local status, id = ap.poke(r, "hello")
    assert.are.equal("typed", status)
    assert.is_not_nil(id)
    assert.are.equal("sent", (ap.progress(id)))
    vim.wait(50)
    assert.are.equal("sent", (ap.progress(id)))
  end)

  it("a throwing progress(handle) does not escape", function()
    ap.setup({ targets = { with_progress() } })
    local r = stored("fake")
    local _, id = ap.poke(r, "hello")
    script.throw = true
    local ok, stage = pcall(ap.progress, id)
    assert.is_true(ok, tostring(stage))
    assert.are.equal("sent", stage)
  end)

  it("a failed delivery is 'failed' with an error", function()
    ap.setup({
      targets = {
        { name = "broken", list = list, deliver = function()
          return false, "pane is gone"
        end },
      },
    })
    local r = stored("broken")
    local status, id = ap.poke(r, "hello")
    assert.are.equal(false, status)
    assert.is_not_nil(id)
    local stage, err = ap.progress(id)
    assert.are.equal("failed", stage)
    assert.is_truthy(err and tostring(err) ~= "", "no error for a failed delivery")
  end)

  it("ids of target deliveries are unique", function()
    ap.setup({ targets = { with_progress() } })
    local r = stored("fake")
    local _, a = ap.poke(r, "one")
    local _, b = ap.poke(r, "two")
    assert.is_not_nil(a)
    assert.is_not_nil(b)
    assert.are_not.equal(a, b)
  end)

  it("fires AgentPokeProgress 'sent' with the target's name on delivery, and the changes it sees", function()
    ap.setup({ targets = { with_progress() } })
    local r = stored("fake")
    local _, id = ap.poke(r, "hello")
    assert.is_true(vim.wait(1000, function()
      return #stages_of(id) >= 1
    end, 10), "events: " .. vim.inspect(events))
    local first
    for _, e in ipairs(events) do
      if e.id == id then
        first = first or e
      end
    end
    assert.are.equal("sent", first.stage)
    assert.are.equal(r, first.root)
    assert.are.equal("fake", first.target)
    script.stage = "done"
    ap.progress(id)
    assert.is_true(vim.wait(1000, function()
      local s = stages_of(id)
      return s[#s] == "done"
    end, 10), "events: " .. vim.inspect(events))
    local s = stages_of(id)
    for i = 2, #s do
      assert.are_not.equal(s[i - 1], s[i], "event without a stage change: " .. vim.inspect(s))
    end
  end)
end)
