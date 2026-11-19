-- agent-poke_nvim-5h5 (nit 6): every notification of init.lua goes through the
-- shared helper agent-poke.util.notify (which adds the "agent-poke: " prefix),
-- including the unknown headless.agent error of setup() and the "no background
-- run to stop" notice of stop().
--
-- util.notify is wrapped by a spy before agent-poke is loaded (init.lua may keep
-- a local reference to it); the spy records the call and calls the real helper.
local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return assert(vim.uv.fs_realpath(d))
end

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("init.lua notifications", function()
  local ap, spied, notes, old_notify, old_state_home

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    unload()
    local util = require("agent-poke.util")
    local real = util.notify
    spied = {}
    util.notify = function(msg, level)
      spied[#spied + 1] = { msg = tostring(msg), level = level }
      return real(msg, level)
    end
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
  end)

  after_each(function()
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
  end)

  local function spied_with(text)
    for _, s in ipairs(spied) do
      if s.msg:find(text, 1, true) then
        return s
      end
    end
  end

  local function assert_single_prefix()
    for _, n in ipairs(notes) do
      assert.is_truthy(n.msg:find("^agent%-poke: "), "no prefix: " .. n.msg)
      assert.is_nil(n.msg:find("^agent%-poke: agent%-poke: "), "doubled prefix: " .. n.msg)
    end
  end

  it("setup() reports an unknown headless.agent through util.notify, at ERROR", function()
    ap.setup({ headless = { agent = "bogus-agent" } })
    local s = spied_with("unknown headless.agent")
    assert.is_not_nil(s, "util.notify was not used; vim.notify got: " .. vim.inspect(notes))
    assert.is_nil(s.msg:find("^agent%-poke: "), "the message passed to util.notify carries its own prefix: " .. s.msg)
    assert.is_truthy(s.msg:find("bogus-agent", 1, true), s.msg)
    assert.are.equal(vim.log.levels.ERROR, s.level)
    assert.are.equal(1, #notes, vim.inspect(notes))
    assert_single_prefix()
  end)

  it("stop() without a run says so through util.notify", function()
    ap.stop(new_root())
    local s = spied_with("no background run to stop")
    assert.is_not_nil(s, "util.notify was not used; vim.notify got: " .. vim.inspect(notes))
    assert.is_nil(s.msg:find("^agent%-poke: "), "the message passed to util.notify carries its own prefix: " .. s.msg)
    assert.are.equal(1, #notes, vim.inspect(notes))
    assert_single_prefix()
  end)
end)
