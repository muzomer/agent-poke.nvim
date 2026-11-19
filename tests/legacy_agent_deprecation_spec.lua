-- agent-poke_nvim-0d8.3: the old `agent` option keeps working for one release
-- (owner: agent = "herdr" | "auto" -> targets = { "herdr" }; agent = "headless"
-- -> no targets) and setup() then shows a ONE-line deprecation notice, once
-- per setup() call that passes `agent` explicitly. A plain setup({}) or a
-- setup() with only headless options shows none.
--
-- No external program is run: setup() only registers targets.

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

local function target_names(ap)
  local names = {}
  for _, t in ipairs(ap.targets) do
    names[#names + 1] = t.name
  end
  return names
end

local function is_deprecation(n)
  local m = n.msg:lower():gsub("^agent%-poke:%s*", "") -- the prefix names no option
  return m:find("deprecat", 1, true) ~= nil and m:find("%f[%w_]agent%f[^%w_%-]") ~= nil
end

describe("legacy agent option", function()
  local ap, notes, old_notify

  before_each(function()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
  end)

  after_each(function()
    vim.notify = old_notify
    unload()
  end)

  local function deprecations()
    local out = {}
    for _, n in ipairs(notes) do
      if is_deprecation(n) then
        out[#out + 1] = n
      end
    end
    return out
  end

  local function assert_one_line_notice()
    local d = deprecations()
    assert.are.equal(1, #d, "expected exactly one deprecation notice, got: " .. vim.inspect(notes))
    local n = d[1]
    assert.is_nil(n.msg:find("\n", 1, true), "the deprecation notice must be one line: " .. n.msg)
    assert.is_truthy(n.msg:find("targets", 1, true), "the notice must name the new option `targets`: " .. n.msg)
    assert.are_not.equal(vim.log.levels.ERROR, n.level, "a deprecation is not an error")
    assert.are.equal(1, #notes, "setup() must show nothing besides the notice: " .. vim.inspect(notes))
  end

  local mapped = {
    { "herdr", { "herdr" } },
    { "auto", { "herdr" } },
    { "headless", {} },
  }

  for _, case in ipairs(mapped) do
    local agent, want = case[1], case[2]

    it('setup({ agent = "' .. agent .. '" }) still works: targets = ' .. vim.inspect(want), function()
      ap.setup({ agent = agent })
      assert.are.same(want, target_names(ap))
    end)

    it('setup({ agent = "' .. agent .. '" }) shows one one-line deprecation notice', function()
      ap.setup({ agent = agent })
      assert_one_line_notice()
    end)
  end

  it("each setup() call with agent shows the notice once (two calls, two notices)", function()
    ap.setup({ agent = "herdr" })
    assert.are.equal(1, #deprecations())
    ap.setup({ agent = "herdr" }) -- same value: vim.notify_once would not do
    assert.are.equal(2, #deprecations(), vim.inspect(notes))
  end)

  it("setup({}) shows no deprecation notice", function()
    ap.setup({})
    assert.are.same({}, deprecations())
  end)

  it("setup() with only headless options shows no deprecation notice", function()
    ap.setup({ headless = { agent = "claude", args = {} } })
    assert.are.same({}, deprecations())
  end)

  it("setup() with the new targets option shows no deprecation notice", function()
    ap.setup({ targets = { "herdr" } })
    assert.are.same({ "herdr" }, target_names(ap))
    assert.are.same({}, deprecations())
  end)
end)
