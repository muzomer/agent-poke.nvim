-- agent-poke_nvim-0d8.1: the target interface and registry; the background
-- agent is the only built-in target.
--
-- Interface (lua/agent-poke/init.lua):
--   ap.register_target(spec)   -- spec = { name, available?(), list(root) -> { {id, title, ...} },
--                                 deliver(root, entry, prompt, opts) -> status, err, progress?(handle) }
--                                 name and deliver are required; a duplicate name is
--                                 rejected with a notification (the first one stays)
--   ap.setup({ targets = { spec, ... } })
--   ap.pick(root)              -- the background agent plus every available target's entries;
--                                 the choice is stored per root: state key target = { target = name, id }
--   ap.poke(root, prompt)      -- no targets: always the background agent, never a picker;
--                                 a remembered target entry: its deliver(), whose status is returned
--
-- Fakes: tests/helpers.install_fakes puts fake `claude` and `herdr` first on
-- PATH; HERDR_SOCKET_PATH / HERDR_PANE_ID are set so that a core that still
-- talks to herdr by default would run the fake (and be caught). The real
-- herdr / claude are never run.
local helpers = require("tests.helpers")

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

-- What the picker shows for an item (its shape is the implementation's choice).
local function label(opts, item)
  if opts and opts.format_item then
    return tostring(opts.format_item(item))
  end
  if type(item) == "table" then
    return tostring(item.title or item.label or item.name or vim.inspect(item))
  end
  return tostring(item)
end

describe("agent-poke targets", function()
  local ap, state, fakes, notes, selects, roots
  local old_notify, old_select, old_state_home, old_socket, old_pane

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_socket, old_pane = vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname()
    vim.env.HERDR_PANE_ID = "w1:p5"
    fakes = helpers.install_fakes()
    old_notify, old_select = vim.notify, vim.ui.select
    notes, selects, roots = {}, {}, {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    -- default: record the picker and choose nothing
    vim.ui.select = function(items, opts, on_choice)
      selects[#selects + 1] = { items = items, opts = opts }
      on_choice(nil)
    end
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
  end)

  after_each(function()
    local headless = package.loaded["agent-poke.headless"]
    if headless then
      for _, r in ipairs(roots) do
        pcall(headless.stop, r)
      end
      vim.wait(2000, function()
        for _, r in ipairs(roots) do
          if headless.running(r) then
            return false
          end
        end
        return true
      end, 20)
    end
    vim.notify, vim.ui.select = old_notify, old_select
    fakes.restore()
    vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID = old_socket, old_pane
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
  end)

  local function root()
    local r = new_root()
    roots[#roots + 1] = r
    return r
  end

  local function warned()
    for _, n in ipairs(notes) do
      if (n.level or vim.log.levels.INFO) >= vim.log.levels.WARN then
        return true
      end
    end
    return false
  end

  ---A fake target recording its calls.
  local function fake(name, opts)
    opts = opts or {}
    local t = { listed = {}, delivered = {} }
    t.spec = {
      name = name,
      available = function()
        return opts.available ~= false
      end,
      list = function(r)
        t.listed[#t.listed + 1] = r
        return opts.entries or { { id = "a", title = "Alpha " .. name }, { id = "b", title = "Beta " .. name } }
      end,
      deliver = function(r, entry, prompt, o)
        t.delivered[#t.delivered + 1] = { root = r, entry = entry, prompt = prompt, opts = o }
        return opts.status or "typed"
      end,
    }
    return t
  end

  describe("default (no targets configured)", function()
    it("poke() uses the background agent, shows no picker and runs no multiplexer", function()
      local r = root()
      local status = ap.poke(r, "hello")
      assert.are.equal("started", status)
      vim.wait(100)
      assert.are.equal(0, #selects, "no picker without targets")
      assert.is_true(vim.wait(5000, function()
        local s = ap.status(r)
        return s ~= nil and s.status ~= "working"
      end, 20), "the background run did not finish")
      assert.are.equal("done", ap.status(r).status)
      assert.are.equal(1, #fakes.calls("claude"))
      assert.are.equal(0, #fakes.calls("herdr"), "herdr must not be executed by default")
    end)

    it("pick() offers only the background agent (or nothing, with a notice) and runs no multiplexer", function()
      local r = root()
      ap.pick(r)
      vim.wait(100, function()
        return #selects > 0
      end, 10)
      if #selects > 0 then
        assert.are.equal(1, #selects)
        assert.are.equal(1, #selects[1].items, "only the background agent is offered")
      else
        assert.is_true(#notes > 0, "pick() without targets must tell the user something")
      end
      assert.are.equal(0, #fakes.calls("herdr"), "herdr must not be executed by default")
    end)
  end)

  describe("register_target", function()
    it("rejects a spec without a name", function()
      local t = fake(nil)
      assert.is_function(ap.register_target)
      local ok = pcall(ap.register_target, t.spec)
      assert.is_true(not ok or warned(), "an invalid spec must be reported")
      ap.pick(root())
      vim.wait(100)
      assert.are.equal(0, #t.listed, "a rejected spec must not be used")
    end)

    it("rejects a spec without deliver", function()
      local t = fake("nodeliver")
      t.spec.deliver = nil
      assert.is_function(ap.register_target)
      local ok = pcall(ap.register_target, t.spec)
      assert.is_true(not ok or warned(), "an invalid spec must be reported")
      ap.pick(root())
      vim.wait(100)
      assert.are.equal(0, #t.listed, "a rejected spec must not be used")
    end)

    it("rejects a duplicate name with a notification and keeps the first", function()
      local a = fake("dup", { status = "typed" })
      local b = fake("dup", { status = "queued" })
      ap.register_target(a.spec)
      assert.is_false(warned(), "a valid first registration is not an error")
      ap.register_target(b.spec)
      assert.is_true(warned(), "a duplicate name must be reported")
      local r = root()
      state.set(r, "target", { target = "dup", id = "a" })
      assert.are.equal("typed", ap.poke(r, "hi"))
      assert.are.equal(1, #a.delivered)
      assert.are.equal(0, #b.delivered)
    end)
  end)

  describe("with a fake target", function()
    it("pick() lists the background agent plus the target's entries and remembers the choice per root", function()
      local t = fake("fake")
      ap.register_target(t.spec)
      local r, other = root(), root()
      vim.ui.select = function(items, opts, on_choice)
        selects[#selects + 1] = { items = items, opts = opts }
        for _, item in ipairs(items) do
          if label(opts, item):find("Alpha fake", 1, true) then
            return on_choice(item, _)
          end
        end
        on_choice(nil)
      end
      ap.pick(r)
      assert.is_true(vim.wait(1000, function()
        return #selects > 0
      end, 10), "pick() did not open a picker")
      local items, opts = selects[1].items, selects[1].opts
      assert.are.equal(3, #items, "background agent + 2 entries")
      local alpha, beta = 0, 0
      for _, item in ipairs(items) do
        local l = label(opts, item)
        if l:find("Alpha fake", 1, true) then
          alpha = alpha + 1
        elseif l:find("Beta fake", 1, true) then
          beta = beta + 1
        end
      end
      assert.are.same({ 1, 1 }, { alpha, beta })
      assert.are.same({ r }, t.listed)
      local saved = state.get(r).target
      assert.are.equal("table", type(saved))
      assert.are.equal("fake", saved.target)
      assert.are.equal("a", saved.id)
      assert.is_nil(state.get(other).target, "the choice is per root")
    end)

    it("poke() delivers through the remembered entry and returns its status", function()
      local t = fake("fake", { status = "typed" })
      ap.register_target(t.spec)
      local r = root()
      vim.ui.select = function(items, opts, on_choice)
        selects[#selects + 1] = { items = items, opts = opts }
        for _, item in ipairs(items) do
          if label(opts, item):find("Alpha fake", 1, true) then
            return on_choice(item, _)
          end
        end
        on_choice(nil)
      end
      ap.pick(r)
      vim.wait(1000, function()
        return state.get(r).target ~= nil
      end, 10)
      local before = #selects
      assert.are.equal("typed", ap.poke(r, "hello"))
      assert.are.equal(before, #selects, "a remembered choice needs no picker")
      assert.are.equal(1, #t.delivered)
      local d = t.delivered[1]
      assert.are.equal(r, d.root)
      assert.are.equal("a", d.entry.id)
      assert.are.equal("hello", d.prompt)
      assert.are.equal(0, #fakes.calls("claude"), "the background agent is not used")
      assert.are.equal(0, #fakes.calls("herdr"))
    end)

    it("poke() honours a stored { target = name, id } and returns the target's status", function()
      local t = fake("fake", { status = "queued" })
      ap.register_target(t.spec)
      local r = root()
      state.set(r, "target", { target = "fake", id = "b" })
      assert.are.equal("queued", ap.poke(r, "x"))
      assert.are.equal(0, #selects)
      assert.are.equal(1, #t.delivered)
      assert.are.equal("b", t.delivered[1].entry.id)
      assert.are.equal("x", t.delivered[1].prompt)
    end)

    it("pick() leaves out the entries of a target that is not available", function()
      local up = fake("up")
      local down = fake("down", { available = false })
      ap.register_target(up.spec)
      ap.register_target(down.spec)
      ap.pick(root())
      assert.is_true(vim.wait(1000, function()
        return #selects > 0
      end, 10), "pick() did not open a picker")
      local items, opts = selects[1].items, selects[1].opts
      assert.are.equal(3, #items, "background agent + the available target's 2 entries")
      for _, item in ipairs(items) do
        assert.is_nil(label(opts, item):find(" down", 1, true), "entry of an unavailable target offered")
      end
    end)

    it("setup({ targets = { spec } }) registers the spec", function()
      local t = fake("viasetup", { status = "typed" })
      ap.setup({ targets = { t.spec } })
      local r = root()
      state.set(r, "target", { target = "viasetup", id = "a" })
      assert.are.equal("typed", ap.poke(r, "y"))
      assert.are.equal(1, #t.delivered)
    end)
  end)
end)
