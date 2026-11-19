-- agent-poke_nvim-0d8.1 finding (tests/targets_spec.lua:137): the default
-- cases must also hold after setup() itself, not only with ap.config set
-- directly. setup({}) and setup({ headless = { agent = "claude" } }) must not
-- map the default agent = "auto" onto the herdr target: poke() runs the
-- background agent and pick() offers only it, with 0 herdr calls.
--
-- Fakes: tests/helpers.install_fakes puts fake `claude` and `herdr` first on
-- PATH; HERDR_SOCKET_PATH / HERDR_PANE_ID are set so that a herdr target that
-- got enabled would run the fake (and be caught).
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

describe("agent-poke default targets through setup()", function()
  local ap, fakes, notes, selects, roots
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
    vim.ui.select = function(items, opts, on_choice)
      selects[#selects + 1] = { items = items, opts = opts }
      on_choice(nil)
    end
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
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

  local cases = {
    { "setup({})", {} },
    { 'setup({ headless = { agent = "claude" } })', { headless = { agent = "claude" } } },
  }

  for _, case in ipairs(cases) do
    local name, opts = case[1], case[2]

    describe("after " .. name, function()
      it("poke() uses the background agent, shows no picker and runs no herdr", function()
        ap.setup(vim.deepcopy(opts))
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

      it("pick() offers only the background agent (or nothing, with a notice) and runs no herdr", function()
        ap.setup(vim.deepcopy(opts))
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
  end
end)
