-- agent-poke_nvim-wtd.4: herdr targets (pick, fork vs type, per-root memory).
--
-- Interface (lua/agent-poke/herdr.lua), ported from code-review.nvim's poke.lua:
--   herdr.pick(root)          -- vim.ui.select over the herdr agent panes (this
--                                pane left out) plus "… (background)"; the choice
--                                is stored per root with agent-poke.state (key `target`)
--   herdr.poke(root, prompt)  -- deliver `prompt` to root's remembered target
--                                (picking one first when none is remembered):
--     * isolate = "fork" and a Claude pane whose transcript is found
--       ($CLAUDE_CONFIG_DIR/projects/<dir>/<session>.jsonl): a throwaway
--       `claude -p <prompt> --resume <id> --fork-session` in the session's directory;
--     * otherwise typed into the pane: `herdr agent prompt <pane> <text>`, the
--       text asking Claude to use a subagent unless isolate == false;
--     * herdr missing, or the remembered pane gone: the background agent
--       (agent-poke.headless) gets the prompt.
--
-- Fakes (test doubles, defined here): `herdr` answers `agent list` from a
-- per-test agents.json and records argv; `claude` records argv and cwd, prints
-- stream-json and exits at once. PATH holds only the fakes and /usr/bin:/bin, so
-- the real herdr / claude are never reached.
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

-- Records argv (NUL-separated) and `pwd -P` per call in <log>/<name>.<n>/,
-- then runs the body.
local RECORD = [[#!/bin/sh
log="%s"
name="%s"
n=$(cat "$log/$name.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/$name.n"
d="$log/$name.$n"; mkdir -p "$d"
: > "$d/argv.tmp"
for a in "$@"; do printf '%%s\0' "$a" >> "$d/argv.tmp"; done
mv "$d/argv.tmp" "$d/argv"
pwd -P > "$d/cwd"
%s
]]

local HERDR_BODY = [[
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  cat "$log/agents.json"
else
  printf '%s\n' '{"result":{"ok":true}}'
fi
touch "$d/done"
]]

local CLAUDE_BODY = [[
sid=fake-session; prev=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  prev=$a
done
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
touch "$d/done"
]]

local function install()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  for name, body in pairs({ herdr = HERDR_BODY, claude = CLAUDE_BODY }) do
    write(bin .. "/" .. name, string.format(RECORD, log, name, body))
    uv.fs_chmod(bin .. "/" .. name, tonumber("755", 8))
  end
  local self = { bin = bin, log = log }
  function self.calls(name)
    local list = {}
    local n = tonumber(vim.trim(read(log .. "/" .. name .. ".n") or "0")) or 0
    for i = 1, n do
      local d = log .. "/" .. name .. "." .. i
      local raw = read(d .. "/argv")
      if raw then
        local argv = {}
        for a in raw:gmatch("([^%z]*)%z") do
          argv[#argv + 1] = a
        end
        list[#list + 1] = { argv = argv, cwd = vim.trim(read(d .. "/cwd") or ""), done = uv.fs_stat(d .. "/done") ~= nil }
      end
    end
    return list
  end
  function self.agents(list)
    write(log .. "/agents.json", vim.json.encode({ result = { agents = list } }))
  end
  function self.remove_herdr()
    os.remove(bin .. "/herdr")
  end
  return self
end

local OWN = "w1:p5" -- the pane this Neovim runs in

local function pane(id, title, cwd, session)
  return {
    pane_id = id,
    agent = "claude",
    agent_status = "idle",
    cwd = cwd,
    terminal_title_stripped = title,
    agent_session = session and { value = session } or nil,
  }
end

local function arg_after(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

local function has(argv, flag)
  return vim.tbl_contains(argv, flag)
end

describe("agent-poke.herdr", function()
  local herdr, state, headless, fakes, notes, selects, choose
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
    vim.env.HERDR_PANE_ID = OWN
    vim.env.CLAUDE_CONFIG_DIR = new_dir()

    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    old_select = vim.ui.select
    selects = 0
    choose = nil -- substring of the item label to choose; nil dismisses the picker
    vim.ui.select = function(items, opts, cb)
      selects = selects + 1
      local picked
      for _, item in ipairs(items) do
        local label = opts and opts.format_item and opts.format_item(item)
          or (type(item) == "table" and (item.title or item.pane_id))
          or tostring(item)
        if choose and tostring(label):find(choose, 1, true) then
          picked = item
          break
        end
      end
      cb(picked)
    end

    require("agent-poke").config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
    herdr = require("agent-poke.herdr")
  end)

  after_each(function()
    if headless then
      headless.stop_all()
    end
    -- let the fakes (which exit at once) finish, so no child is left behind
    if fakes then
      vim.wait(5000, function()
        for _, name in ipairs({ "herdr", "claude" }) do
          for _, c in ipairs(fakes.calls(name)) do
            if not c.done then
              return false
            end
          end
        end
        return true
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

  local function prompts()
    return vim.tbl_filter(function(c)
      return c.argv[1] == "agent" and c.argv[2] == "prompt"
    end, fakes.calls("herdr"))
  end

  local function wait_for(what, cond)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; notes: " .. vim.inspect(notes))
  end

  local function wait_claude(n)
    wait_for(n .. " claude run(s)", function()
      local calls = fakes.calls("claude")
      return #calls >= n and calls[n].done
    end)
    vim.wait(100) -- let on_exit run
  end

  local function wait_prompt(n)
    wait_for(n .. " herdr prompt(s)", function()
      return #prompts() >= n
    end)
  end

  ---A Claude transcript of `session`, started in `dir`, under $CLAUDE_CONFIG_DIR.
  local function transcript(session, dir)
    local project = vim.env.CLAUDE_CONFIG_DIR .. "/projects/" .. dir:gsub("[^%w]", "-")
    write(project .. "/" .. session .. ".jsonl",
      vim.json.encode({ type = "user", cwd = dir, sessionId = session }) .. "\n")
  end

  describe("pick", function()
    it("stores the choice per root; a second root keeps its own", function()
      require("agent-poke").setup({ isolate = false })
      local a_dir, b_dir = new_dir(), new_dir()
      fakes.agents({
        pane("w1:p1", "Review PR", a_dir),
        pane("w1:p9", "Other task", b_dir),
        pane(OWN, "This nvim", a_dir),
      })
      local root_a, root_b = new_dir(), new_dir()

      choose = "Review PR"
      herdr.pick(root_a)
      wait_for("root A's target", function()
        return state.get(root_a).target ~= nil
      end)
      choose = "Other task"
      herdr.pick(root_b)
      wait_for("root B's target", function()
        return state.get(root_b).target ~= nil
      end)
      assert.are.equal(2, selects)
      assert.are.equal("w1:p1", state.get(root_a).target.pane_id)
      assert.are.equal("w1:p9", state.get(root_b).target.pane_id)

      -- and each root's poke goes to its own pane, without asking again
      choose = nil
      herdr.poke(root_a, "prompt for A")
      wait_prompt(1)
      herdr.poke(root_b, "prompt for B")
      wait_prompt(2)
      local p = prompts()
      assert.are.same({ "agent", "prompt", "w1:p1", "prompt for A" }, p[1].argv)
      assert.are.same({ "agent", "prompt", "w1:p9", "prompt for B" }, p[2].argv)
      assert.are.equal(2, selects)
    end)

    it("leaves this pane out and offers the background agent", function()
      local labels
      vim.ui.select = function(items, opts, cb)
        selects = selects + 1
        labels = {}
        for _, item in ipairs(items) do
          labels[#labels + 1] = tostring(opts and opts.format_item and opts.format_item(item)
            or (type(item) == "table" and (item.title or item.pane_id)) or item)
        end
        cb(nil)
      end
      local d = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", d), pane(OWN, "This nvim", d) })
      herdr.pick(new_dir())
      wait_for("the picker", function()
        return labels ~= nil
      end)
      local all = table.concat(labels, "\n")
      assert.is_truthy(all:find("Review PR", 1, true), all)
      assert.is_falsy(all:find("This nvim", 1, true), all)
      assert.is_truthy(all:find("(background)", 1, true), all)
    end)
  end)

  describe("fork", function()
    it("isolate='fork' with a Claude transcript runs a throwaway fork in the session's directory", function()
      require("agent-poke").setup({ isolate = "fork" })
      local sess_dir, pane_dir, root = new_dir(), new_dir(), new_dir()
      transcript("sess-123", sess_dir)
      fakes.agents({ pane("w1:p1", "Review PR", pane_dir, "sess-123") })
      choose = "Review PR"
      herdr.pick(root)
      wait_for("the target", function()
        return state.get(root).target ~= nil
      end)

      herdr.poke(root, "please check the comments")
      wait_claude(1)
      local runs = fakes.calls("claude")
      assert.are.equal(1, #runs)
      local argv = runs[1].argv
      assert.is_truthy(has(argv, "-p"), vim.inspect(argv))
      assert.is_truthy(tostring(arg_after(argv, "-p")):find("please check the comments", 1, true), vim.inspect(argv))
      assert.are.equal("sess-123", arg_after(argv, "--resume"))
      assert.is_truthy(has(argv, "--fork-session"), vim.inspect(argv))
      assert.is_falsy(has(argv, "--session-id"), vim.inspect(argv))
      assert.are.equal(sess_dir, runs[1].cwd) -- the transcript's directory, not the pane's
      assert.are.equal(0, #prompts()) -- nothing typed into the pane
    end)
  end)

  describe("typing into the pane", function()
    it("without a transcript (isolate='fork') types the prompt with the subagent wording", function()
      require("agent-poke").setup({ isolate = "fork" })
      local root = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", new_dir(), "no-transcript") })
      choose = "Review PR"
      herdr.pick(root)
      wait_for("the target", function()
        return state.get(root).target ~= nil
      end)

      herdr.poke(root, "please check the comments")
      wait_prompt(1)
      local argv = prompts()[1].argv
      assert.are.same({ "agent", "prompt", "w1:p1" }, { argv[1], argv[2], argv[3] })
      assert.is_truthy(argv[4]:find("please check the comments", 1, true), argv[4])
      assert.is_truthy(argv[4]:lower():find("subagent", 1, true), argv[4])
      vim.wait(200)
      assert.are.equal(0, #fakes.calls("claude"))
    end)

    it("isolate='subagent' types the prompt with the subagent wording even with a transcript", function()
      require("agent-poke").setup({ isolate = "subagent" })
      local sess_dir, root = new_dir(), new_dir()
      transcript("sess-456", sess_dir)
      fakes.agents({ pane("w1:p1", "Review PR", sess_dir, "sess-456") })
      choose = "Review PR"
      herdr.pick(root)
      wait_for("the target", function()
        return state.get(root).target ~= nil
      end)

      herdr.poke(root, "please check the comments")
      wait_prompt(1)
      local text = prompts()[1].argv[4]
      assert.is_truthy(text:find("please check the comments", 1, true), text)
      assert.is_truthy(text:lower():find("subagent", 1, true), text)
      vim.wait(200)
      assert.are.equal(0, #fakes.calls("claude"))
    end)

    it("isolate=false types the plain prompt, even with a transcript", function()
      require("agent-poke").setup({ isolate = false })
      local sess_dir, root = new_dir(), new_dir()
      transcript("sess-789", sess_dir)
      fakes.agents({ pane("w1:p1", "Review PR", sess_dir, "sess-789") })
      choose = "Review PR"
      herdr.pick(root)
      wait_for("the target", function()
        return state.get(root).target ~= nil
      end)

      herdr.poke(root, "please check the comments")
      wait_prompt(1)
      assert.are.same({ "agent", "prompt", "w1:p1", "please check the comments" }, prompts()[1].argv)
      vim.wait(200)
      assert.are.equal(0, #fakes.calls("claude"))
    end)
  end)

  describe("falls back to the background agent", function()
    local function assert_background(root, prompt)
      wait_claude(1)
      local runs = fakes.calls("claude")
      assert.are.equal(1, #runs)
      local argv = runs[1].argv
      assert.is_truthy(tostring(arg_after(argv, "-p")):find(prompt, 1, true), vim.inspect(argv))
      assert.is_falsy(has(argv, "--fork-session"), vim.inspect(argv))
      assert.are.equal(root, runs[1].cwd)
      assert.are.equal(0, #prompts())
    end

    it("when herdr is not running (no HERDR_SOCKET_PATH)", function()
      vim.env.HERDR_SOCKET_PATH = nil
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      local root = new_dir()
      herdr.poke(root, "background please")
      assert_background(root, "background please")
      assert.are.equal(0, selects)
    end)

    it("when herdr is not installed", function()
      fakes.remove_herdr()
      local root = new_dir()
      herdr.poke(root, "background please")
      assert_background(root, "background please")
      assert.are.equal(0, selects)
    end)

    it("when the remembered pane is gone", function()
      local d = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", d), pane(OWN, "This nvim", d) })
      local root = new_dir()
      choose = "Review PR"
      herdr.pick(root)
      wait_for("the target", function()
        return state.get(root).target ~= nil
      end)
      fakes.agents({ pane(OWN, "This nvim", d) }) -- w1:p1 closed; only this pane is left
      choose = nil
      local before = selects
      herdr.poke(root, "background please")
      assert_background(root, "background please")
      assert.are.equal(before, selects)
    end)
  end)
end)
