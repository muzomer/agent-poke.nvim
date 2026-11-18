---The background agent: a coding agent started without a terminal (`claude -p`,
---`codex exec`, `opencode run`, `gemini -p`), one resumable conversation per
---project root. The first poke starts a session and stores its id with
---agent-poke.state; later pokes resume it. Runs start in <root> (agents file
---their sessions by directory). A poke while a run is in flight is queued
---(one slot: the latest wins) and runs when the run ends.
local state = require("agent-poke.state")

local uv = vim.uv or vim.loop

local M = {}

local runs = {} -- root -> { handle, status = "working"|"done"|"failed", queued?, text }

local function cfg()
  return require("agent-poke").config.headless or {}
end

local function notify(msg, level)
  vim.notify("agent-poke: " .. msg, level or vim.log.levels.INFO)
end

local function one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  return #s > max and (s:sub(1, max - 1) .. "…") or s
end

-- Adapters (as in code-review.nvim's agents.lua) ----------------------------------

local agents = {}

agents.claude = {
  name = "Claude Code",
  cmd = "claude",
  preset_id = true,
  DEFAULT_TOOLS = { "Read", "Grep", "Glob" },
  args = function(o)
    local c = o.cfg
    local args = { o.cmd, "-p", o.prompt, "--output-format", "stream-json", "--verbose" }
    if o.resume then
      vim.list_extend(args, { "--resume", o.resume })
    else
      vim.list_extend(args, { "--session-id", o.new_id })
    end
    local tools = vim.deepcopy(c.allowed_tools or agents.claude.DEFAULT_TOOLS)
    vim.list_extend(tools, c.extra_tools or {})
    if #tools > 0 then
      args[#args + 1] = "--allowedTools"
      vim.list_extend(args, tools)
    end
    if c.permission_mode then
      vim.list_extend(args, { "--permission-mode", c.permission_mode })
    end
    return args
  end,
  parse = function(ev)
    if ev.type == "result" then
      return { done = true, error = ev.is_error and tostring(ev.result or "failed") or nil }
    end
  end,
  -- the saved session is gone (deleted, or never written)
  lost_session = function(err)
    return err:lower():find("no conversation found", 1, true) ~= nil
  end,
}

agents.codex = {
  name = "Codex",
  cmd = "codex",
  args = function(o)
    local args = { o.cmd, "exec", "--json", "--skip-git-repo-check", "--sandbox", o.cfg.permission_mode or "workspace-write" }
    if o.resume then
      vim.list_extend(args, { "resume", o.resume })
    end
    args[#args + 1] = o.prompt
    return args
  end,
  parse = function(ev)
    if ev.type == "thread.started" then
      return { session_id = ev.thread_id }
    elseif ev.type == "turn.completed" then
      return { done = true }
    elseif ev.type == "turn.failed" or ev.type == "error" then
      local e = ev.error
      return { done = ev.type == "turn.failed", error = type(e) == "table" and e.message or ev.message or "failed" }
    end
  end,
}

agents.opencode = {
  name = "OpenCode",
  cmd = "opencode",
  args = function(o)
    local args = { o.cmd, "run", "--format", "json" }
    if o.resume then
      vim.list_extend(args, { "--session", o.resume })
    end
    if o.cfg.permission_mode == "auto" then
      args[#args + 1] = "--auto"
    end
    vim.list_extend(args, { "--dir", o.cwd, o.prompt })
    return args
  end,
  parse = function(ev)
    local part = type(ev.part) == "table" and ev.part or {}
    local res = { session_id = ev.sessionID or ev.session_id or part.sessionID }
    if ev.type == "error" then
      res.error = one_line(type(ev.error) == "table" and (ev.error.message or vim.inspect(ev.error)) or ev.error or "failed", 200)
    end
    return res
  end,
}

agents.gemini = {
  name = "Gemini CLI",
  cmd = "gemini",
  args = function(o)
    local args = { o.cmd, "-p", o.prompt, "-o", "stream-json" }
    if o.resume then
      vim.list_extend(args, { "-r", "latest" })
    end
    if o.cfg.permission_mode then
      vim.list_extend(args, { "--approval-mode", o.cfg.permission_mode })
    end
    return args
  end,
  parse = function(ev)
    if ev.type == "init" then
      return { session_id = ev.session_id or ev.sessionId or "latest" }
    elseif ev.type == "error" then
      return { error = one_line(ev.message or ev.error or "error", 200), done = false }
    elseif ev.type == "result" then
      local failed = ev.status == "error" or ev.status == "failure"
      return { done = true, error = failed and one_line(ev.error or ev.status, 200) or nil }
    end
  end,
}

local function agent_name()
  return cfg().agent or "claude"
end

---The adapter of the configured background agent.
function M.adapter()
  return agents[agent_name()] or agents.claude
end

---Its executable: config.headless.cmd, else the adapter's own.
function M.command()
  return cfg().cmd or M.adapter().cmd
end

-- Session id ------------------------------------------------------------------------

---The stored session id, if it was started with the configured agent.
---@return string?
function M.session_id(root)
  local s = state.get(root).session
  if type(s) == "table" and type(s.id) == "string" and (s.agent or "claude") == agent_name() then
    return s.id
  end
  return nil
end

local function save_session_id(root, id)
  state.set(root, "session", { id = id, agent = agent_name() })
end

local function forget(root)
  state.set(root, "session", nil)
end

---A random (version 4) UUID, the form `--session-id` accepts.
local function uuid()
  local b = { uv.random(16):byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i, v in ipairs(b) do
    hex[i] = string.format("%02x", v)
  end
  local h = table.concat(hex)
  return string.format("%s-%s-%s-%s-%s", h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

---Command line of a run. `resume` = id of the session to continue, `new_id` = id for a new one.
function M.args(root, text, opts)
  local args = M.adapter().args({
    cmd = M.command(), prompt = text, cwd = root, cfg = cfg(), new_id = opts.new_id, resume = opts.resume,
  })
  vim.list_extend(args, cfg().args or {})
  return args
end

-- Process ------------------------------------------------------------------------------

---Start a process, calling `on_line` per stdout line and `on_exit` at the end,
---both on the main loop. Replaceable in tests.
---@return { kill: fun() }
M.spawn = function(args, cwd, on_line, on_exit)
  local pending = ""
  local h = vim.system(args, {
    cwd = cwd,
    text = true,
    stdin = "",
    stdout = function(_, data)
      if not data then
        return
      end
      pending = pending .. data
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
        vim.schedule(function()
          on_line(line)
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      if pending ~= "" then
        on_line(pending)
        pending = ""
      end
      on_exit(res.code, res.stderr or "", res.signal)
    end)
  end)
  return {
    kill = function()
      pcall(h.kill, h, "sigterm")
    end,
  }
end

local start -- forward: queued pokes start again from the exit handler

start = function(root, text, retried)
  local a = M.adapter()
  local saved = M.session_id(root)
  local new_id = not saved and a.preset_id and uuid() or nil
  if new_id then
    local ok, err = pcall(save_session_id, root, new_id) -- before the run, so a second poke resumes it
    if not ok then
      notify(string.format("could not start %s: %s", a.name, one_line(tostring(err), 200)), vim.log.levels.ERROR)
      return nil
    end
  end
  local run = { status = "working", text = text }
  runs[root] = run
  local function on_line(line)
    local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(event) ~= "table" then
      return
    end
    local r = a.parse(event) or {}
    if r.session_id and not saved and not new_id and r.session_id ~= M.session_id(root) then
      local sok, serr = pcall(save_session_id, root, r.session_id) -- agents that pick their own id
      if not sok then
        notify("could not store the session id: " .. one_line(serr, 200), vim.log.levels.ERROR)
      end
    end
    if r.done then
      run.result = vim.tbl_extend("force", run.result or {}, r)
      run.result.error = r.error -- a final result supersedes an earlier non-fatal error event
    elseif r.error then
      run.result = vim.tbl_extend("force", run.result or {}, r)
    end
  end
  local function on_exit_unsafe(code, stderr, signal)
    if runs[root] ~= run then
      return -- stopped meanwhile
    end
    local r = run.result
    if signal and signal ~= 0 and not (r and r.done) then
      code = code ~= 0 and code or 128 + signal
      stderr = vim.trim(stderr .. " killed by signal " .. signal)
    end
    if code == 0 and not (r and r.error) then
      run.status = "done"
    else
      local err = vim.trim((r and r.error) or stderr or "")
      if err == "" then
        err = "exit code " .. tostring(code)
      end
      -- the saved session is gone: start a new one, once (a second loss cannot be fixed by retrying)
      if saved and not retried and a.lost_session and a.lost_session(err) then
        local fok, ferr = pcall(forget, root)
        if not fok then
          run.status, run.error = "failed", one_line(tostring(ferr), 200)
          notify(string.format("%s failed: %s", a.name, run.error), vim.log.levels.ERROR)
          local q = run.queued
          if q then
            start(root, q)
          end
          return
        end
        local again = start(root, text, true)
        if again then
          again.queued = run.queued -- a poke that waited for this run still waits
        elseif run.queued then
          start(root, run.queued)
        end
        return
      end
      run.status, run.error = "failed", one_line(err, 200)
      notify(string.format("%s failed: %s", a.name, run.error), vim.log.levels.ERROR)
    end
    local q = run.queued
    if q then
      start(root, q)
    end
  end
  local function on_exit(code, stderr, signal)
    local ok, err = pcall(on_exit_unsafe, code, stderr, signal)
    if not ok then
      if runs[root] == run and run.status == "working" then
        run.status, run.error = "failed", one_line(tostring(err), 200)
      end
      notify(string.format("%s failed: %s", a.name, one_line(tostring(err), 200)), vim.log.levels.ERROR)
    end
  end
  local spawned, handle = pcall(function()
    return M.spawn(M.args(root, text, { resume = saved, new_id = new_id }), root, on_line, on_exit)
  end)
  if not spawned then -- vim.system throws when the command or its directory is missing
    if new_id then
      pcall(forget, root) -- that session was never created
    end
    run.status, run.error = "failed", one_line(tostring(handle), 200)
    notify(string.format("could not start %s: %s", a.name, run.error), vim.log.levels.ERROR)
    return nil
  end
  run.handle = handle
  return run
end

---Send `text` to this root's background agent, starting or resuming it.
---@return boolean started false when the poke was queued or could not start
function M.poke(root, text)
  local run = runs[root]
  if run and run.status == "working" then
    if run.queued then
      notify("replacing the queued prompt with the latest one")
    else
      notify("the agent is still working; your prompt runs when it is done")
    end
    run.queued = text
    return false
  end
  return start(root, text) ~= nil
end

---Stop the running process of this root (the session is kept). A queued prompt
---is dropped and reported as cancelled.
---@return boolean stopped
function M.stop(root)
  local run = runs[root]
  if run and run.status == "working" then
    runs[root] = nil
    if run.handle then
      run.handle.kill()
    end
    if run.queued then
      notify("stopped; the queued prompt was cancelled", vim.log.levels.WARN)
    end
    return true
  end
  return false
end

---Stop every run (Neovim is quitting).
function M.stop_all()
  for root in pairs(vim.deepcopy(runs)) do
    M.stop(root)
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("agent-poke-headless", { clear = true }),
  callback = function()
    M.stop_all()
  end,
})

return M
