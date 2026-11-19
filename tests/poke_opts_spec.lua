-- agent-poke_nvim-3am: poke(root, prompt, opts) options and the status API that
-- code-review.nvim (7e2d74ca: headless.send(), progress.lua:301/464) needs.
--
-- Interface (lua/agent-poke/init.lua):
--   poke(root, prompt, opts?) -> "started" | "queued" | "typed" | "forked" | false
--     opts = {
--       cwd?      -- the background agent runs (and later resumes) there instead of root
--       dirs?     -- extra directories: each backend's add-dir flag
--                 --   (claude: --add-dir d, gemini: --include-directories d)
--       env?      -- merged into the agent process's environment
--       on_start? -- fun(): called when a background run starts (now, or later for a queued poke)
--       pick?     -- true: choose the agent again (the picker opens even with a remembered one)
--     }
--     The status is returned synchronously by poke() on every route.
--   status(root) -> nil before any run, else { status = "working"|"done"|"failed", error? }
--   lines(root)  -> readable output lines of the current/last background run
--
-- Fakes (test doubles, defined here): `herdr` answers `agent list` from a
-- per-test agents.json; `agent prompt` answers ok, or an error when
-- <log>/prompt_error exists. `claude` and `gemini` record argv, `pwd -P`,
-- $AP_TEST_VAR, $XDG_STATE_HOME and $PATH; claude waits (at most ~5 s) for
-- <log>/release when <log>/gate exists, and fails (exit 3) when <log>/fail
-- exists. PATH holds only the fakes and /usr/bin:/bin.
local uv = vim.uv or vim.loop
local helpers = require("tests.helpers")

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

local HERDR_BODY = [[
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  cat "$log/agents.json"
elif [ -f "$log/prompt_error" ]; then
  printf '%s\n' '{"error":{"code":"pane_not_found","message":"no such pane"}}'
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
if [ -f "$log/fail" ]; then
  echo "fake claude exploded" >&2
  touch "$d/done"
  exit 3
fi
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line one from fake"}]}}'
if [ -f "$log/gate" ]; then
  i=0
  while [ ! -f "$log/release" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
fi
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
touch "$d/done"
]]

local GEMINI_BODY = [[
printf '%s\n' '{"type":"init","session_id":"gem-1","model":"x"}'
printf '%s\n' '{"type":"message","role":"assistant","content":"ok"}'
printf '%s\n' '{"type":"result","status":"success"}'
touch "$d/done"
]]

local NAMES = { "herdr", "claude", "gemini" }

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

---Values following each occurrence of `flag`, in order.
local function all_after(argv, flag)
  local out = {}
  for i, a in ipairs(argv) do
    if a == flag then
      out[#out + 1] = argv[i + 1]
    end
  end
  return out
end

describe("agent-poke poke() options and status API", function()
  local ap, state, headless, fakes, notes, selects, choose
  local saved_env, old_notify, old_select

  before_each(function()
    saved_env = {
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      PATH = vim.env.PATH,
      HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH,
      HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
      AP_TEST_VAR = vim.env.AP_TEST_VAR,
    }
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    fakes = helpers.install_fakes({ bodies = { herdr = HERDR_BODY, claude = CLAUDE_BODY, gemini = GEMINI_BODY }, env = true })
    vim.env.PATH = fakes.bin .. ":/usr/bin:/bin"
    vim.env.HERDR_SOCKET_PATH = nil -- no herdr unless a test sets it
    vim.env.HERDR_PANE_ID = OWN
    vim.env.CLAUDE_CONFIG_DIR = new_dir()
    vim.env.AP_TEST_VAR = nil

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

    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
  end)

  after_each(function()
    if fakes then
      fakes.flag("release")
    end
    if headless then
      headless.stop_all()
    end
    if fakes then
      vim.wait(6000, function()
        for _, name in ipairs(NAMES) do
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

  local function wait_for(what, cond)
    assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what .. "; notes: " .. vim.inspect(notes))
  end

  local function wait_run(name, n)
    wait_for(n .. " " .. name .. " run(s)", function()
      local calls = fakes.calls(name)
      return #calls >= n and calls[n].done
    end)
    vim.wait(100) -- let on_exit run
  end

  local function wait_started(name, n)
    wait_for(n .. " " .. name .. " run(s) started", function()
      return #fakes.calls(name) >= n
    end)
  end

  local function prompts()
    return vim.tbl_filter(function(c)
      return c.argv[1] == "agent" and c.argv[2] == "prompt"
    end, fakes.calls("herdr"))
  end

  local function with_herdr()
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname() .. ".sock"
  end

  ---A Claude transcript of `session`, started in `dir`, under $CLAUDE_CONFIG_DIR.
  local function transcript(session, dir)
    local project = vim.env.CLAUDE_CONFIG_DIR .. "/projects/" .. dir:gsub("[^%w]", "-")
    write(project .. "/" .. session .. ".jsonl",
      vim.json.encode({ type = "user", cwd = dir, sessionId = session }) .. "\n")
  end

  describe("return value", function()
    it("is 'started' when the background agent starts a run", function()
      local root = new_dir()
      local res = ap.poke(root, "hello")
      assert.are.equal("started", res)
      wait_run("claude", 1)
    end)

    it("is 'queued' when a background run is still in flight", function()
      fakes.flag("gate")
      local root = new_dir()
      assert.are.equal("started", ap.poke(root, "first"))
      wait_started("claude", 1)
      assert.are.equal("queued", ap.poke(root, "second"))
      fakes.flag("release")
      wait_run("claude", 2)
    end)

    it("is false when the background agent cannot start", function()
      ap.setup({ agent = "headless", headless = { cmd = "/nonexistent/agent-poke-claude" } })
      local res = ap.poke(new_dir(), "hello")
      assert.are.equal(false, res)
      assert.are.equal(0, #fakes.calls("claude"))
    end)

    it("is 'typed' when the prompt is typed into the remembered herdr pane", function()
      with_herdr()
      ap.setup({ targets = { "herdr" }, isolate = false })
      local root = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      state.set(root, "target", { target = "herdr", id = "w1:p1" })
      local res = ap.poke(root, "typed prompt")
      assert.are.equal("typed", res)
      wait_for("a herdr prompt", function()
        return #prompts() >= 1
      end)
      assert.are.same({ "agent", "prompt", "w1:p1", "typed prompt" }, prompts()[1].argv)
    end)

    it("is false when herdr rejects the typed prompt", function()
      with_herdr()
      ap.setup({ targets = { "herdr" }, isolate = false })
      fakes.flag("prompt_error")
      local root = new_dir()
      fakes.agents({ pane("w1:p1", "Review PR", new_dir()) })
      state.set(root, "target", { target = "herdr", id = "w1:p1" })
      local res = ap.poke(root, "typed prompt")
      assert.are.equal(false, res)
    end)

    it("is 'forked' when a throwaway fork of the herdr agent's session runs", function()
      with_herdr()
      ap.setup({ targets = { "herdr" }, isolate = "fork" })
      local sess_dir, root = new_dir(), new_dir()
      transcript("sess-123", sess_dir)
      fakes.agents({ pane("w1:p1", "Review PR", new_dir(), "sess-123") })
      state.set(root, "target", { target = "herdr", id = "w1:p1" })
      local res = ap.poke(root, "fork prompt")
      assert.are.equal("forked", res)
      wait_run("claude", 1)
      local run = fakes.calls("claude")[1]
      assert.are.equal("sess-123", arg_after(run.argv, "--resume"))
      assert.are.equal(sess_dir, run.cwd)
    end)
  end)

  describe("on_start", function()
    it("is called once when a background run starts", function()
      local calls = 0
      ap.poke(new_dir(), "hello", { on_start = function() calls = calls + 1 end })
      wait_for("on_start", function()
        return calls >= 1
      end)
      wait_run("claude", 1)
      assert.are.equal(1, calls)
    end)

    it("waits with a queued poke until its run starts", function()
      fakes.flag("gate")
      local root = new_dir()
      local first, second = 0, 0
      ap.poke(root, "first", { on_start = function() first = first + 1 end })
      wait_started("claude", 1)
      ap.poke(root, "second", { on_start = function() second = second + 1 end })
      vim.wait(100)
      assert.are.equal(1, first)
      assert.are.equal(0, second) -- still queued
      fakes.flag("release")
      wait_for("the queued poke's on_start", function()
        return second >= 1
      end)
      wait_run("claude", 2)
      assert.are.equal(1, first)
      assert.are.equal(1, second)
    end)
  end)

  describe("pick", function()
    it("opens the picker even with a remembered agent and delivers to the new choice", function()
      with_herdr()
      ap.setup({ targets = { "herdr" }, isolate = false })
      local root = new_dir()
      fakes.agents({ pane("w1:p1", "Pane A", new_dir()), pane("w1:p2", "Pane B", new_dir()) })
      state.set(root, "target", { target = "herdr", id = "w1:p1" })
      choose = "Pane B"
      ap.poke(root, "picked prompt", { pick = true })
      wait_for("a herdr prompt", function()
        return #prompts() >= 1
      end)
      vim.wait(100)
      assert.are.equal(1, selects)
      assert.are.equal(1, #prompts())
      assert.are.same({ "agent", "prompt", "w1:p2", "picked prompt" }, prompts()[1].argv)
      assert.are.equal("w1:p2", state.get(root).target.id)
    end)
  end)

  describe("cwd", function()
    it("runs the background agent in cwd and resumes its session there", function()
      local root, work = new_dir(), new_dir()
      assert.are.equal("started", ap.poke(root, "first", { cwd = work }))
      wait_run("claude", 1)
      local first = fakes.calls("claude")[1]
      assert.are.equal(work, first.cwd)
      local id = arg_after(first.argv, "--session-id")
      assert.is_truthy(id, vim.inspect(first.argv))

      assert.are.equal("started", ap.poke(root, "second", { cwd = work }))
      wait_run("claude", 2)
      local second = fakes.calls("claude")[2]
      assert.are.equal(work, second.cwd)
      assert.are.equal(id, arg_after(second.argv, "--resume"))
    end)
  end)

  describe("dirs", function()
    it("become --add-dir flags for claude, in order", function()
      local root, d1, d2 = new_dir(), new_dir(), new_dir()
      ap.poke(root, "hello", { dirs = { d1, d2 } })
      wait_run("claude", 1)
      assert.are.same({ d1, d2 }, all_after(fakes.calls("claude")[1].argv, "--add-dir"))
    end)

    it("become --include-directories flags for gemini, in order", function()
      ap.setup({ agent = "headless", headless = { agent = "gemini" } })
      local root, d1, d2 = new_dir(), new_dir(), new_dir()
      ap.poke(root, "hello", { dirs = { d1, d2 } })
      wait_run("gemini", 1)
      assert.are.same({ d1, d2 }, all_after(fakes.calls("gemini")[1].argv, "--include-directories"))
    end)
  end)

  describe("env", function()
    it("is merged into the process environment", function()
      local root = new_dir()
      ap.poke(root, "hello", { env = { AP_TEST_VAR = "from-opts" } })
      wait_run("claude", 1)
      local run = fakes.calls("claude")[1]
      assert.are.equal("from-opts", run.ap_test_var)
      assert.are.equal(vim.env.XDG_STATE_HOME, run.xdg_state_home) -- inherited, not replaced
    end)

    it("can set PATH for the agent", function()
      local root = new_dir()
      local path = fakes.bin .. ":/usr/bin:/bin:/ap-extra-dir"
      ap.poke(root, "hello", { env = { PATH = path } })
      wait_run("claude", 1)
      assert.are.equal(path, fakes.calls("claude")[1].path)
    end)
  end)

  describe("status and lines", function()
    it("status is nil and lines empty before any run", function()
      local root = new_dir()
      assert.is_nil(ap.status(root))
      assert.are.same({}, ap.lines(root))
    end)

    it("status is 'working' during a run and 'done' after; lines hold its output", function()
      fakes.flag("gate")
      local root = new_dir()
      ap.poke(root, "hello")
      wait_started("claude", 1)
      local st = ap.status(root)
      assert.is_table(st)
      assert.are.equal("working", st.status)
      fakes.flag("release")
      wait_run("claude", 1)
      wait_for("status done", function()
        local s = ap.status(root)
        return s and s.status == "done"
      end)
      local text = table.concat(ap.lines(root), "\n")
      assert.is_truthy(text:find("line one from fake", 1, true), text)
    end)

    it("status is 'failed' with an error when the run fails", function()
      fakes.flag("fail")
      local root = new_dir()
      ap.poke(root, "hello")
      wait_run("claude", 1)
      wait_for("status failed", function()
        local s = ap.status(root)
        return s and s.status == "failed"
      end)
      local st = ap.status(root)
      assert.is_string(st.error)
      assert.is_truthy(#st.error > 0)
    end)
  end)

  describe("no opts", function()
    it("poke(root, prompt) still runs the background agent in root without extra flags", function()
      local root = new_dir()
      ap.poke(root, "plain poke")
      wait_run("claude", 1)
      local run = fakes.calls("claude")[1]
      assert.are.equal(root, run.cwd)
      assert.are.equal("plain poke", arg_after(run.argv, "-p"))
      assert.are.same({}, all_after(run.argv, "--add-dir"))
      assert.are.equal("<unset>", run.ap_test_var)
    end)
  end)

  describe("README", function()
    local readme = read(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/README.md") or ""

    it("documents the poke options", function()
      for _, token in ipairs({ "`cwd`", "`dirs`", "`env`", "`on_start`", "`pick`", "poke(root, prompt, opts)" }) do
        assert.is_truthy(readme:find(token, 1, true), "README lacks " .. token)
      end
    end)

    it("documents the returned status values", function()
      for _, word in ipairs({ "started", "queued", "typed", "forked" }) do
        assert.is_truthy(readme:find("[\"'`]" .. word .. "[\"'`]"), "README lacks the status " .. word)
      end
    end)

    it("documents status(root) and lines(root)", function()
      for _, token in ipairs({ "status(root)", "lines(root)" }) do
        assert.is_truthy(readme:find(token, 1, true), "README lacks " .. token)
      end
    end)
  end)
end)
