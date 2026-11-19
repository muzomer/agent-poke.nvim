-- agent-poke_nvim-hla (nits 1-3): option leftovers of the herdr-as-target epic.
--   - defaults.lua has no unread `agent` option.
--   - setup({ agent = "headless" }) loads no adapter module (the legacy mapping
--     is read without requiring every lua/agent-poke/targets/*.lua).
--   - isolate is read from one place, the adapter option
--     (targets = { herdr = { isolate = ... } }), whose default is "fork"; the
--     top-level `isolate` keeps working as a deprecated alias.
--
-- Fakes: tests/herdr_fakes.lua (fake `herdr` and `claude` on PATH).
local F = require("tests.herdr_fakes")

describe("targets follow-up: options", function()
  local h = F.harness()

  describe("defaults", function()
    it("have no `agent` option (nothing reads it)", function()
      assert.is_nil(require("agent-poke.defaults")().agent)
    end)

    it("have no top-level `isolate` (it is the herdr adapter's option)", function()
      assert.is_nil(require("agent-poke.defaults")().isolate)
    end)

    it("setup({}) leaves config.agent unset", function()
      h.ap.setup({})
      assert.is_nil(h.ap.config.agent)
    end)
  end)

  describe("legacy agent mapping", function()
    it('setup({ agent = "headless" }) loads no adapter module', function()
      assert.is_nil(package.loaded["agent-poke.targets.herdr"], "test setup: herdr must not be loaded yet")
      h.ap.setup({ agent = "headless" })
      assert.are.equal(0, #h.ap.targets)
      assert.is_nil(package.loaded["agent-poke.targets.herdr"], "the herdr module was loaded for agent = headless")
    end)

    it('setup({}) loads no adapter module (passes already)', function()
      h.ap.setup({})
      assert.is_nil(package.loaded["agent-poke.targets.herdr"])
    end)

    it('setup({ agent = "auto" }) still enables herdr (passes already)', function()
      h.ap.setup({ agent = "auto" })
      assert.are.equal(1, #h.ap.targets)
      assert.are.equal("herdr", h.ap.targets[1].name)
    end)
  end)

  describe("isolate", function()
    local function stored_pane(dir)
      h.fakes.agents({ F.pane("w1:p1", "Review PR", dir, "sess-1") })
      F.transcript("sess-1", dir) -- forkable, so isolate decides fork vs typed
      local root = F.new_dir()
      h.state.set(root, "target", { target = "herdr", id = "w1:p1" })
      return root
    end

    it("top-level isolate = false still types the plain prompt (deprecated alias; passes already)", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local root = stored_pane(F.new_dir())
      assert.are.equal("typed", h.ap.poke(root, "plain please"), vim.inspect(h.notes))
      h.wait_prompt(1)
      assert.are.same({ "agent", "prompt", "w1:p1", "plain please" }, h.fakes.prompts()[1].argv)
      assert.are.equal(0, #h.fakes.calls("claude"))
    end)

    it("the adapter option wins over the top-level alias (passes already)", function()
      h.ap.setup({ isolate = "fork", targets = { herdr = { isolate = false } } })
      local root = stored_pane(F.new_dir())
      assert.are.equal("typed", h.ap.poke(root, "plain please"), vim.inspect(h.notes))
      h.wait_prompt(1)
      assert.are.same({ "agent", "prompt", "w1:p1", "plain please" }, h.fakes.prompts()[1].argv)
    end)

    it("no isolate anywhere: the adapter default forks the pane's session (passes already)", function()
      h.ap.setup({ targets = { herdr = {} } })
      local root = stored_pane(F.new_dir())
      assert.are.equal("forked", h.ap.poke(root, "fork please"), vim.inspect(h.notes))
      h.wait_claude(1)
      local argv = h.fakes.calls("claude")[1].argv
      assert.are.equal("sess-1", F.arg_after(argv, "--resume"), vim.inspect(argv))
      assert.are.equal(0, #h.fakes.prompts())
    end)
  end)
end)
