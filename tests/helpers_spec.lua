-- agent-poke_nvim-wtd.1: the test harness puts fake `claude` and `herdr`
-- executables on PATH that record argv / stdin and print canned stream-json.
--
-- Interface (tests/helpers.lua, required as "tests.helpers"):
--   local fake = helpers.install_fakes()  -- prepends a temp bin dir to PATH
--   fake.dir                              -- that directory
--   fake.calls(name) -> { { argv = { ... }, stdin = "..." }, ... }  (name: "claude" | "herdr")
--   fake.restore()                        -- PATH back as before
local helpers = require("tests.helpers")

local function run(cmd, stdin)
  return vim.system(cmd, { stdin = stdin, text = true }):wait()
end

describe("test helpers: fake agents", function()
  local fake, old_path

  before_each(function()
    old_path = vim.env.PATH
    fake = helpers.install_fakes()
  end)

  after_each(function()
    fake.restore()
  end)

  it("puts fake claude and herdr first on PATH", function()
    assert.is_truthy(fake.dir and fake.dir ~= "")
    for _, name in ipairs({ "claude", "herdr" }) do
      local exe = vim.fn.exepath(name)
      assert.are.same(vim.fs.normalize(fake.dir .. "/" .. name), vim.fs.normalize(exe))
    end
  end)

  it("records claude's argv and stdin", function()
    local res = run({ "claude", "-p", "--output-format", "stream-json", "--resume", "abc 123" }, "hello\nagent")
    assert.are.same(0, res.code)
    local calls = fake.calls("claude")
    assert.are.same(1, #calls)
    assert.are.same({ "-p", "--output-format", "stream-json", "--resume", "abc 123" }, calls[1].argv)
    assert.are.same("hello\nagent", calls[1].stdin)
  end)

  it("records every call, in order", function()
    run({ "claude", "-p", "one" }, "")
    run({ "claude", "-p", "two" }, "second")
    local calls = fake.calls("claude")
    assert.are.same(2, #calls)
    assert.are.same({ "-p", "one" }, calls[1].argv)
    assert.are.same({ "-p", "two" }, calls[2].argv)
    assert.are.same("second", calls[2].stdin)
  end)

  it("fake claude prints canned stream-json ending in a result with a session id", function()
    local res = run({ "claude", "-p", "--output-format", "stream-json" }, "hi")
    local lines = vim.tbl_filter(function(l)
      return l ~= ""
    end, vim.split(res.stdout, "\n"))
    assert.is_true(#lines > 0)
    local last
    for _, l in ipairs(lines) do
      local ok, obj = pcall(vim.json.decode, l)
      assert.is_true(ok, "not JSON: " .. l)
      assert.is_truthy(obj.type, "no type: " .. l)
      last = obj
    end
    assert.are.same("result", last.type)
    assert.is_truthy(last.session_id and last.session_id ~= "")
  end)

  it("records herdr's argv and stdin separately from claude's", function()
    local res = run({ "herdr", "pane", "send-text", "w1:p1", "do it" }, "typed")
    assert.are.same(0, res.code)
    assert.are.same({}, fake.calls("claude"))
    local calls = fake.calls("herdr")
    assert.are.same(1, #calls)
    assert.are.same({ "pane", "send-text", "w1:p1", "do it" }, calls[1].argv)
    assert.are.same("typed", calls[1].stdin)
  end)

  it("restore() puts PATH back", function()
    fake.restore()
    assert.are.same(old_path, vim.env.PATH)
    fake = { restore = function() end }
  end)
end)
