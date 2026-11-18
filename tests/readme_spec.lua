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

---Every option path ("agent", "headless.cmd", ...) of the default config. Keys
---whose default is nil are not in the table, so list them from the design.
local function option_keys()
  local keys = {}
  local function walk(t, prefix)
    for k, v in pairs(t) do
      local name = prefix .. k
      keys[#keys + 1] = { key = k, path = name }
      if type(v) == "table" and not vim.islist(v) and next(v) ~= nil then
        walk(v, name .. ".")
      end
    end
  end
  walk(fresh().config, "")
  for _, k in ipairs({ "cmd", "allowed_tools", "permission_mode" }) do
    keys[#keys + 1] = { key = k, path = "headless." .. k }
  end
  return keys
end

describe("README.md", function()
  it("exists at the repository root", function()
    readme()
  end)

  it("documents every setup() option as `key = ...` (e.g. in the setup example)", function()
    local text = readme()
    local missing = {}
    for _, o in ipairs(option_keys()) do
      if not text:find("%f[%w_]" .. vim.pesc(o.key) .. "%s*=") then
        missing[#missing + 1] = o.path
      end
    end
    table.sort(missing)
    assert.are.same({}, missing, "options not shown as `key = ...`: " .. table.concat(missing, ", "))
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
