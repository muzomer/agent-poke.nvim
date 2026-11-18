-- agent-poke_nvim-ei4.1: a second setup() deep-merges into the current config,
-- and an unknown headless.agent is rejected (notification, previous value kept).
local function fresh()
  package.loaded["agent-poke"] = nil
  return require("agent-poke")
end

describe("agent-poke setup() merging and agent validation", function()
  local old_notify, notes

  before_each(function()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
  end)

  after_each(function()
    vim.notify = old_notify
    package.loaded["agent-poke"] = nil
  end)

  local function mentions(word)
    for _, n in ipairs(notes) do
      if n.msg:find(word, 1, true) then
        return true
      end
    end
    return false
  end

  it("a second setup() keeps the first caller's options and adds its own", function()
    local ap = fresh()
    ap.setup({ agent = "headless", headless = { agent = "codex", permission_mode = "read-only" } })
    ap.setup({ isolate = false, headless = { cmd = "/opt/codex" } })
    assert.are.equal("headless", ap.config.agent)
    assert.are.equal(false, ap.config.isolate)
    assert.are.equal("codex", ap.config.headless.agent)
    assert.are.equal("read-only", ap.config.headless.permission_mode)
    assert.are.equal("/opt/codex", ap.config.headless.cmd)
  end)

  it("setup() with no options after a configured one changes nothing", function()
    local ap = fresh()
    ap.setup({ isolate = "subagent", headless = { agent = "gemini" } })
    ap.setup()
    assert.are.equal("subagent", ap.config.isolate)
    assert.are.equal("gemini", ap.config.headless.agent)
    ap.setup({})
    assert.are.equal("subagent", ap.config.isolate)
    assert.are.equal("gemini", ap.config.headless.agent)
  end)

  it("a later setup() overrides the same key", function()
    local ap = fresh()
    ap.setup({ headless = { agent = "codex" } })
    ap.setup({ headless = { agent = "opencode" } })
    assert.are.equal("opencode", ap.config.headless.agent)
  end)

  it("rejects an unknown headless.agent with a notification and keeps the default", function()
    local ap = fresh()
    ap.setup({ headless = { agent = "bogus-agent" } })
    assert.are.equal("claude", ap.config.headless.agent)
    assert.is_true(mentions("bogus-agent"), "no notification about the unknown agent: " .. vim.inspect(notes))
  end)

  it("rejects an unknown headless.agent with a notification and keeps the previous value", function()
    local ap = fresh()
    ap.setup({ headless = { agent = "codex" } })
    ap.setup({ headless = { agent = "nonsense" } })
    assert.are.equal("codex", ap.config.headless.agent)
    assert.is_true(mentions("nonsense"), "no notification about the unknown agent: " .. vim.inspect(notes))
  end)

  it("accepts every known agent without a notification (passes already)", function()
    for _, name in ipairs({ "claude", "codex", "opencode", "gemini" }) do
      local ap = fresh()
      ap.setup({ headless = { agent = name } })
      assert.are.equal(name, ap.config.headless.agent)
    end
    assert.are.same({}, notes)
  end)
end)
