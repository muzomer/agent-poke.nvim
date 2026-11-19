-- agent-poke_nvim-5h5 (blocker): a failed background delivery in the core path
-- (the background agent chosen directly, re-picked with poke({ pick = true }),
-- or chosen in the picker of the first poke) notifies once (one line) and
-- copies the prompt to the " register; nothing is stored as the chosen target.
--
-- Everything goes through the core API (require("agent-poke")). The background
-- agent's command is the fake `claude` of tests/helpers.install_fakes, rewritten
-- with a missing interpreter: it is executable (so the picker offers it) but
-- cannot be started (vim.system throws ENOENT). It is configured by absolute
-- path (config.headless.cmd) and PATH holds only the fakes and /usr/bin:/bin,
-- so a failed exec never falls through to a real `claude`. The other target is a plain
-- table registered with register_target (a test double; it never delivers).
local helpers = require("tests.helpers")

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return assert(vim.uv.fs_realpath(d))
end

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("a failed background delivery through the core API", function()
  local ap, state, fakes, notes, selects, choose, delivered
  local old_state_home, old_notify, old_select, old_path

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_path = vim.env.PATH
    fakes = helpers.install_fakes()
    -- an executable `claude` whose interpreter is missing: spawning it fails
    local f = assert(io.open(fakes.bin .. "/claude", "w"))
    f:write("#!/nonexistent/agent-poke-test/interp\necho never\n")
    f:close()
    vim.uv.fs_chmod(fakes.bin .. "/claude", tonumber("755", 8))
    vim.env.PATH = fakes.bin .. ":/usr/bin:/bin"

    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    old_select = vim.ui.select
    selects, choose = {}, nil
    vim.ui.select = function(items, o, cb)
      local picked
      local labels = {}
      for _, item in ipairs(items) do
        local label = tostring(o and o.format_item and o.format_item(item) or item.title or item)
        labels[#labels + 1] = label
        if not picked and choose and label:find(choose, 1, true) then
          picked = item
        end
      end
      selects[#selects + 1] = labels
      cb(picked)
    end
    vim.fn.setreg('"', "")

    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    delivered = {}
  end)

  after_each(function()
    local headless = package.loaded["agent-poke.headless"]
    if headless then
      pcall(headless.stop_all)
    end
    vim.notify = old_notify
    vim.ui.select = old_select
    fakes.restore()
    vim.env.PATH = old_path -- after restore(): it would put back the fakes-first PATH
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
  end)

  ---Enable a second target ("other", one entry "e1") besides the background agent.
  ---setup() with the unstartable fake as the background agent's command.
  local function setup()
    ap.setup({ headless = { cmd = fakes.bin .. "/claude" } })
  end

  local function with_other_target()
    setup()
    assert.is_true(ap.register_target({
      name = "other",
      list = function()
        return { { id = "e1", title = "Other entry" } }
      end,
      deliver = function(root, entry, prompt)
        delivered[#delivered + 1] = { root = root, id = entry.id, prompt = prompt }
        return "typed"
      end,
    }))
  end

  local function assert_one_line_notice_and_register(prompt)
    assert.are.equal(1, #notes, "expected exactly one notification: " .. vim.inspect(notes))
    assert.is_nil(notes[1].msg:find("\n", 1, true), "the notification spans more than one line: " .. notes[1].msg)
    assert.are.equal(prompt, vim.fn.getreg('"'), "the prompt was not copied to the \" register")
  end

  it("with no other target (background agent directly): one one-line notice, prompt in the \" register", function()
    setup()
    local root = new_root()
    local status = ap.poke(root, "direct prompt")
    assert.is_false(status)
    assert.are.equal(0, #fakes.calls("claude"))
    assert_one_line_notice_and_register("direct prompt")
    assert.is_nil(state.get(root).target, "a failed delivery stored a target")
  end)

  it("with the background agent stored as the choice: one one-line notice, prompt in the \" register", function()
    with_other_target()
    local root = new_root()
    state.set(root, "target", { target = "background" })
    local status = ap.poke(root, "stored background prompt")
    assert.is_false(status)
    assert.are.equal(0, #selects, "a stored choice must not open the picker")
    assert_one_line_notice_and_register("stored background prompt")
    assert.are.same({ target = "background" }, state.get(root).target)
  end)

  it("after re-picking (background): one one-line notice, prompt in the \" register, the old choice is kept", function()
    with_other_target()
    local root = new_root()
    state.set(root, "target", { target = "other", id = "e1" })
    choose = "(background)"
    local status = ap.poke(root, "re-picked prompt", { pick = true })
    assert.are.equal(1, #selects, "pick = true must open the picker; notes: " .. vim.inspect(notes))
    assert.is_false(status)
    assert.are.equal(0, #delivered, "the other target got the prompt")
    assert_one_line_notice_and_register("re-picked prompt")
    assert.are.same({ target = "other", id = "e1" }, state.get(root).target,
      "a failed delivery must not replace the stored choice")
  end)

  it("first poke through the picker, (background) chosen: one one-line notice, prompt in the \" register, nothing stored", function()
    with_other_target()
    local root = new_root()
    choose = "(background)"
    local status = ap.poke(root, "first picked prompt")
    assert.are.equal(1, #selects, "the first poke must open the picker; notes: " .. vim.inspect(notes))
    assert.is_false(status)
    assert.are.equal(0, #delivered, "the other target got the prompt")
    assert_one_line_notice_and_register("first picked prompt")
    assert.is_nil(state.get(root).target, "a failed delivery must not be stored")
  end)
end)
