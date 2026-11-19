-- herdr as a target: delivering to a stored herdr pane through core (ap.poke).
-- Ported from herdr_spec (fork, typing, fallbacks) and herdr_findings_spec
-- (fork with the pane agent's command line), which called the old
-- herdr.pick / herdr.poke directly (agent-poke_nvim-0d8.2 finding 1).
--
-- The pane is stored as state key target = { target = "herdr", id = <pane> }.
local F = require("tests.herdr_fakes")

describe("herdr target: delivering", function()
  local h = F.harness()

  local function stored(r)
    h.state.set(r, "target", { target = "herdr", id = "w1:p1" })
    return r
  end

  describe("fork", function()
    it("isolate='fork' with a Claude transcript runs a throwaway fork in the session's directory", function()
      h.ap.setup({ targets = { "herdr" }, isolate = "fork" })
      local sess_dir, pane_dir = F.new_dir(), F.new_dir()
      F.transcript("sess-123", sess_dir)
      h.fakes.agents({ F.pane("w1:p1", "Review PR", pane_dir, "sess-123") })
      local r = stored(F.new_dir())
      assert.are.equal("forked", h.ap.poke(r, "please check the comments"), vim.inspect(h.notes))
      h.wait_claude(1)
      local runs = h.fakes.calls("claude")
      assert.are.equal(1, #runs)
      local argv = runs[1].argv
      assert.is_truthy(vim.tbl_contains(argv, "-p"), vim.inspect(argv))
      assert.is_truthy(tostring(F.arg_after(argv, "-p")):find("please check the comments", 1, true), vim.inspect(argv))
      assert.are.equal("sess-123", F.arg_after(argv, "--resume"))
      assert.is_truthy(vim.tbl_contains(argv, "--fork-session"), vim.inspect(argv))
      assert.is_falsy(vim.tbl_contains(argv, "--session-id"), vim.inspect(argv))
      assert.are.equal(sess_dir, runs[1].cwd) -- the transcript's directory, not the pane's
      assert.are.equal(0, #h.fakes.prompts()) -- nothing typed into the pane
      assert.are.equal(0, #h.selects)
    end)

    it("forks a Claude pane with Claude's command line when the background agent is codex", function()
      h.ap.setup({
        targets = { "herdr" },
        isolate = "fork",
        headless = { agent = "codex", args = { "--codex-only-arg" } },
      })
      local sess_dir, pane_dir = F.new_dir(), F.new_dir()
      F.transcript("sess-123", sess_dir)
      h.fakes.agents({ F.pane("w1:p1", "Review PR", pane_dir, "sess-123") })
      local r = stored(F.new_dir())
      h.ap.poke(r, "please check the comments")
      h.wait_claude(1)
      vim.wait(100)
      local runs = h.fakes.calls("claude")
      assert.are.equal(1, #runs)
      local argv = runs[1].argv
      assert.are.equal("-p", argv[1], vim.inspect(argv))
      assert.is_truthy(tostring(argv[2]):find("please check the comments", 1, true), vim.inspect(argv))
      assert.are.equal("sess-123", F.arg_after(argv, "--resume"), vim.inspect(argv))
      assert.is_truthy(vim.tbl_contains(argv, "--fork-session"), vim.inspect(argv))
      assert.is_falsy(vim.tbl_contains(argv, "exec"), vim.inspect(argv))
      assert.is_falsy(vim.tbl_contains(argv, "--json"), vim.inspect(argv))
      assert.is_falsy(vim.tbl_contains(argv, "--codex-only-arg"), vim.inspect(argv))
      assert.are.equal(sess_dir, runs[1].cwd)
      assert.are.equal(0, #h.errors(), vim.inspect(h.notes))
    end)
  end)

  describe("typing into the pane", function()
    it("without a transcript (isolate='fork') types the prompt with the subagent wording", function()
      h.ap.setup({ targets = { "herdr" }, isolate = "fork" })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir(), "no-transcript") })
      local r = stored(F.new_dir())
      assert.are.equal("typed", h.ap.poke(r, "please check the comments"), vim.inspect(h.notes))
      h.wait_prompt(1)
      local argv = h.fakes.prompts()[1].argv
      assert.are.same({ "agent", "prompt", "w1:p1" }, { argv[1], argv[2], argv[3] })
      assert.is_truthy(argv[4]:find("please check the comments", 1, true), argv[4])
      assert.is_truthy(argv[4]:lower():find("subagent", 1, true), argv[4])
      vim.wait(200)
      assert.are.equal(0, #h.fakes.calls("claude"))
    end)

    it("isolate='subagent' types the prompt with the subagent wording even with a transcript", function()
      h.ap.setup({ targets = { "herdr" }, isolate = "subagent" })
      local sess_dir = F.new_dir()
      F.transcript("sess-456", sess_dir)
      h.fakes.agents({ F.pane("w1:p1", "Review PR", sess_dir, "sess-456") })
      local r = stored(F.new_dir())
      assert.are.equal("typed", h.ap.poke(r, "please check the comments"), vim.inspect(h.notes))
      local text = h.fakes.prompts()[1].argv[4]
      assert.is_truthy(text:find("please check the comments", 1, true), text)
      assert.is_truthy(text:lower():find("subagent", 1, true), text)
      vim.wait(200)
      assert.are.equal(0, #h.fakes.calls("claude"))
    end)

    it("isolate=false types the plain prompt, even with a transcript", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local sess_dir = F.new_dir()
      F.transcript("sess-789", sess_dir)
      h.fakes.agents({ F.pane("w1:p1", "Review PR", sess_dir, "sess-789") })
      local r = stored(F.new_dir())
      assert.are.equal("typed", h.ap.poke(r, "please check the comments"), vim.inspect(h.notes))
      assert.are.same({ "agent", "prompt", "w1:p1", "please check the comments" }, h.fakes.prompts()[1].argv)
      vim.wait(200)
      assert.are.equal(0, #h.fakes.calls("claude"))
    end)
  end)

  describe("falls back to the background agent", function()
    local function assert_background(r, prompt, selects)
      h.wait_claude(1)
      local runs = h.fakes.calls("claude")
      assert.are.equal(1, #runs)
      local argv = runs[1].argv
      assert.is_truthy(tostring(F.arg_after(argv, "-p")):find(prompt, 1, true), vim.inspect(argv))
      assert.is_falsy(vim.tbl_contains(argv, "--fork-session"), vim.inspect(argv))
      assert.are.equal(r, runs[1].cwd)
      assert.are.equal(0, #h.fakes.prompts())
      assert.are.equal(selects or 0, #h.selects)
    end

    it("when herdr is not running (no HERDR_SOCKET_PATH)", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      vim.env.HERDR_SOCKET_PATH = nil
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local r = stored(F.new_dir())
      h.ap.poke(r, "background please")
      assert_background(r, "background please")
    end)

    it("when herdr is not installed", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.remove_herdr()
      local r = stored(F.new_dir())
      h.ap.poke(r, "background please")
      assert_background(r, "background please")
    end)

    it("when the remembered pane is gone", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      local d = F.new_dir()
      h.fakes.agents({ F.pane(F.OWN, "This nvim", d) }) -- w1:p1 closed; only this pane is left
      local r = stored(F.new_dir())
      h.ap.poke(r, "background please")
      assert_background(r, "background please")
    end)

    it("when nothing is stored yet and the picker's choice is the background agent", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local r = F.new_dir()
      h.choose = "(background)" -- the first poke opens the picker (agent-poke_nvim-hla)
      h.ap.poke(r, "background please")
      assert_background(r, "background please", 1)
    end)
  end)
end)
