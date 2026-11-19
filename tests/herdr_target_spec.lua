-- agent-poke_nvim-0d8.2: herdr is a target like any other (list/deliver), not a
-- takeover of poke()/pick(). Everything here goes through the core API
-- (require("agent-poke").setup / pick / poke), never herdr.poke / herdr.pick.
--
-- Interface:
--   setup({ targets = { "herdr", <spec>... } })      -- herdr enabled with other targets
--   setup({ targets = { herdr = { isolate = ... } } }) -- herdr enabled with its own options
--   herdr entries: id = the pane id; the choice is stored as
--     state key target = { target = "herdr", id = <pane_id> }
--   poke() with a stored herdr entry: typed into the pane ("typed") or a
--     throwaway fork of its session ("forked"); on failure false, one ERROR
--     notice in total, and the prompt in the " register.
--   setup() replaces the target list (a second call does not add to it).
--
-- Fakes (test doubles, defined here): `herdr` answers `agent list` from a
-- per-test agents.json, answers `agent prompt` with ok (or an error when
-- <log>/prompt_fail exists) and records argv; `claude` records argv and cwd and
-- prints stream-json. PATH holds only the fakes and /usr/bin:/bin.
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
  cat "$log/agents.json"
  touch "$d/done"
elif [ -e "$log/prompt_fail" ]; then
  printf '%s\n' '{"error":{"code":"pane_not_found","message":"no such pane"}}'
  touch "$d/done"
  exit 1
else
  printf '%s\n' '{"result":{"ok":true}}'
  touch "$d/done"
fi
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
  function self.fail_prompts()
    write(log .. "/prompt_fail", "")
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

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("herdr as a target", function()
  local ap, state, fakes, notes, selects, choose
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
    selects = {}
    choose = nil -- substring of the label to choose; nil dismisses the picker
    vim.ui.select = function(items, opts, cb)
      local labels, picked = {}, nil
      for _, item in ipairs(items) do
        local label = tostring(opts and opts.format_item and opts.format_item(item)
          or (type(item) == "table" and (item.title or item.label)) or item)
        labels[#labels + 1] = label
        if not picked and choose and label:find(choose, 1, true) then
          picked = item
        end
      end
      selects[#selects + 1] = labels
      cb(picked)
    end

    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
  end)

  after_each(function()
    local headless = package.loaded["agent-poke.headless"]
    if headless then
      pcall(headless.stop_all)
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
    unload()
  end)

  local function prompts()
    return vim.tbl_filter(function(c)
      return c.argv[1] == "agent" and c.argv[2] == "prompt"
    end, fakes.calls("herdr"))
  end

  local function errors()
    return vim.tbl_filter(function(n)
      return (n.level or vim.log.levels.INFO) >= vim.log.levels.ERROR
    end, notes)
  end

  local function wait_claude(n)
    assert(vim.wait(5000, function()
      local calls = fakes.calls("claude")
      return #calls >= n and calls[n].done
    end, 20), "timed out waiting for claude; notes: " .. vim.inspect(notes))
    vim.wait(100)
  end

  local function transcript(session, dir)
    local project = vim.env.CLAUDE_CONFIG_DIR .. "/projects/" .. dir:gsub("[^%w]", "-")
    write(project .. "/" .. session .. ".jsonl",
      vim.json.encode({ type = "user", cwd = dir, sessionId = session }) .. "\n")
  end

  ---A fake target recording its deliveries.
  local function fake(name)
    local t = { delivered = {} }
    t.spec = {
      name = name,
      list = function()
        return { { id = "a", title = "Alpha " .. name }, { id = "b", title = "Beta " .. name } }
      end,
      deliver = function(r, entry, prompt, o)
        t.delivered[#t.delivered + 1] = { root = r, entry = entry, prompt = prompt, opts = o }
        return "queued"
      end,
    }
    return t
  end

  local function contains(labels, text)
    for _, l in ipairs(labels) do
      if l:find(text, 1, true) then
        return true
      end
    end
    return false
  end

  describe("next to another target", function()
    it("pick() lists the background agent, herdr's panes and the other target's entries in one picker", function()
      local f = fake("fake")
      ap.setup({ targets = { "herdr", f.spec } })
      local d = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", d), pane(OWN, "This nvim", d) })
      ap.pick(new_dir())
      assert.is_true(vim.wait(1000, function()
        return #selects > 0
      end, 10), "pick() did not open a picker; notes: " .. vim.inspect(notes))
      assert.are.equal(1, #selects)
      local labels = selects[1]
      local all = table.concat(labels, "\n")
      assert.are.equal(4, #labels, all) -- background + 1 herdr pane + 2 fake entries
      assert.is_true(contains(labels, "(background)"), all)
      assert.is_true(contains(labels, "Review PR"), all)
      assert.is_false(contains(labels, "This nvim"), all)
      assert.is_true(contains(labels, "Alpha fake"), all)
      assert.is_true(contains(labels, "Beta fake"), all)
    end)

    it("poke() with the other target's entry stored delivers through it, not herdr", function()
      local f = fake("fake")
      ap.setup({ targets = { "herdr", f.spec } })
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      local r = new_dir()
      state.set(r, "target", { target = "fake", id = "a" })
      assert.are.equal("queued", ap.poke(r, "hello"))
      assert.are.equal(0, #selects)
      assert.are.equal(1, #f.delivered)
      assert.are.equal("a", f.delivered[1].entry.id)
      assert.are.equal("hello", f.delivered[1].prompt)
      assert.are.equal(0, #prompts(), "nothing typed into a herdr pane")
    end)

    it("poke({ pick = true }) delivers through the chosen herdr pane and remembers { target = 'herdr', id = pane }", function()
      local f = fake("fake")
      ap.setup({ targets = { "herdr", f.spec } })
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      local r = new_dir()
      choose = "Review PR"
      local status = ap.poke(r, "please check the comments", { pick = true })
      assert.are.equal("typed", status, vim.inspect(notes))
      assert.are.equal(1, #selects)
      assert.is_true(contains(selects[1], "Alpha fake"), "the other target's entries are offered too")
      local p = prompts()
      assert.are.equal(1, #p)
      assert.are.same({ "agent", "prompt", "w1:p1" }, { p[1].argv[1], p[1].argv[2], p[1].argv[3] })
      assert.is_truthy(p[1].argv[4]:find("please check the comments", 1, true), p[1].argv[4])
      assert.are.equal(0, #f.delivered)
      assert.are.same({ target = "herdr", id = "w1:p1" }, state.get(r).target)
    end)

    it("poke({ pick = true }) delivers through the chosen entry of the other target", function()
      local f = fake("fake")
      ap.setup({ targets = { "herdr", f.spec } })
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      local r = new_dir()
      choose = "Beta fake"
      assert.are.equal("queued", ap.poke(r, "hi", { pick = true }))
      assert.are.equal(1, #f.delivered)
      assert.are.equal("b", f.delivered[1].entry.id)
      assert.are.equal(0, #prompts())
      assert.are.same({ target = "fake", id = "b" }, state.get(r).target)
    end)
  end)

  describe("a stored herdr entry", function()
    it("poke() types into the pane and returns 'typed', without a picker", function()
      ap.setup({ targets = { "herdr" } })
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      local r = new_dir()
      state.set(r, "target", { target = "herdr", id = "w1:p1" })
      assert.are.equal("typed", ap.poke(r, "please check the comments"), vim.inspect(notes))
      assert.are.equal(0, #selects)
      local p = prompts()
      assert.are.equal(1, #p)
      assert.are.equal("w1:p1", p[1].argv[3])
      assert.is_truthy(p[1].argv[4]:find("please check the comments", 1, true), p[1].argv[4])
      vim.wait(100)
      assert.are.equal(0, #fakes.calls("claude"))
    end)

    it("poke() forks the pane's Claude session (isolate = 'fork', transcript found) and returns 'forked'", function()
      ap.setup({ targets = { "herdr" } })
      local sess_dir = new_dir()
      transcript("sess-123", sess_dir)
      fakes.agents({ pane("w1:p1", "Review PR", new_dir(), "sess-123") })
      local r = new_dir()
      state.set(r, "target", { target = "herdr", id = "w1:p1" })
      assert.are.equal("forked", ap.poke(r, "please check the comments"), vim.inspect(notes))
      wait_claude(1)
      local argv = fakes.calls("claude")[1].argv
      assert.are.equal("sess-123", arg_after(argv, "--resume"))
      assert.is_truthy(vim.tbl_contains(argv, "--fork-session"), vim.inspect(argv))
      assert.is_truthy(tostring(arg_after(argv, "-p")):find("please check the comments", 1, true), vim.inspect(argv))
      assert.are.equal(sess_dir, fakes.calls("claude")[1].cwd)
      assert.are.equal(0, #prompts())
    end)

    it("targets = { herdr = { isolate = false } }: the adapter's own option types the plain prompt", function()
      ap.setup({ isolate = "fork", targets = { herdr = { isolate = false } } })
      local sess_dir = new_dir()
      transcript("sess-789", sess_dir)
      fakes.agents({ pane("w1:p1", "Review PR", sess_dir, "sess-789") })
      local r = new_dir()
      state.set(r, "target", { target = "herdr", id = "w1:p1" })
      assert.are.equal("typed", ap.poke(r, "please check the comments"), vim.inspect(notes))
      local p = prompts()
      assert.are.equal(1, #p)
      assert.are.same({ "agent", "prompt", "w1:p1", "please check the comments" }, p[1].argv)
      vim.wait(200)
      assert.are.equal(0, #fakes.calls("claude"))
    end)

    it("a failed delivery returns false with exactly one error notice and the prompt in the \" register", function()
      ap.setup({ targets = { "herdr" } })
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      fakes.fail_prompts()
      local r = new_dir()
      state.set(r, "target", { target = "herdr", id = "w1:p1" })
      vim.fn.setreg('"', "something else")
      local status = ap.poke(r, "please check the comments")
      assert.is_false(status)
      assert.are.equal(1, #prompts())
      assert.are.equal(1, #errors(), "one notice per failed delivery; got: " .. vim.inspect(notes))
      assert.are.equal("please check the comments", vim.fn.getreg('"'))
    end)
  end)

  describe("setup() replaces the target list", function()
    it("setup({}) after setup({ targets = { 'herdr' } }) leaves herdr off", function()
      ap.setup({ targets = { "herdr" } })
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      ap.setup({})
      local r = new_dir()
      assert.are.equal("started", ap.poke(r, "hello"))
      wait_claude(1)
      ap.pick(r)
      vim.wait(100)
      for _, labels in ipairs(selects) do
        assert.are.equal(1, #labels, "only the background agent: " .. table.concat(labels, "\n"))
      end
      assert.are.equal(0, #fakes.calls("herdr"), "herdr must not run once it is off")
    end)
  end)

  describe("without herdr enabled", function()
    it("the adapter module is never loaded (passes already)", function()
      local f = fake("fake")
      ap.setup({ targets = { f.spec } })
      local r = new_dir()
      ap.pick(r)
      ap.poke(r, "hello")
      ap.setup({})
      ap.pick(r)
      ap.poke(new_dir(), "hello")
      wait_claude(1)
      assert.is_nil(package.loaded["agent-poke.targets.herdr"])
      assert.are.equal(0, #fakes.calls("herdr"))
    end)
  end)
end)
