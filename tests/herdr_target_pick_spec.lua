-- herdr as a target: choosing a herdr pane through core (ap.pick / ap.poke).
-- Ported from herdr_spec (pick), herdr_pick_edges_spec, herdr_findings_spec
-- (failed agent list) and herdr_repick_fork_findings_spec, which called the
-- old herdr.pick / herdr.poke directly (agent-poke_nvim-0d8.2 finding 1).
--
-- Core stores a herdr choice as state key target = { target = "herdr", id = <pane> }.
-- The old herdr.poke() opened the picker when nothing was stored; core sends
-- that to the background agent, so the pick-path checks use poke({ pick = true }).
local F = require("tests.herdr_fakes")

describe("herdr target: picking", function()
  local h = F.harness()

  describe("pick()", function()
    it("stores the choice per root; a second root keeps its own, and each poke goes to its own pane", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local a_dir, b_dir = F.new_dir(), F.new_dir()
      h.fakes.agents({
        F.pane("w1:p1", "Review PR", a_dir),
        F.pane("w1:p9", "Other task", b_dir),
        F.pane(F.OWN, "This nvim", a_dir),
      })
      local root_a, root_b = F.new_dir(), F.new_dir()

      h.choose = "Review PR"
      h.ap.pick(root_a)
      h.wait_for("root A's target", function()
        return h.state.get(root_a).target ~= nil
      end)
      h.choose = "Other task"
      h.ap.pick(root_b)
      h.wait_for("root B's target", function()
        return h.state.get(root_b).target ~= nil
      end)
      assert.are.equal(2, #h.selects)
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(root_a).target)
      assert.are.same({ target = "herdr", id = "w1:p9" }, h.state.get(root_b).target)

      h.choose = nil
      assert.are.equal("typed", h.ap.poke(root_a, "prompt for A"), vim.inspect(h.notes))
      h.wait_prompt(1)
      assert.are.equal("typed", h.ap.poke(root_b, "prompt for B"), vim.inspect(h.notes))
      h.wait_prompt(2)
      local p = h.fakes.prompts()
      assert.are.same({ "agent", "prompt", "w1:p1", "prompt for A" }, p[1].argv)
      assert.are.same({ "agent", "prompt", "w1:p9", "prompt for B" }, p[2].argv)
      assert.are.equal(2, #h.selects, "no picker for a remembered pane")
    end)

    it("leaves this pane out and offers the background agent", function()
      h.ap.setup({ targets = { "herdr" } })
      local d = F.new_dir()
      h.fakes.agents({ F.pane("w1:p1", "Review PR", d), F.pane(F.OWN, "This nvim", d) })
      h.ap.pick(F.new_dir())
      assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
      local labels = h.selects[1].labels
      assert.is_true(F.contains(labels, "Review PR"), vim.inspect(labels))
      assert.is_false(F.contains(labels, "This nvim"), vim.inspect(labels))
      assert.is_true(F.contains(labels, "(background)"), vim.inspect(labels))
    end)
  end)

  describe("storing the choice (poke with pick = true)", function()
    it("does not store a picked pane when the prompt could not be delivered to it", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local r = F.new_dir()
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      h.fakes.prompt_fails("no pane w1:p1")
      h.choose = "Review PR"
      local res = h.ap.poke(r, "please check the comments", { pick = true })
      assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
      assert.are.equal(1, #h.fakes.prompts(), "expected one prompt attempt; notes: " .. vim.inspect(h.notes))
      assert.is_false(res)
      assert.is_nil(h.state.get(r).target, "the failed choice was stored")
    end)

    it("stores the picked pane once the prompt was delivered", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local r = F.new_dir()
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      h.choose = "Review PR"
      assert.are.equal("typed", h.ap.poke(r, "please check the comments", { pick = true }), vim.inspect(h.notes))
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(r).target)
    end)

    it("a failed `herdr agent list` does not choose and remember the background agent", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local r = F.new_dir()
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()), F.pane(F.OWN, "This nvim", F.new_dir()) })
      h.fakes.list_fails(true)
      h.choose = nil -- a picker, if one opens, is dismissed
      h.ap.poke(r, "first prompt", { pick = true })
      vim.wait(500) -- let the poke settle (picker, background run, notifications)
      local saved = h.state.get(r).target
      assert.is_falsy(type(saved) == "table" and saved.target == "background",
        "background agent was remembered after a failed agent list: " .. vim.inspect(saved))

      -- herdr answers again: the next pick offers the herdr panes and reaches the chosen one
      h.fakes.list_fails(false)
      h.choose = "Review PR"
      h.ap.poke(r, "second prompt", { pick = true })
      h.wait_prompt(1)
      assert.are.same({ "agent", "prompt", "w1:p1", "second prompt" }, h.fakes.prompts()[1].argv)
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(r).target)
    end)
  end)

  describe("a failed delivery to the picked pane", function()
    ---Pick "Review PR" with poke({ pick = true }); the notices after the choice.
    local function pick_and_poke(r, prompt)
      vim.fn.setreg('"', "something else")
      h.choose = "Review PR"
      local before_pick
      h.on_select = function()
        before_pick = #h.notes
      end
      local res = h.ap.poke(r, prompt, { pick = true })
      assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
      assert.is_not_nil(before_pick, "the picker was not reached")
      return res, vim.list_slice(h.notes, before_pick + 1)
    end

    local function assert_kept(r, res, after, prompt)
      assert.is_false(res, "notes: " .. vim.inspect(h.notes))
      assert.are.equal(1, #after, "expected one notification after the pick, got: " .. vim.inspect(after))
      assert.is_nil(after[1].msg:find("\n", 1, true), "the notification is not one line: " .. vim.inspect(after[1].msg))
      assert.is_nil(after[1].msg:find("^agent%-poke: poked"), "false success notification: " .. vim.inspect(after[1].msg))
      assert.are.equal(prompt, (vim.fn.getreg('"'):gsub("\n$", "")), "the prompt was not copied to the \" register")
      local t = h.state.get(r).target
      assert.is_false(type(t) == "table" and t.id == "w1:p1", "the failed choice was stored: " .. vim.inspect(t))
    end

    it("typing fails with a two-line error: one one-line notice, prompt in the \" register, not stored", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local r = F.new_dir()
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      h.fakes.prompt_fails("no pane w1:p1\nrun herdr agent list to see the panes")
      local prompt = "please check the comments\nin src/main.lua"
      local res, after = pick_and_poke(r, prompt)
      assert.are.equal(1, #h.fakes.prompts(), "expected one prompt attempt; notes: " .. vim.inspect(h.notes))
      assert_kept(r, res, after, prompt)
    end)

    it("isolate = fork (default), the fork cannot start (session directory gone): one line, no false success", function()
      h.ap.setup({ targets = { "herdr" } })
      local cfg = h.ap.config
      assert.is_true(cfg.isolate == nil or cfg.isolate == "fork", "test setup: isolate must be the default (fork)")
      local r, sess_dir = F.new_dir(), F.new_dir()
      F.transcript("sess-123", sess_dir)
      vim.fn.delete(sess_dir, "rf") -- the session's cwd no longer exists: the fork cannot start
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir(), "sess-123") })
      h.fakes.prompt_fails("no pane w1:p1") -- a fallback to typing fails too
      local prompt = "please check the comments\nin src/main.lua"
      local res, after = pick_and_poke(r, prompt)
      assert_kept(r, res, after, prompt)
    end)

    it("isolate = fork (default), session not found and typing fails: one notification", function()
      h.ap.setup({ targets = { "herdr" } })
      local r = F.new_dir()
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir(), "sess-missing") }) -- no transcript
      h.fakes.prompt_fails("no pane w1:p1\nrun herdr agent list to see the panes")
      local prompt = "please check the comments\nin src/main.lua"
      local res, after = pick_and_poke(r, prompt)
      assert.are.equal(1, #h.fakes.prompts(), "expected one typed attempt; notes: " .. vim.inspect(h.notes))
      assert_kept(r, res, after, prompt)
    end)

    it("isolate = fork (default), the fork starts: 'forked' and the picked pane is stored", function()
      h.ap.setup({ targets = { "herdr" } })
      local r, sess_dir = F.new_dir(), F.new_dir()
      F.transcript("sess-123", sess_dir)
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir(), "sess-123") })
      local res = pick_and_poke(r, "please check the comments")
      assert.are.equal("forked", res, "notes: " .. vim.inspect(h.notes))
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(r).target)
      h.wait_claude(1)
    end)
  end)
end)
