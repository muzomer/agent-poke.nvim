-- agent-poke_nvim-wtd.6: README documents every option and every API function
-- with a short example, plus install, state location, legacy import and backends.
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local README = ROOT .. "/README.md"

local function readme()
  assert.are.equal(1, vim.fn.filereadable(README), "no README.md at the repository root")
  return table.concat(vim.fn.readfile(README), "\n")
end

local function fresh()
  package.loaded["agent-poke"] = nil
  return require("agent-poke")
end

local function has(text, needle)
  return text:find(needle, 1, true) ~= nil
end

describe("README.md", function()
  it("exists at the repository root", function()
    readme()
  end)

  it("names the choices of agent and isolate", function()
    local text = readme()
    for _, v in ipairs({ '"auto"', '"herdr"', '"headless"', '"fork"', '"subagent"' }) do
      assert.is_true(has(text, v), "README does not name " .. v)
    end
  end)

  it("names every exported function with a call example", function()
    local text = readme()
    local missing = {}
    for name, v in pairs(fresh()) do
      if type(v) == "function" and not text:find("%." .. vim.pesc(name) .. "%(") then
        missing[#missing + 1] = name
      end
    end
    table.sort(missing)
    assert.are.same({}, missing, "functions without a `.name(` example: " .. table.concat(missing, ", "))
  end)

  it("documents setup/poke/pick/output/chat/stop with calls", function()
    local text = readme()
    for _, name in ipairs({ "setup", "poke", "pick", "output", "chat", "stop" }) do
      assert.is_truthy(text:find("%." .. name .. "%("), "no `." .. name .. "(` example")
    end
  end)

  it("has lua code examples", function()
    assert.is_true(has(readme(), "```lua"), "no ```lua code block")
  end)

  it("covers install with lazy.nvim and vim.pack", function()
    local text = readme()
    assert.is_true(has(text, "lazy.nvim"), "no lazy.nvim install")
    assert.is_true(has(text, "vim.pack"), "no vim.pack install")
  end)

  it("gives the state location and the legacy code-review.nvim import", function()
    local text = readme()
    assert.is_true(has(text, 'stdpath("state")'), 'no stdpath("state")')
    assert.is_true(has(text, ".code-review/headless.json"), "no legacy .code-review/headless.json")
  end)

  it("lists every background agent backend", function()
    local text = readme()
    for _, b in ipairs({ "claude", "codex", "opencode", "gemini" }) do
      assert.is_true(has(text, b), "backend " .. b .. " not listed")
    end
  end)
end)

describe("README.md install examples", function()
  it("lazy.nvim spec uses muzomer/agent-poke.nvim", function()
    assert.is_truthy(readme():find('"muzomer/agent-poke.nvim"', 1, true))
  end)

  it("vim.pack URL uses https://github.com/muzomer/agent-poke.nvim", function()
    assert.is_truthy(readme():find("https://github.com/muzomer/agent-poke.nvim", 1, true))
  end)

  it("names no other GitHub owner for the plugin", function()
    local text = readme()
    for owner in text:gmatch("([%w_.-]+)/agent%-poke%.nvim") do
      if owner ~= "github.com" then
        assert.are.equal("muzomer", owner)
      end
    end
  end)
end)
