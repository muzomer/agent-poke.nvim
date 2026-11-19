-- agent-poke_nvim-hla (blocker): with a non-background target enabled and no
-- stored choice for the root, the first poke(root, prompt) opens the picker
-- (the background agent plus the targets' entries), as the old agent = "auto"
-- did (tests/herdr_findings_spec.lua at 87c404e). The choice is stored only
-- once the prompt was delivered. With no targets enabled poke() never opens a
-- picker.
--
-- Everything goes through the core API (require("agent-poke").setup / poke).
-- Fakes: tests/herdr_fakes.lua (fake `herdr` and `claude` on PATH).
local F = require("tests.herdr_fakes")

describe("first poke without a stored choice", function()
  local h = F.harness()

  describe("with the herdr target enabled", function()
    it("opens the picker (background + herdr panes), delivers to the chosen pane and stores it", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local d = F.new_dir()
      h.fakes.agents({ F.pane("w1:p1", "Review PR", d), F.pane(F.OWN, "This nvim", d) })
      local root = F.new_dir()

      h.choose = "Review PR"
      local status = h.ap.poke(root, "please check the comments")
      assert.are.equal(1, #h.selects, "the first poke must open the picker; notes: " .. vim.inspect(h.notes))
      local labels = h.selects[1].labels
      assert.is_true(F.contains(labels, "Review PR"), vim.inspect(labels))
      assert.is_true(F.contains(labels, "(background)"), vim.inspect(labels))
      assert.is_false(F.contains(labels, "This nvim"), vim.inspect(labels))
      assert.are.equal("typed", status, vim.inspect(h.notes))
      h.wait_prompt(1)
      assert.are.same({ "agent", "prompt", "w1:p1", "please check the comments" }, h.fakes.prompts()[1].argv)
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(root).target)
      assert.are.equal(0, #h.fakes.calls("claude"), "the background agent must not get the prompt too")

      -- the second poke goes to the stored pane, without a picker
      h.choose = nil
      assert.are.equal("typed", h.ap.poke(root, "second prompt"), vim.inspect(h.notes))
      h.wait_prompt(2)
      assert.are.same({ "agent", "prompt", "w1:p1", "second prompt" }, h.fakes.prompts()[2].argv)
      assert.are.equal(1, #h.selects, "no picker once a choice is stored")
    end)

    it("choosing the background agent runs it and stores { target = 'background' }; no picker afterwards", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local root = F.new_dir()

      h.choose = "(background)"
      local status = h.ap.poke(root, "first prompt")
      assert.are.equal(1, #h.selects, "the first poke must open the picker; notes: " .. vim.inspect(h.notes))
      assert.is_truthy(status == "started" or status == "queued", "status: " .. tostring(status))
      h.wait_claude(1)
      local argv = h.fakes.calls("claude")[1].argv
      assert.is_truthy(table.concat(argv, "\n"):find("first prompt", 1, true), vim.inspect(argv))
      assert.are.same({ target = "background" }, h.state.get(root).target)
      assert.are.equal(0, #h.fakes.prompts(), "nothing typed into a herdr pane")

      h.choose = nil
      local again = h.ap.poke(root, "second prompt")
      assert.is_truthy(again == "started" or again == "queued", "status: " .. tostring(again))
      assert.are.equal(1, #h.selects, "no picker once the background agent is stored")
    end)

    it("dismissing the picker delivers nothing and stores nothing; the next poke opens it again", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local root = F.new_dir()

      h.choose = nil
      local status = h.ap.poke(root, "first prompt")
      assert.are.equal(1, #h.selects, "the first poke must open the picker; notes: " .. vim.inspect(h.notes))
      assert.is_false(status)
      vim.wait(200)
      assert.is_nil(h.state.get(root).target)
      assert.are.equal(0, #h.fakes.calls("claude"))
      assert.are.equal(0, #h.fakes.prompts())

      h.choose = "Review PR"
      assert.are.equal("typed", h.ap.poke(root, "second prompt"), vim.inspect(h.notes))
      assert.are.equal(2, #h.selects, "nothing stored: the picker opens again")
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(root).target)
    end)

    it("a failed delivery to the chosen pane stores nothing", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      h.fakes.prompt_fails("no such pane")
      local root = F.new_dir()

      h.choose = "Review PR"
      local status = h.ap.poke(root, "first prompt")
      assert.are.equal(1, #h.selects, "the first poke must open the picker; notes: " .. vim.inspect(h.notes))
      assert.is_false(status)
      assert.is_nil(h.state.get(root).target, "a failed delivery must not be stored")
    end)

    it("a failed `herdr agent list` on the first poke does not remember the background agent", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()), F.pane(F.OWN, "This nvim", F.new_dir()) })
      h.fakes.list_fails(true)
      local root = F.new_dir()

      h.choose = nil -- a picker, if one opens, is dismissed
      h.ap.poke(root, "first prompt")
      h.wait_for("herdr agent list", function()
        local calls = h.fakes.calls("herdr")
        return #calls >= 1 and calls[1].done
      end)
      vim.wait(300)
      local saved = h.state.get(root).target
      assert.is_falsy(type(saved) == "table" and saved.target == "background",
        "background agent was remembered after a failed agent list: " .. vim.inspect(saved))

      -- herdr answers again: the next poke offers the herdr panes and reaches the chosen one
      h.fakes.list_fails(false)
      h.choose = "Review PR"
      local before = #h.selects
      assert.are.equal("typed", h.ap.poke(root, "second prompt"), vim.inspect(h.notes))
      assert.are.equal(before + 1, #h.selects, "the second poke must open the picker")
      h.wait_prompt(1)
      assert.are.same({ "agent", "prompt", "w1:p1", "second prompt" }, h.fakes.prompts()[1].argv)
      assert.are.same({ target = "herdr", id = "w1:p1" }, h.state.get(root).target)
    end)
  end)

  describe("with a non-herdr target spec enabled", function()
    it("opens the picker with the spec's entries and the background agent, delivers through the choice", function()
      local delivered = {}
      local spec = {
        name = "fake",
        list = function()
          return { { id = "a", title = "Alpha fake" }, { id = "b", title = "Beta fake" } }
        end,
        deliver = function(root, entry, prompt)
          delivered[#delivered + 1] = { root = root, entry = entry, prompt = prompt }
          return "queued"
        end,
      }
      h.ap.setup({ targets = { spec } })
      local root = F.new_dir()

      h.choose = "Beta fake"
      local status = h.ap.poke(root, "hello")
      assert.are.equal(1, #h.selects, "the first poke must open the picker; notes: " .. vim.inspect(h.notes))
      local labels = h.selects[1].labels
      assert.is_true(F.contains(labels, "Alpha fake"), vim.inspect(labels))
      assert.is_true(F.contains(labels, "(background)"), vim.inspect(labels))
      assert.are.equal("queued", status)
      assert.are.equal(1, #delivered)
      assert.are.equal("b", delivered[1].entry.id)
      assert.are.equal("hello", delivered[1].prompt)
      assert.are.same({ target = "fake", id = "b" }, h.state.get(root).target)
      assert.are.equal(0, #h.fakes.calls("claude"))
    end)
  end)

  describe("with no targets enabled (passes already)", function()
    for _, case in ipairs({
      { "setup({})", {} },
      { 'setup({ agent = "headless" })', { agent = "headless" } },
    }) do
      it(case[1] .. ": poke() never opens a picker and runs the background agent", function()
        h.ap.setup(case[2])
        local root = F.new_dir()
        local status = h.ap.poke(root, "hello")
        assert.is_truthy(status == "started" or status == "queued", "status: " .. tostring(status))
        h.wait_claude(1)
        assert.are.equal(0, #h.selects, "no picker without targets")
        assert.are.equal(0, #h.fakes.calls("herdr"))
      end)
    end
  end)
end)
