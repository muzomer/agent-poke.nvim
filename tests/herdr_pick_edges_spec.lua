-- agent-poke_nvim-ei4.3: picker edge cases (lua/agent-poke/targets/herdr.lua).
--   * "(background)" is offered only when the background agent is available
--     (headless.available()).
--   * The picked target is stored (state key `target`) only after the prompt
--     was delivered to it.
--   * When the remembered pane is gone, the user picks another and delivery to
--     it fails too: one notification (one line) for the failure, and the prompt
--     is copied to the " register so it is not lost.
--
-- Fakes (test doubles): `herdr` answers `agent list` from <log>/agents.json and
-- `agent prompt` from <log>/prompt.json (default {"result":{"ok":true}}), and
-- records argv; `claude` prints stream-json and exits at once. PATH holds only
-- the fakes and /usr/bin:/bin. Every fake exits at once; waits are bounded.
local uv = vim.uv or vim.loop

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function new_dir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return uv.fs_realpath(d)
end

local HERDR = [[#!/bin/sh
log="%s"
n=$(cat "$log/herdr.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/herdr.n"
d="$log/herdr.$n"; mkdir -p "$d"
printf '%%s ' "$@" > "$d/argv"
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  cat "$log/agents.json"
elif [ -f "$log/prompt.json" ]; then
  cat "$log/prompt.json"
else
  printf '%%s\n' '{"result":{"ok":true}}'
fi
touch "$d/done"
]]

local CLAUDE = [[#!/bin/sh
log="%s"
n=$(cat "$log/claude.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/claude.n"
d="$log/claude.$n"; mkdir -p "$d"
printf '%%s\n' '{"type":"system","subtype":"init","session_id":"fake-session"}'
printf '%%s\n' '{"type":"result","subtype":"success","result":"ok","session_id":"fake-session"}'
touch "$d/done"
]]

local function install()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  write(bin .. "/herdr", string.format(HERDR, log))
  write(bin .. "/claude", string.format(CLAUDE, log))
  uv.fs_chmod(bin .. "/herdr", tonumber("755", 8))
  uv.fs_chmod(bin .. "/claude", tonumber("755", 8))
  local self = { bin = bin, log = log }
  function self.pending()
    for _, name in ipairs({ "herdr", "claude" }) do
      local n = tonumber(vim.trim(read(log .. "/" .. name .. ".n") or "0")) or 0
      for i = 1, n do
        if not uv.fs_stat(log .. "/" .. name .. "." .. i .. "/done") then
          return true
        end
      end
    end
    return false
  end
  function self.prompts()
    local list = {}
    local n = tonumber(vim.trim(read(log .. "/herdr.n") or "0")) or 0
    for i = 1, n do
      local argv = read(log .. "/herdr." .. i .. "/argv") or ""
      if argv:find("^agent prompt ") then
        list[#list + 1] = argv
      end
    end
    return list
  end
  function self.agents(list)
    write(log .. "/agents.json", vim.json.encode({ result = { agents = list } }))
  end
  function self.prompt_fails(message)
    write(log .. "/prompt.json", vim.json.encode({ error = { code = "pane_not_found", message = message } }) .. "\n")
  end
  return self
end

local function pane(id, title, cwd)
  return { pane_id = id, agent = "claude", agent_status = "idle", cwd = cwd, terminal_title_stripped = title }
end

describe("agent-poke.herdr picker edge cases", function()
  local herdr, state, headless, fakes, notes, offered, choose, on_select
  local saved_env, old_notify, old_select

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
    }
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    fakes = install()
    vim.env.PATH = fakes.bin .. ":/usr/bin:/bin"
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname() .. ".sock"
    vim.env.HERDR_PANE_ID = "w1:p5"
    vim.env.CLAUDE_CONFIG_DIR = new_dir()

    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    old_select = vim.ui.select
    offered, choose, on_select = nil, nil, nil
    vim.ui.select = function(items, opts, cb)
      offered = {}
      local picked
      for _, item in ipairs(items) do
        local label = tostring(opts and opts.format_item and opts.format_item(item) or item.title)
        offered[#offered + 1] = label
        if choose and not picked and label:find(choose, 1, true) then
          picked = item
        end
      end
      if on_select then
        on_select()
      end
      cb(picked)
    end

    require("agent-poke").config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
    herdr = require("agent-poke.targets.herdr")
  end)

  after_each(function()
    if headless then
      headless.stop_all()
    end
    if fakes then
      vim.wait(5000, function()
        return not fakes.pending()
      end, 20)
      vim.wait(100)
    end
    vim.notify = old_notify
    vim.ui.select = old_select
    for k, v in pairs(saved_env) do
      vim.env[k] = v
    end
    require("agent-poke").config = require("agent-poke.defaults")()
  end)

  local function has_background(list)
    for _, label in ipairs(list or {}) do
      if label:find("(background)", 1, true) then
        return true
      end
    end
    return false
  end

  describe("(background) in the picker", function()
    it("is not offered when the background agent's executable is missing", function()
      local cfg = require("agent-poke").config
      cfg.isolate = false
      cfg.headless.cmd = "agent-poke-no-such-agent-cmd"
      assert.is_false(headless.available(), "test setup: the background agent must be unavailable")
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      herdr.pick(new_dir())
      assert.is_not_nil(offered, "the picker did not open; notes: " .. vim.inspect(notes))
      assert.is_false(has_background(offered), "(background) offered although unavailable: " .. vim.inspect(offered))
      local found = false
      for _, label in ipairs(offered) do
        found = found or label:find("Review PR", 1, true) ~= nil
      end
      assert.is_true(found, "the herdr agent was not offered: " .. vim.inspect(offered))
    end)

    it("is offered when the background agent is available (passes already)", function()
      require("agent-poke").config.isolate = false
      assert.is_true(headless.available(), "test setup: the fake claude must be found")
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      herdr.pick(new_dir())
      assert.is_not_nil(offered, "the picker did not open; notes: " .. vim.inspect(notes))
      assert.is_true(has_background(offered), "(background) not offered: " .. vim.inspect(offered))
    end)
  end)

  describe("storing the choice", function()
    it("does not store a picked pane when the prompt could not be delivered to it", function()
      require("agent-poke").config.isolate = false
      local root = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      fakes.prompt_fails("no pane w1:p1")
      choose = "Review PR"
      local res = herdr.poke(root, "please check the comments")
      assert.is_not_nil(offered, "the picker did not open; notes: " .. vim.inspect(notes))
      assert.equals(1, #fakes.prompts(), "expected one prompt attempt; notes: " .. vim.inspect(notes))
      assert.is_false(res)
      local t = state.get(root).target
      assert.is_nil(t, "the failed choice was stored: " .. vim.inspect(t))
    end)

    it("stores the picked pane once the prompt was delivered (passes already)", function()
      require("agent-poke").config.isolate = false
      local root = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      choose = "Review PR"
      local res = herdr.poke(root, "please check the comments")
      assert.equals("typed", res, "notes: " .. vim.inspect(notes))
      local t = state.get(root).target
      assert.is_table(t)
      assert.equals("w1:p1", t.pane_id)
    end)
  end)

  describe("re-pick after the remembered pane is gone (agent = herdr)", function()
    it("keeps the prompt when delivery to the newly picked pane fails: one line, \" register", function()
      local cfg = require("agent-poke").config
      cfg.isolate = false
      cfg.agent = "herdr"
      local root = new_dir()
      state.set(root, "target", { pane_id = "w1:p9", title = "Gone agent" }) -- not in herdr's list
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      fakes.prompt_fails("no pane w1:p1\nrun herdr agent list to see the panes") -- two lines
      vim.fn.setreg('"', "something else")
      local prompt = "please check the comments\nin src/main.lua"
      choose = "Review PR"
      local before_pick
      on_select = function()
        before_pick = #notes
      end

      local res = herdr.poke(root, prompt)

      assert.is_not_nil(offered, "the picker did not open; notes: " .. vim.inspect(notes))
      assert.equals(1, #fakes.prompts(), "expected one prompt attempt; notes: " .. vim.inspect(notes))
      assert.is_false(res)
      local after = vim.list_slice(notes, before_pick + 1)
      assert.equals(1, #after, "expected one notification for the failed delivery, got: " .. vim.inspect(after))
      assert.is_nil(after[1].msg:find("\n", 1, true), "the notification is not one line: " .. vim.inspect(after[1].msg))
      assert.equals(prompt, (vim.fn.getreg('"'):gsub("\n$", "")), "the prompt was not copied to the \" register")
      local t = state.get(root).target
      assert.is_false(type(t) == "table" and t.pane_id == "w1:p1", "the failed choice was stored: " .. vim.inspect(t))
    end)
  end)
end)
