-- agent-poke_nvim-hf4: a poke while chat(root) has the same session open
-- must not run the agent on that session (code-review.nvim 7e2d74ca,
-- headless.lua send(): refuse, copy the prompt to a register, notify).
--
-- The chat runs the fake `claude` from tests/helpers.lua in a real terminal:
-- its `cat > stdin` reads the pty, so it stays open until the test stops the
-- job. headless.spawn (documented as replaceable in tests) is replaced by a
-- double that records each run and starts no process.
local helpers = require("tests.helpers")

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.fn.fnamemodify(d, ":p"):gsub("/$", ""))
end

describe("agent-poke.headless poke while a chat is open", function()
  local headless, state, fakes, old_state_home, old_notify, old_spawn, notes, spawns, roots, chat_wins

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    fakes = helpers.install_fakes()
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    roots, spawns, chat_wins = {}, {}, {}
    package.loaded["agent-poke.state"] = nil
    package.loaded["agent-poke.headless"] = nil
    require("agent-poke").config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
    old_spawn = headless.spawn
    headless.spawn = function(args, cwd, on_line, on_exit)
      local s = { args = args, cwd = cwd, on_line = on_line, on_exit = on_exit }
      spawns[#spawns + 1] = s
      return { kill = function() end }
    end
    vim.fn.setreg('"', "")
  end)

  local function close_chat(entry)
    if entry.job then
      pcall(vim.fn.jobstop, entry.job)
      pcall(vim.fn.jobwait, { entry.job }, 2000)
    end
    if vim.api.nvim_win_is_valid(entry.win) then
      pcall(vim.api.nvim_win_close, entry.win, true)
    end
    if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
    end
    vim.wait(100) -- let the job's on_exit callback run
  end

  after_each(function()
    for _, c in ipairs(chat_wins) do
      close_chat(c)
    end
    for _, r in ipairs(roots) do
      pcall(headless.stop, r)
    end
    vim.cmd("stopinsert")
    headless.spawn = old_spawn
    vim.notify = old_notify
    fakes.restore()
    vim.env.XDG_STATE_HOME = old_state_home
    require("agent-poke").config = require("agent-poke.defaults")()
  end)

  local function root()
    local r = new_root()
    roots[#roots + 1] = r
    return r
  end

  ---Open chat(r) on a stored session; returns the terminal's { win, buf, job }.
  local function open_chat(r)
    state.set(r, "session", { id = "sess-" .. #roots, agent = "claude" })
    local before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      before[w] = true
    end
    headless.chat(r)
    vim.cmd("stopinsert")
    local entry
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if not before[w] and vim.bo[b].buftype == "terminal" then
        entry = { win = w, buf = b, job = vim.b[b].terminal_job_id }
      end
    end
    assert.is_not_nil(entry, "chat opened no terminal; notes: " .. vim.inspect(notes))
    chat_wins[#chat_wins + 1] = entry
    -- the chat's process is up (the fake recorded its argv) and still running
    assert.is_true(vim.wait(5000, function()
      return #fakes.calls("claude") >= 1
    end, 20), "the chat's fake claude never started")
    assert.are.equal(-1, vim.fn.jobwait({ entry.job }, 0)[1], "the chat terminal exited on its own")
    notes = {}
    return entry
  end

  it("refuses the poke: no process, the prompt in the \" register, one one-line notice about the chat", function()
    local r = root()
    open_chat(r)

    local started = headless.poke(r, "please review the diff")

    assert.is_false(started)
    assert.are.equal(0, #spawns, "a run was started on the session the chat has open")
    assert.is_nil(headless.status(r))
    assert.are.equal(1, #fakes.calls("claude"), "a second claude process was started")
    assert.are.equal("please review the diff", vim.fn.getreg('"'))
    assert.are.equal(1, #notes, "notices: " .. vim.inspect(notes))
    assert.is_nil(notes[1].msg:find("\n", 1, true), "the notice spans more than one line")
    assert.is_truthy(notes[1].msg:lower():find("chat", 1, true), "the notice does not mention the chat: " .. notes[1].msg)
  end)

  it("pokes run again after the chat terminal closes", function()
    local r = root()
    local entry = open_chat(r)
    assert.is_false(headless.poke(r, "while open"))
    assert.are.equal(0, #spawns)

    close_chat(entry)
    vim.fn.setreg('"', "")
    notes = {}

    local started, how = headless.poke(r, "after close")
    assert.is_true(started, "notes: " .. vim.inspect(notes))
    assert.are.equal("started", how)
    assert.are.equal(1, #spawns)
    assert.are.equal(r, spawns[1].cwd)
    assert.are.equal("", vim.fn.getreg('"'))
  end)

  it("a chat open on one root does not affect pokes of another root", function()
    local a = root()
    local b = root()
    open_chat(a)

    local started, how = headless.poke(b, "for root b")
    assert.is_true(started, "notes: " .. vim.inspect(notes))
    assert.are.equal("started", how)
    assert.are.equal(1, #spawns)
    assert.are.equal(b, spawns[1].cwd)
    assert.are.equal("", vim.fn.getreg('"'))
  end)
end)
