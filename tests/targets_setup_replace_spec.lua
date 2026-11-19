-- agent-poke_nvim-0d8.2 (reviewer nit from 0d8.1): setup() replaces the
-- target list. Calling setup() again (a config reload) does not warn about
-- duplicate names, and the targets of the last call are the only ones used.
local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.uv.fs_realpath(d) or d)
end

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("setup() replaces the target list", function()
  local ap, state, notes, selects
  local old_notify, old_select, old_state_home

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify, old_select = vim.notify, vim.ui.select
    notes, selects = {}, {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    vim.ui.select = function(items, opts, on_choice)
      local labels = {}
      for _, item in ipairs(items) do
        labels[#labels + 1] = tostring(opts and opts.format_item and opts.format_item(item) or item.title)
      end
      selects[#selects + 1] = labels
      on_choice(nil)
    end
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
  end)

  after_each(function()
    vim.notify, vim.ui.select = old_notify, old_select
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
  end)

  local function warnings()
    return vim.tbl_filter(function(n)
      return (n.level or vim.log.levels.INFO) >= vim.log.levels.WARN
    end, notes)
  end

  local function fake(name, status)
    local t = { delivered = 0 }
    t.spec = {
      name = name,
      list = function()
        return { { id = "a", title = "Alpha " .. name } }
      end,
      deliver = function()
        t.delivered = t.delivered + 1
        return status or "typed"
      end,
    }
    return t
  end

  it("the same targets again: no duplicate warning, and the newer spec is used", function()
    local first, second = fake("same", "typed"), fake("same", "queued")
    ap.setup({ targets = { first.spec } })
    ap.setup({ targets = { second.spec } })
    assert.are.same({}, warnings())
    local r = new_root()
    state.set(r, "target", { target = "same", id = "a" })
    assert.are.equal("queued", ap.poke(r, "hi"))
    assert.are.equal(0, first.delivered)
    assert.are.equal(1, second.delivered)
  end)

  it("other targets: pick() lists only the last call's targets", function()
    local a, b = fake("one"), fake("two")
    ap.setup({ targets = { a.spec } })
    ap.setup({ targets = { b.spec } })
    ap.pick(new_root())
    assert.is_true(vim.wait(1000, function()
      return #selects > 0
    end, 10), "pick() did not open a picker")
    local all = table.concat(selects[1], "\n")
    assert.are.equal(2, #selects[1], all) -- background + Alpha two
    assert.is_truthy(all:find("Alpha two", 1, true), all)
    assert.is_falsy(all:find("Alpha one", 1, true), all)
  end)
end)
