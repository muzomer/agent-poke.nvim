-- agent-poke_nvim-wtd.3: each background backend's command line matches
-- code-review.nvim's table (lua/code-review/agents.lua at 7e2d74ca), for the
-- first run (new session) and for a resumed one.
--
-- Interface: require("agent-poke").setup({ headless = { agent, allowed_tools,
-- extra_tools, permission_mode } }), then require("agent-poke.headless").poke(root, prompt).
-- Fake codex / opencode / gemini / claude (test doubles) record their argv and
-- print the event that carries the session id.
local uv = vim.uv or vim.loop

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.fn.fnamemodify(d, ":p"):gsub("/$", ""))
end

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
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local SCRIPT = [[#!/bin/sh
log="%s/%s"
n=$(cat "$log.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log.n"
: > "$log.$n.tmp"
for a in "$@"; do printf '%%s\0' "$a" >> "$log.$n.tmp"; done
mv "$log.$n.tmp" "$log.$n.argv"
%s
echo done > "$log.$n.end"
]]

local OUT = {
  claude = [[
sid=fake-session; prev=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  prev=$a
done
printf '%%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
printf '%%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
]],
  codex = [[
printf '%%s\n' '{"type":"thread.started","thread_id":"codex-thread-1"}'
printf '%%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
printf '%%s\n' '{"type":"turn.completed","usage":{}}'
]],
  opencode = [[
printf '%%s\n' '{"type":"text","sessionID":"ses_oc1","part":{"type":"text","text":"ok","sessionID":"ses_oc1"}}'
]],
  gemini = [[
printf '%%s\n' '{"type":"init","session_id":"gem-1","model":"x"}'
printf '%%s\n' '{"type":"message","role":"assistant","content":"ok"}'
printf '%%s\n' '{"type":"result","status":"success"}'
]],
}

local function install()
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  for name, out in pairs(OUT) do
    write(bin .. "/" .. name, string.format(SCRIPT, log, name, string.format(out)))
    uv.fs_chmod(bin .. "/" .. name, tonumber("755", 8))
  end
  local old = vim.env.PATH
  vim.env.PATH = bin .. ":" .. old
  return {
    ---argv of call i of name (without the executable), once it has finished
    call = function(name, i)
      if not read(log .. "/" .. name .. "." .. i .. ".end") then
        return nil
      end
      local argv = {}
      for a in (read(log .. "/" .. name .. "." .. i .. ".argv") or ""):gmatch("([^%z]*)%z") do
        argv[#argv + 1] = a
      end
      return argv
    end,
    restore = function()
      vim.env.PATH = old
    end,
  }
end

---argv without the `--session-id <id>` pair (claude may preset its session id).
local function without_session_id(argv)
  local out, i = {}, 1
  while i <= #argv do
    if argv[i] == "--session-id" then
      i = i + 2
    else
      out[#out + 1] = argv[i]
      i = i + 1
    end
  end
  return out
end

describe("agent-poke.headless backends", function()
  local fake, headless, state, ap, old_state_home, old_notify

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_notify = vim.notify
    vim.notify = function() end
    fake = install()
    ap = require("agent-poke")
    state = require("agent-poke.state")
    headless = require("agent-poke.headless")
  end)

  after_each(function()
    fake.restore()
    ap.setup({})
    vim.notify = old_notify
    vim.env.XDG_STATE_HOME = old_state_home
  end)

  ---Poke twice (new session, then resume); the argv of both runs.
  local function two_runs(name, headless_opts)
    ap.setup({ headless = vim.tbl_extend("force", { agent = name }, headless_opts or {}) })
    local root = new_root()
    headless.poke(root, "first prompt")
    local first
    assert.is_true(vim.wait(10000, function()
      first = fake.call(name, 1)
      return first ~= nil and (state.get(root).session or {}).id ~= nil
    end, 20), name .. ": first run did not finish with a stored session")
    vim.wait(100)
    headless.poke(root, "second prompt")
    local second
    assert.is_true(vim.wait(10000, function()
      second = fake.call(name, 2)
      return second ~= nil
    end, 20), name .. ": second run did not run")
    return first, second, root
  end

  it("claude: -p stream-json, --resume <id>, allowed/extra tools and --permission-mode", function()
    local first, second = two_runs("claude", {
      allowed_tools = { "Read" },
      extra_tools = { "Bash(make test:*)" },
      permission_mode = "acceptEdits",
    })
    assert.are.same({
      "-p", "first prompt", "--output-format", "stream-json", "--verbose",
      "--allowedTools", "Read", "Bash(make test:*)",
      "--permission-mode", "acceptEdits",
    }, without_session_id(first))
    assert.is_false(vim.tbl_contains(first, "--resume"))
    assert.are.same({
      "-p", "second prompt", "--output-format", "stream-json", "--verbose",
      "--resume", second[7],
      "--allowedTools", "Read", "Bash(make test:*)",
      "--permission-mode", "acceptEdits",
    }, second)
    assert.is_truthy(second[7] == "fake-session" or second[7] == first[vim.fn.index(first, "--session-id") + 2], vim.inspect(second))
  end)

  it("claude: no --permission-mode unless set", function()
    local first, second = two_runs("claude", { allowed_tools = { "Read" } })
    assert.is_false(vim.tbl_contains(first, "--permission-mode"), vim.inspect(first))
    assert.is_false(vim.tbl_contains(second, "--permission-mode"), vim.inspect(second))
  end)

  it("codex: exec --json --sandbox workspace-write; resume <thread id>", function()
    local first, second = two_runs("codex")
    assert.are.same({ "exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write", "first prompt" }, first)
    assert.are.same(
      { "exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write", "resume", "codex-thread-1", "second prompt" },
      second
    )
  end)

  it("codex: permission_mode sets --sandbox", function()
    local first, second = two_runs("codex", { permission_mode = "read-only" })
    assert.are.same({ "exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "first prompt" }, first)
    assert.are.same(
      { "exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "resume", "codex-thread-1", "second prompt" },
      second
    )
  end)

  it("opencode: run --format json --dir <root>; --session <id> to resume", function()
    local first, second, root = two_runs("opencode")
    assert.are.same({ "run", "--format", "json", "--dir", root, "first prompt" }, first)
    assert.are.same({ "run", "--format", "json", "--session", "ses_oc1", "--dir", root, "second prompt" }, second)
  end)

  it("opencode: permission_mode = 'auto' adds --auto", function()
    local first, second, root = two_runs("opencode", { permission_mode = "auto" })
    assert.are.same({ "run", "--format", "json", "--auto", "--dir", root, "first prompt" }, first)
    assert.are.same({ "run", "--format", "json", "--session", "ses_oc1", "--auto", "--dir", root, "second prompt" }, second)
  end)

  it("gemini: -p -o stream-json; -r latest to resume", function()
    local first, second = two_runs("gemini")
    assert.are.same({ "-p", "first prompt", "-o", "stream-json" }, first)
    assert.are.same({ "-p", "second prompt", "-o", "stream-json", "-r", "latest" }, second)
  end)

  it("gemini: permission_mode sets --approval-mode", function()
    local first, second = two_runs("gemini", { permission_mode = "yolo" })
    assert.are.same({ "-p", "first prompt", "-o", "stream-json", "--approval-mode", "yolo" }, first)
    assert.are.same({ "-p", "second prompt", "-o", "stream-json", "-r", "latest", "--approval-mode", "yolo" }, second)
  end)
end)
