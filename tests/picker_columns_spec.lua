-- agent-poke_nvim-hla (nit 7): picker rows line up. The background item has
-- the same columns as the target entries (title, status, cwd), so its status
-- and cwd columns start where a herdr row's do.
--
-- The columns are derived from the herdr row (where its status "idle" and its
-- cwd start), not hard-coded; what the background row shows in them is not
-- checked, only that each column starts at the same place.
--
-- Fakes: tests/herdr_fakes.lua (fake `herdr` and `claude` on PATH).
local F = require("tests.herdr_fakes")

describe("picker rows", function()
  local h = F.harness()

  local function find_label(labels, text)
    for _, l in ipairs(labels) do
      if l:find(text, 1, true) then
        return l
      end
    end
  end

  ---Display column (1-based) where byte `i` of `s` starts.
  local function col(s, i)
    return vim.fn.strdisplaywidth(s:sub(1, i - 1)) + 1
  end

  ---The character at display column `c` of `s` ("" past the end).
  local function char_at(s, c)
    local chars = vim.fn.split(s, "\\zs")
    local w = 0
    for _, ch in ipairs(chars) do
      w = w + vim.fn.strdisplaywidth(ch)
      if w >= c then
        return ch
      end
    end
    return ""
  end

  it("the background row's status and cwd columns start where the herdr row's do", function()
    h.ap.setup({ targets = { "herdr" }, isolate = false })
    local pane_dir = F.new_dir()
    h.fakes.agents({ F.pane("w1:p1", "Review PR", pane_dir) })
    h.ap.pick(F.new_dir())
    assert.are.equal(1, #h.selects, "the picker did not open; notes: " .. vim.inspect(h.notes))
    local labels = h.selects[1].labels
    local pane = find_label(labels, "Review PR")
    local bg = find_label(labels, "(background)")
    assert.is_truthy(pane and bg, vim.inspect(labels))

    local status_at = pane:find("idle", 1, true)
    local shown_dir = (pane_dir:gsub("^" .. vim.pesc(vim.env.HOME or "\0"), "~"))
    local cwd_at = pane:find(shown_dir, 1, true)
    assert.is_truthy(status_at and cwd_at, "test setup: herdr row has no status/cwd column: " .. pane)
    local columns = { col(pane, status_at), col(pane, cwd_at) }

    for _, c in ipairs(columns) do
      assert.are.equal(" ", char_at(bg, c - 1),
        string.format("background row: column %d must start after a space:\n%s\n%s", c, pane, bg))
      assert.is_truthy(char_at(bg, c):match("%S"),
        string.format("background row: nothing in the column at %d:\n%s\n%s", c, pane, bg))
    end
  end)
end)
