-- herdr as a target: total blocking time of poke() through core.
-- Ported from herdr_deadline_spec and herdr_repick_deadline_spec, which called
-- the old herdr.poke directly (agent-poke_nvim-0d8.2 finding 1).
--   - stored pane: `agent list` then `agent prompt` share one deadline;
--   - poke({ pick = true }): at most TIMEOUT_MS before the picker opens, and
--     at most TIMEOUT_MS from the choice until poke() returns.
--
-- herdr.TIMEOUT_MS is shortened to 1500 ms. The fake `herdr` sleeps 1.3 s
-- (just under the timeout) before each answer, so two chained calls take ~2.6 s.
local F = require("tests.herdr_fakes")
local uv = vim.uv or vim.loop

local TIMEOUT = 1500
local SLACK = 400 -- ms allowed beyond TIMEOUT for process start and bookkeeping

local function ms_since(t0)
  return (uv.hrtime() - t0) / 1e6
end

describe("herdr target: poke() total blocking time", function()
  local h = F.harness({ delay = "1.3" })

  before_each(function()
    h.ap.setup({ targets = { "herdr" }, isolate = false })
    require("agent-poke.targets.herdr").TIMEOUT_MS = TIMEOUT -- the module is unloaded after each test
    h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
  end)

  it("stored pane: list + prompt together block at most TIMEOUT_MS", function()
    local r = F.new_dir()
    h.state.set(r, "target", { target = "herdr", id = "w1:p1" })
    local t0 = uv.hrtime()
    h.ap.poke(r, "please check the comments")
    local took = ms_since(t0)
    assert.is_true(took <= TIMEOUT + SLACK,
      string.format("poke() blocked %d ms, more than TIMEOUT_MS (%d) + %d; notes: %s",
        took, TIMEOUT, SLACK, vim.inspect(h.notes)))
  end)

  it("pick = true: at most TIMEOUT_MS before the picker opens", function()
    local r = F.new_dir()
    h.choose = "Review PR"
    local t0 = uv.hrtime()
    h.ap.poke(r, "please check the comments", { pick = true })
    assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
    local before = (h.selects[1].at - t0) / 1e6
    assert.is_true(before <= TIMEOUT + SLACK,
      string.format("picker opened after %d ms, more than TIMEOUT_MS (%d) + %d", before, TIMEOUT, SLACK))
  end)

  it("pick = true: at most TIMEOUT_MS from the choice until poke() returns", function()
    local r = F.new_dir()
    h.choose = "Review PR"
    h.ap.poke(r, "please check the comments", { pick = true })
    assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
    local after = ms_since(h.selects[1].at)
    assert.is_true(after <= TIMEOUT + SLACK,
      string.format("poke() blocked %d ms after the choice, more than TIMEOUT_MS (%d) + %d; notes: %s",
        after, TIMEOUT, SLACK, vim.inspect(h.notes)))
  end)
end)
