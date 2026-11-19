-- agent-poke_nvim-4kp: progress of prompts delivered through the herdr target.
-- The herdr adapter reports progress only if herdr exposes the agent's status;
-- otherwise core shows "sent". Core never polls herdr: after a delivery no herdr
-- call is made until someone asks ap.progress(id).
--
-- Assumption: a forked delivery is a background run, so its id follows that
-- run to "done".
local F = require("tests.herdr_fakes")

describe("herdr target: progress", function()
  local h = F.harness()

  local function stored(r)
    h.state.set(r, "target", { target = "herdr", id = "w1:p1" })
    return r
  end

  local function pane_without_status(dir)
    local p = F.pane("w1:p1", "Review PR", dir)
    p.agent_status = nil
    return p
  end

  it("a typed prompt makes no further herdr calls after delivery", function()
    h.ap.setup({ targets = { "herdr" }, isolate = false })
    h.fakes.agents({ pane_without_status(F.new_dir()) })
    local r = stored(F.new_dir())
    local status, id = h.ap.poke(r, "please check")
    assert.are.equal("typed", status, vim.inspect(h.notes))
    assert.is_not_nil(id)
    local before = #h.fakes.calls("herdr")
    vim.wait(500)
    assert.are.equal(before, #h.fakes.calls("herdr"), vim.inspect(h.fakes.calls("herdr")))
    assert.are.equal(0, #h.fakes.calls("claude"))
  end)

  it("a typed prompt stays 'sent' when herdr exposes no status for the agent", function()
    h.ap.setup({ targets = { "herdr" }, isolate = false })
    h.fakes.agents({ pane_without_status(F.new_dir()) })
    local r = stored(F.new_dir())
    local _, id = h.ap.poke(r, "please check")
    local stage = h.ap.progress(id)
    assert.are.equal("sent", stage)
  end)

  it("a forked prompt follows its background run to done", function()
    h.ap.setup({ targets = { "herdr" }, isolate = "fork" })
    local sess_dir = F.new_dir()
    F.transcript("sess-123", sess_dir)
    h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir(), "sess-123") })
    local r = stored(F.new_dir())
    local status, id = h.ap.poke(r, "please check")
    assert.are.equal("forked", status, vim.inspect(h.notes))
    assert.is_not_nil(id)
    h.wait_claude(1)
    h.wait_for("the fork to be done", function()
      return h.ap.progress(id) == "done"
    end)
  end)
end)
