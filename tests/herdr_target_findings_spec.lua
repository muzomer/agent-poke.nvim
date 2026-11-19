-- agent-poke_nvim-0d8.2 review findings (blockers), through the core API only.
--   1. herdr.lua keeps a second picker/fallback/deliver path (pick, poke, ...)
--      next to core: the adapter must expose only the target interface.
--   2. init.lua:175: with targets = { "herdr" } and the background agent's
--      executable missing, pick() must not offer "(background)".
--   3. init.lua:197: opened from an insert-mode mapping, the picker must be
--      opened after the mapping returns (scheduled), not at once, so that the
--      mapping's stopinsert does not knock it out of its input.
local F = require("tests.herdr_fakes")

describe("herdr target review findings", function()
  local h = F.harness()

  describe("blocker 1: herdr is only a target", function()
    it("the adapter exposes no picker or poke path of its own", function()
      h.ap.setup({ targets = { "herdr" } })
      local herdr = require("agent-poke.targets.herdr")
      assert.is_function(herdr.list)
      assert.is_function(herdr.deliver)
      for _, name in ipairs({ "pick", "poke", "HEADLESS" }) do
        assert.is_nil(herdr[name], "the old herdr path is still there: herdr." .. name)
      end
    end)
  end)

  describe("blocker 2: (background) in the picker", function()
    it("is not offered when the background agent's executable is missing", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false, headless = { cmd = "agent-poke-no-such-agent-cmd" } })
      assert.is_false(require("agent-poke.headless").available(), "test setup: the background agent must be unavailable")
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      h.ap.pick(F.new_dir())
      assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
      local labels = h.selects[1].labels
      assert.is_true(F.contains(labels, "Review PR"), "the herdr agent was not offered: " .. vim.inspect(labels))
      assert.is_false(F.contains(labels, "(background)"), "(background) offered although unavailable: " .. vim.inspect(labels))
    end)

    it("poke({ pick = true }) does not offer it either, and delivers to the chosen pane", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false, headless = { cmd = "agent-poke-no-such-agent-cmd" } })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local r = F.new_dir()
      h.choose = "Review PR"
      local status = h.ap.poke(r, "please check the comments", { pick = true })
      assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
      assert.is_false(F.contains(h.selects[1].labels, "(background)"), vim.inspect(h.selects[1].labels))
      assert.are.equal("typed", status, vim.inspect(h.notes))
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(r).target)
    end)

    it("is offered when the background agent is available (passes already)", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      assert.is_true(require("agent-poke.headless").available(), "test setup: the fake claude must be found")
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      h.ap.pick(F.new_dir())
      assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
      assert.is_true(F.contains(h.selects[1].labels, "(background)"), vim.inspect(h.selects[1].labels))
    end)
  end)

  describe("blocker 3: picker from an insert-mode mapping", function()
    local KEY = "<Plug>(agent-poke-test-pick)"
    local during

    after_each(function()
      pcall(vim.keymap.del, "i", KEY)
      vim.cmd("stopinsert")
    end)

    ---Run fn from an insert-mode mapping; `during` = selects opened while it ran.
    local function from_insert_mapping(fn)
      during = nil
      vim.keymap.set("i", KEY, function()
        local before = #h.selects
        fn()
        during = #h.selects - before
      end)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i" .. KEY .. "<Esc>", true, false, true), "x", false)
      assert.is_not_nil(during, "the mapping did not run")
    end

    it("pick() opens the picker after the mapping returns, not at once", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local r = F.new_dir()
      h.choose = "Review PR"
      from_insert_mapping(function()
        h.ap.pick(r)
      end)
      assert.are.equal(0, during, "the picker opened inside the insert-mode mapping")
      h.wait_for("the deferred picker", function()
        return #h.selects == 1
      end)
      h.wait_for("the choice to be stored", function()
        return h.state.get(r).target ~= nil
      end)
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(r).target)
    end)

    it("poke({ pick = true }) opens the picker after the mapping returns and delivers on the choice", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local r = F.new_dir()
      h.choose = "Review PR"
      local status = "not returned"
      from_insert_mapping(function()
        status = h.ap.poke(r, "please check the comments", { pick = true })
      end)
      assert.are.equal(0, during, "the picker opened inside the insert-mode mapping")
      assert.is_false(status, "poke() returns false while the picker is still to open")
      h.wait_for("the deferred picker", function()
        return #h.selects == 1
      end)
      h.wait_prompt(1)
      local p = h.fakes.prompts()
      assert.are.same({ "agent", "prompt", "w1:p1", "please check the comments" }, p[1].argv)
      h.wait_for("the choice to be stored", function()
        return h.state.get(r).target ~= nil
      end)
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(r).target)
    end)

    it("from normal mode the picker opens at once (passes already)", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      h.ap.pick(F.new_dir())
      assert.are.equal(1, #h.selects)
    end)
  end)
end)
