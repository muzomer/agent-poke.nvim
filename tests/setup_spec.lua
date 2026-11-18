-- agent-poke_nvim-wtd.1: setup() defaults and deep merge.
local function fresh()
  package.loaded["agent-poke"] = nil
  return require("agent-poke")
end

-- code-review.nvim's defaults for the options agent-poke takes over
-- (lua/code-review/init.lua M.config: agent, isolate, headless).
local HEADLESS_DEFAULTS = {
  agent = "claude",
  cmd = nil,
  allowed_tools = nil,
  extra_tools = {},
  permission_mode = nil,
  args = {},
}

describe("agent-poke setup()", function()
  it("with no args gives code-review.nvim's defaults", function()
    local ap = fresh()
    ap.setup()
    local c = ap.config
    assert.are.same("auto", c.agent) -- herdr choice: "auto", "herdr", "headless"
    assert.are.same("fork", c.isolate)
    assert.are.same(HEADLESS_DEFAULTS, c.headless)
  end)

  it("with an empty table gives the same defaults", function()
    local ap = fresh()
    ap.setup({})
    assert.are.same("auto", ap.config.agent)
    assert.are.same("fork", ap.config.isolate)
    assert.are.same(HEADLESS_DEFAULTS, ap.config.headless)
  end)

  it("deep-merges headless options, keeping the other defaults", function()
    local ap = fresh()
    ap.setup({ headless = { agent = "codex" } })
    local want = vim.deepcopy(HEADLESS_DEFAULTS)
    want.agent = "codex"
    assert.are.same(want, ap.config.headless)
    assert.are.same("fork", ap.config.isolate)
    assert.are.same("auto", ap.config.agent)
  end)

  it("accepts isolate = false", function()
    local ap = fresh()
    ap.setup({ isolate = false })
    assert.are.same(false, ap.config.isolate)
  end)

  -- agent-poke_nvim-ei4.1: a second setup() merges into the current config
  it("a second setup() deep-merges into the current config", function()
    local ap = fresh()
    ap.setup({ headless = { agent = "codex", permission_mode = "acceptEdits" } })
    ap.setup({ isolate = false })
    local want = vim.deepcopy(HEADLESS_DEFAULTS)
    want.agent = "codex"
    want.permission_mode = "acceptEdits"
    assert.are.same(want, ap.config.headless)
    assert.are.same(false, ap.config.isolate)
  end)

  it("does not let the caller's table alias the config", function()
    local ap = fresh()
    local opts = { headless = { agent = "gemini", args = { "--x" } } }
    ap.setup(opts)
    opts.headless.args[1] = "--changed"
    assert.are.same({ "--x" }, ap.config.headless.args)
  end)
end)
