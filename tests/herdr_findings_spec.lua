-- agent-poke_nvim-wtd.4, review findings (blockers):
--   1. headless.lua: a fork of a pane whose agent differs from
--      config.headless.agent must be built, run and parsed with the pane agent's
--      adapter (claude: `-p <prompt> --resume <id> --fork-session`), not the
--      configured one (codex: `exec --json ...`) and without its config.headless.args.
--   2. herdr.lua: in agent = "auto", a failed `herdr agent list` on the first poke
--      must not auto-choose and remember the background agent for that root.
--
-- Fakes (test doubles): `herdr` answers `agent list` from agents.json, or fails
-- (exit 1) while <log>/list_fail exists; `claude` records argv and cwd, prints
-- stream-json and exits at once. PATH holds only the fakes and /usr/bin:/bin.
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
  if [ -e "$log/list_fail" ]; then
    echo "herdr: connection refused" >&2
    touch "$d/done"
    exit 1
  fi
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
  function self.list_fails(on)
    if on then
      write(log .. "/list_fail", "")
    else
      os.remove(log .. "/list_fail")
    end
  end
  return self
end

local OWN = "w1:p5"

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

describe("agent-poke.herdr review findings", function()
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
    choose = nil
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

    require("agent-poke").setup()
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
    herdr = require("agent-poke.herdr")
  end)

  after_each(function()
    if headless then
      headless.stop_all()
    end
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
    require("agent-poke").setup()
  end)

  local function prompts()
    return vim.tbl_filter(function(c)
      return c.argv[1] == "agent" and c.argv[2] == "prompt"
    end, fakes.calls("herdr"))
  end

  local function wait_for(what, cond)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; notes: " .. vim.inspect(notes))
  end

  local function transcript(session, dir)
    local project = vim.env.CLAUDE_CONFIG_DIR .. "/projects/" .. dir:gsub("[^%w]", "-")
    write(project .. "/" .. session .. ".jsonl",
      vim.json.encode({ type = "user", cwd = dir, sessionId = session }) .. "\n")
  end

  it("forks a Claude pane with Claude's command line when the background agent is codex", function()
    require("agent-poke").setup({
      isolate = "fork",
      headless = { agent = "codex", args = { "--codex-only-arg" } },
    })
    local sess_dir, pane_dir, root = new_dir(), new_dir(), new_dir()
    transcript("sess-123", sess_dir)
    fakes.agents({ pane("w1:p1", "Review PR", pane_dir, "sess-123") })
    choose = "Review PR"
    herdr.pick(root)
    wait_for("the target", function()
      return state.get(root).target ~= nil
    end)

    herdr.poke(root, "please check the comments")
    wait_for("the claude fork", function()
      local calls = fakes.calls("claude")
      return #calls >= 1 and calls[1].done
    end)
    vim.wait(200) -- let on_exit run
    local runs = fakes.calls("claude")
    assert.are.equal(1, #runs)
    local argv = runs[1].argv
    assert.are.equal("-p", argv[1], vim.inspect(argv))
    assert.is_truthy(tostring(argv[2]):find("please check the comments", 1, true), vim.inspect(argv))
    assert.are.equal("sess-123", arg_after(argv, "--resume"), vim.inspect(argv))
    assert.is_truthy(vim.tbl_contains(argv, "--fork-session"), vim.inspect(argv))
    assert.is_falsy(vim.tbl_contains(argv, "exec"), vim.inspect(argv))
    assert.is_falsy(vim.tbl_contains(argv, "--json"), vim.inspect(argv))
    assert.is_falsy(vim.tbl_contains(argv, "--codex-only-arg"), vim.inspect(argv)) -- codex's extra args stay with codex
    assert.are.equal(sess_dir, runs[1].cwd)
    for _, n in ipairs(notes) do
      assert.is_falsy(n.level == vim.log.levels.ERROR, vim.inspect(notes))
    end
  end)

  it("agent='auto': a failed `herdr agent list` on the first poke does not remember the background agent", function()
    require("agent-poke").setup({ isolate = false })
    local root = new_dir()
    fakes.agents({ pane("w1:p1", "Review PR", new_dir()), pane(OWN, "This nvim", new_dir()) })
    fakes.list_fails(true)

    choose = nil -- a picker, if one opens, is dismissed
    herdr.poke(root, "first prompt")
    wait_for("herdr agent list", function()
      local calls = fakes.calls("herdr")
      return #calls >= 1 and calls[1].done
    end)
    vim.wait(500) -- let the poke settle (picker, background run, notifications)

    local saved = state.get(root).target
    assert.is_falsy(type(saved) == "table" and saved.pane_id == herdr.HEADLESS,
      "background agent was remembered after a failed agent list: " .. vim.inspect(saved))

    -- herdr answers again: the next poke offers the herdr panes and reaches the chosen one
    fakes.list_fails(false)
    choose = "Review PR"
    herdr.poke(root, "second prompt")
    wait_for("the prompt typed into w1:p1", function()
      return #prompts() >= 1
    end)
    assert.are.same({ "agent", "prompt", "w1:p1", "second prompt" }, prompts()[1].argv)
  end)
end)
