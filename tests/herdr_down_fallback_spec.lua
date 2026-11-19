-- agent-poke_nvim-hla (nit 6): herdr is down (not reachable from here) and a
-- herdr pane is stored for the root. As the old agent = "auto" did (herdr.lua
-- at 87c404e: `mode == "auto" and not M.available()` -> background), every
-- poke silently goes to the background agent: at most one notice in total, no
-- "the agent you used before is gone" per poke, no picker, the prompt is
-- delivered, and the stored pane is kept for when herdr is back.
--
-- Fakes: tests/herdr_fakes.lua (fake `herdr` and `claude` on PATH).
local F = require("tests.herdr_fakes")

describe("herdr down with a stored herdr pane", function()
  local h = F.harness()

  local function warnings()
    return vim.tbl_filter(function(n)
      return (n.level or vim.log.levels.INFO) >= vim.log.levels.WARN
    end, h.notes)
  end

  local function gone_notes()
    return vim.tbl_filter(function(n)
      return n.msg:find("gone", 1, true) ~= nil
    end, h.notes)
  end

  local cases = {
    { "no herdr socket", function() vim.env.HERDR_SOCKET_PATH = nil end },
    { "no herdr executable", function() h.fakes.remove_herdr() end },
  }

  for _, case in ipairs(cases) do
    it(case[1] .. ": two pokes reach the background agent with at most one notice", function()
      h.ap.setup({ targets = { "herdr" }, isolate = false })
      h.fakes.agents({ F.pane("w1:p1", "Review PR", F.new_dir()) })
      local root = F.new_dir()
      local stored = { target = "herdr", id = "w1:p1" }
      h.state.set(root, "target", stored)
      case[2]()

      local first = h.ap.poke(root, "first prompt")
      assert.is_truthy(first == "started" or first == "queued", "status: " .. tostring(first) .. " " .. vim.inspect(h.notes))
      h.wait_claude(1)
      local second = h.ap.poke(root, "second prompt")
      assert.is_truthy(second == "started" or second == "queued", "status: " .. tostring(second) .. " " .. vim.inspect(h.notes))
      h.wait_claude(2)

      local runs = h.fakes.calls("claude")
      assert.is_truthy(table.concat(runs[1].argv, "\n"):find("first prompt", 1, true), vim.inspect(runs[1].argv))
      assert.is_truthy(table.concat(runs[2].argv, "\n"):find("second prompt", 1, true), vim.inspect(runs[2].argv))
      assert.are.equal(0, #h.selects, "no picker: a choice is stored")
      assert.are.same({}, gone_notes(), "herdr being down is not the agent being gone")
      assert.is_true(#warnings() <= 1, "at most one notice in total: " .. vim.inspect(h.notes))
      assert.are.same({}, h.errors())
      assert.are.same(stored, h.state.get(root).target, "the stored pane is kept for when herdr is back")
    end)
  end

  it("herdr up but the stored pane is gone still says so (passes already)", function()
    h.ap.setup({ targets = { "herdr" }, isolate = false })
    h.fakes.agents({ F.pane("w1:p2", "Other", F.new_dir()) })
    local root = F.new_dir()
    h.state.set(root, "target", { target = "herdr", id = "w1:p1" })
    local status = h.ap.poke(root, "hello")
    assert.is_truthy(status == "started" or status == "queued", "status: " .. tostring(status))
    h.wait_claude(1)
    assert.are.equal(1, #gone_notes(), vim.inspect(h.notes))
  end)
end)
