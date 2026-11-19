---The background agent: a coding agent started without a terminal (`claude -p`,
---`codex exec`, `opencode run`, `gemini -p`), one resumable conversation per
---project root. The first poke starts a session and stores its id with
---agent-poke.state; later pokes resume it. Runs start in <root> (agents file
---their sessions by directory). A poke while a run is in flight is queued
---(one slot: the latest wins) and runs when the run ends.
local state = require("agent-poke.state")
local progress = require("agent-poke.progress")

local uv = vim.uv or vim.loop

local M = {}

M.MAX_LINES = 500 -- output lines kept per run

local runs = {} -- root -> { handle, lines, status = "working"|"done"|"failed"|"stopped", queued?, text }
local chats = {} -- root -> terminal job id of an open chat

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

local function text_lines(text)
  text = vim.trim(tostring(text or ""))
  return text ~= "" and vim.split(text, "\n", { plain = true }) or {}
end

local function tool_line(name, input)
  input = type(input) == "table" and input or {}
  local what = input.command or input.cmd or input.file_path or input.filePath or input.path or input.pattern
    or input.description or ""
  if type(what) == "table" then
    what = table.concat(what, " ")
  end
  return string.format("→ %s %s", name or "tool", one_line(what, 120))
end

-- Adapters (as in code-review.nvim's agents.lua) ----------------------------------

local agents = {}

agents.claude = {
  name = "Claude Code",
  cmd = "claude",
  preset_id = true,
  fork = true, -- a session can be copied
  subagents = true, -- the agent can hand work to a subagent (prompt wording)
  DEFAULT_TOOLS = { "Read", "Grep", "Glob" },
  args = function(o)
    local c = o.cfg
    local args = { o.cmd, "-p", o.prompt, "--output-format", "stream-json", "--verbose" }
    if o.fork then
      vim.list_extend(args, { "--resume", o.fork, "--fork-session" })
    elseif o.resume then
      vim.list_extend(args, { "--resume", o.resume })
    else
      vim.list_extend(args, { "--session-id", o.new_id })
    end
    local tools = vim.deepcopy(c.allowed_tools or agents.claude.DEFAULT_TOOLS)
    vim.list_extend(tools, c.extra_tools or {})
    vim.list_extend(tools, o.tools or {})
    local seen, uniq = {}, {}
    for _, t in ipairs(tools) do
      if not seen[t] then
        seen[t] = true
        uniq[#uniq + 1] = t
      end
    end
    tools = uniq
    if #tools > 0 then
      args[#args + 1] = "--allowedTools"
      vim.list_extend(args, tools)
    end
    if c.permission_mode then
      vim.list_extend(args, { "--permission-mode", c.permission_mode })
    end
    for _, d in ipairs(o.dirs or {}) do
      vim.list_extend(args, { "--add-dir", d })
    end
    return args
  end,
  parse = function(ev)
    if ev.type == "assistant" and type(ev.message) == "table" then
      local out = {}
      for _, c in ipairs(ev.message.content or {}) do
        if c.type == "text" then
          vim.list_extend(out, text_lines(c.text))
        elseif c.type == "tool_use" then
          out[#out + 1] = tool_line(c.name, c.input)
        end
      end
      return { lines = out }
    elseif ev.type == "result" then
      return { done = true, error = ev.is_error and tostring(ev.result or "failed") or nil }
    end
  end,
  chat = function(cmd, id)
    return { cmd, "--resume", id }
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
    for _, d in ipairs(o.dirs or {}) do
      vim.list_extend(args, { "--add-dir", d })
    end
    if o.resume then
      vim.list_extend(args, { "resume", o.resume })
    end
    args[#args + 1] = o.prompt
    return args
  end,
  chat = function(cmd, id)
    return { cmd, "resume", id }
  end,
  parse = function(ev)
    local item = type(ev.item) == "table" and ev.item or nil
    if ev.type == "thread.started" then
      return { session_id = ev.thread_id }
    elseif ev.type == "item.started" and item and item.type == "command_execution" then
      return { lines = { "→ $ " .. one_line(item.command, 120) } }
    elseif ev.type == "item.completed" and item and item.type == "agent_message" then
      return { lines = text_lines(item.text) }
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
  fork = true,
  chat = function(cmd, id)
    return { cmd, "--session", id }
  end,
  args = function(o)
    local args = { o.cmd, "run", "--format", "json" }
    local session = o.fork or o.resume
    if session then
      vim.list_extend(args, { "--session", session })
    end
    if o.fork then
      args[#args + 1] = "--fork"
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
    local text = part.type == "text" and part.text or (ev.type == "text" and ev.text)
    if text then
      res.lines = text_lines(text)
    elseif part.type == "tool" or ev.type == "tool_use" then
      res.lines = { tool_line(part.tool or ev.name, (part.state or {}).input or ev.input) }
    elseif ev.type == "error" then
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
    for _, d in ipairs(o.dirs or {}) do
      vim.list_extend(args, { "--include-directories", d })
    end
    return args
  end,
  chat = function(cmd)
    return { cmd, "-r", "latest" }
  end,
  parse = function(ev)
    if ev.type == "init" then
      return { session_id = ev.session_id or ev.sessionId or "latest" }
    elseif ev.type == "message" and ev.role ~= "user" then
      local text = type(ev.content) == "string" and ev.content or ""
      if ev.delta then
        return { append = text }
      end
      return { lines = text_lines(text) }
    elseif ev.type == "tool_use" then
      return { lines = { tool_line(ev.tool_name or ev.name, ev.parameters or ev.args) } }
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

---The adapter of the configured background agent (or of `name`, e.g. the agent of a session to fork).
function M.adapter(name)
  return agents[name or agent_name()] or (not name and agents.claude) or nil
end

---Is the executable of the background agent (or of `name`) installed?
function M.available(name)
  local a = M.adapter(name)
  if not a then
    return false
  end
  local cmd = (not name or name == agent_name()) and M.command() or a.cmd
  return vim.fn.executable(cmd) == 1
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

---Directory a stored session runs in. A session stores the cwd it was started
---in; a legacy code-review.nvim one has none: its workdir is the `repo` of
---<root>/.code-review/session.json when that review is of commits, else root.
---@return string cwd
---@return boolean legacy_unknown legacy session whose workdir cannot be known
function M.session_cwd(root)
  local s = state.get(root).session
  if type(s) == "table" and type(s.cwd) == "string" and s.cwd ~= "" then
    return s.cwd, false
  end
  local f = io.open(root .. "/.code-review/session.json", "rb")
  if not f then
    return root, true
  end
  local text = f:read("a")
  f:close()
  local ok, d = pcall(vim.json.decode, text)
  if ok and type(d) == "table" and d.kind == "commits" and type(d.repo) == "string" and d.repo ~= "" then
    return d.repo, false
  end
  return root, false
end

---State of the current (or last) run of root: nil before any run.
---@return { status: "working"|"done"|"failed"|"stopped", error?: string }?
function M.status(root)
  local run = runs[root]
  return run and { status = run.status, error = run.error } or nil
end

---Readable output lines of the current (or last) run of root.
---@return string[]
function M.lines(root)
  local run = runs[root]
  return run and run.lines or {}
end

---Is a run of root in flight?
function M.running(root)
  local run = runs[root]
  return run ~= nil and run.status == "working"
end

local function push(run, lines)
  for _, l in ipairs(lines) do
    run.lines[#run.lines + 1] = l
  end
  if #run.lines > M.MAX_LINES then
    run.lines = vim.list_slice(run.lines, #run.lines - M.MAX_LINES + 1, #run.lines)
  end
end

local function save_session_id(root, id, cwd)
  state.set(root, "session", { id = id, agent = agent_name(), cwd = cwd })
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

---Command line of a run. `resume` = id of the session to continue, `new_id` = id for a new one,
---`fork` = id of a session to copy (run by `agent`, in `cwd`).
function M.args(root, text, opts)
  -- one adapter builds the line: a foreign agent (a fork) gets its own adapter,
  -- executable and no settings of the configured agent
  local foreign = opts.agent and opts.agent ~= agent_name()
  local adapter = M.adapter(opts.agent)
  local args = adapter.args({
    cmd = foreign and adapter.cmd or M.command(),
    prompt = text, cwd = opts.cwd or root, cfg = foreign and {} or cfg(),
    new_id = opts.new_id, resume = opts.resume, fork = opts.fork, dirs = opts.dirs,
    tools = opts.tools,
  })
  if not foreign then
    vim.list_extend(args, cfg().args or {})
  end
  return args
end

-- Process ------------------------------------------------------------------------------

---Start a process, calling `on_line` per stdout line and `on_exit` at the end,
---both on the main loop. Replaceable in tests.
---@return { kill: fun() }
M.spawn = function(args, cwd, on_line, on_exit, env)
  local pending = ""
  local h = vim.system(args, {
    cwd = cwd,
    env = env,
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

local MAX_QUEUED = 10 -- waiting pokes per root; the oldest is dropped beyond that

local start -- forward: queued pokes start again from the exit handler

---Start the oldest of `queue` (a list of { text, fork, opts }); the rest waits on that run.
---A prompt that cannot start is skipped.
local function start_next(root, queue)
  while #queue > 0 do
    local q = table.remove(queue, 1)
    if start(root, q.text, nil, q.fork, q.opts, queue, q.id) then
      return
    end
  end
end

local function start_unsafe(root, text, retried, fork, o, queue, id)
  o = o or {}
  local a = M.adapter(fork and fork.agent) or M.adapter()
  local saved = not fork and M.session_id(root) or nil
  local new_id = not fork and not saved and a.preset_id and uuid() or nil
  local saved_cwd, legacy_unknown
  if saved then
    saved_cwd, legacy_unknown = M.session_cwd(root)
  end
  local run_cwd = fork and fork.cwd or saved_cwd or o.cwd or root
  if new_id then
    local ok, err = pcall(save_session_id, root, new_id, run_cwd) -- before the run, so a second poke resumes it
    if not ok then
      notify(string.format("could not start %s: %s", a.name, one_line(tostring(err), 200)), vim.log.levels.ERROR)
      progress.set(id, "failed", one_line(tostring(err), 200))
      return nil
    end
  end
  local run = { id = id, status = "working", text = text, fork = fork, lines = {}, queue = queue or {} }
  runs[root] = run
  progress.set(id, "working")
  push(run, { string.format("● %s · %s", a.name, one_line(text, 80)) })
  local partial -- text streamed in pieces (delta events), shown as it grows
  local function on_line(line)
    local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(event) ~= "table" then
      partial = nil
      return push(run, { line })
    end
    local pok, r = pcall(a.parse, event)
    if not pok then
      return
    end
    r = r or {}
    if r.append then
      if partial then
        run.lines[#run.lines] = run.lines[#run.lines] .. r.append
      else
        push(run, { r.append })
        partial = true
      end
      local last = run.lines[#run.lines]
      if last:find("\n", 1, true) then
        run.lines[#run.lines] = nil
        push(run, vim.split(last, "\n", { plain = true }))
      end
    elseif r.lines and #r.lines > 0 then
      partial = nil
      push(run, r.lines)
    end
    if r.error and not r.done then
      push(run, { "⚠ " .. one_line(r.error, 200) })
    end
    if r.session_id and not fork and not saved and not new_id and r.session_id ~= M.session_id(root) then
      local sok, serr = pcall(save_session_id, root, r.session_id, run_cwd) -- agents that pick their own id
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
      progress.set(id, "done")
    else
      local err = vim.trim((r and r.error) or stderr or "")
      if err == "" then
        err = "exit code " .. tostring(code)
      end
      -- the saved session is gone: start a new one, once (a second loss cannot be fixed by retrying)
      if saved and not retried and a.lost_session and a.lost_session(err) then
        if legacy_unknown then
          notify(string.format(
            "the %s session %s of code-review.nvim was not found (its directory is unknown); starting a new one",
            a.name, saved
          ), vim.log.levels.WARN)
        end
        local fok, ferr = pcall(forget, root)
        if not fok then
          run.status, run.error = "failed", one_line(tostring(ferr), 200)
          progress.set(id, "failed", run.error)
          notify(string.format("%s failed: %s", a.name, run.error), vim.log.levels.ERROR)
          start_next(root, run.queue)
          return
        end
        -- pokes that waited for this run still wait, on the new one
        if not start(root, text, true, nil, vim.tbl_extend("force", o, { on_start = false }), run.queue, id) then
          start_next(root, run.queue)
        end
        return
      end
      run.status, run.error = "failed", one_line(err, 200)
      progress.set(id, "failed", run.error)
      notify(string.format("%s failed: %s", a.name, run.error), vim.log.levels.ERROR)
    end
    start_next(root, run.queue)
  end
  local function on_exit(code, stderr, signal)
    local ok, err = pcall(on_exit_unsafe, code, stderr, signal)
    if not ok then
      if runs[root] == run and run.status == "working" then
        run.status, run.error = "failed", one_line(tostring(err), 200)
        progress.set(id, "failed", run.error)
      end
      notify(string.format("%s failed: %s", a.name, one_line(tostring(err), 200)), vim.log.levels.ERROR)
    end
  end
  local spawned, handle = pcall(function()
    return M.spawn(M.args(root, text, {
      resume = saved, new_id = new_id, fork = fork and fork.id, agent = fork and fork.agent,
      cwd = run_cwd, dirs = o.dirs, tools = not fork and o.tools or nil,
    }), run_cwd, on_line, on_exit, o.env)
  end)
  if not spawned then -- vim.system throws when the command or its directory is missing
    if new_id then
      pcall(forget, root) -- that session was never created
    end
    run.status, run.error = "failed", one_line(tostring(handle), 200)
    progress.set(id, "failed", run.error)
    notify(string.format("could not start %s: %s", a.name, run.error), vim.log.levels.ERROR)
    return nil
  end
  run.handle = handle
  if type(o.on_start) == "function" then
    local cok, cerr = pcall(o.on_start)
    if not cok then
      notify("on_start failed: " .. one_line(tostring(cerr), 200), vim.log.levels.ERROR)
    end
  end
  return run
end

---start_unsafe that never throws: a failure ends the handle 'failed' (and the run, if it was set).
start = function(root, text, retried, fork, o, queue, id)
  local ok, res = pcall(start_unsafe, root, text, retried, fork, o, queue, id)
  if ok then
    return res
  end
  local msg = one_line(tostring(res), 200)
  local run = runs[root]
  if run and run.id == id and run.status == "working" and not run.handle then
    run.status, run.error = "failed", msg
  end
  progress.set(id, "failed", msg)
  notify("could not start the agent: " .. msg, vim.log.levels.ERROR)
  return nil
end

---Send `text` to this root's background agent, starting or resuming it.
---@return boolean started false when the poke was queued or could not start
---@return "started"|"queued"|false status
---@return string id handle of this poke (see agent-poke.progress)
---@param opts? { fork?: { id: string, cwd: string, agent?: string }, cwd?: string,  tools?: string[], dirs?: string[], env?: table<string,string>, on_start?: fun() }
function M.poke(root, text, opts)
  opts = opts or {}
  local fork = opts.fork
  if chats[root] then
    -- the chat has this session open interactively: do not resume it too
    pcall(vim.fn.setreg, '"', text)
    notify('a chat has this session open; prompt copied to the " register')
    return false, false, progress.new(root, "background", "failed", "a chat has this session open", true)
  end
  local run = runs[root]
  if run and run.status == "working" then
    if #run.queue >= MAX_QUEUED then
      local dropped = table.remove(run.queue, 1)
      progress.set(dropped.id, "failed", "dropped: too many prompts waiting")
      notify(string.format("%d prompts are already waiting; dropped the oldest", MAX_QUEUED))
    elseif #run.queue == 0 then
      notify("the agent is still working; your prompt runs when it is done")
    end
    local id = progress.new(root, "background", "queued", nil, true)
    run.queue[#run.queue + 1] = { text = text, fork = fork, opts = opts, id = id }
    return false, "queued", id
  end
  local id = progress.new(root, "background", "working", nil, true)
  local started = start(root, text, nil, fork, opts, nil, id) ~= nil
  return started, started and "started" or false, id
end

---Open root's conversation interactively in a terminal split, with the
---configured agent's own resume command on the stored session.
function M.chat(root)
  local id = M.session_id(root)
  if not id then
    return notify("no background agent session yet; poke first", vim.log.levels.WARN)
  end
  if M.running(root) then
    return notify("the background agent is still working; wait until it is done (or stop it)", vim.log.levels.WARN)
  end
  if chats[root] then
    return notify("the agent is already open in a chat", vim.log.levels.WARN)
  end
  if not M.available() then
    return notify(M.command() .. " not found; set config.headless.cmd", vim.log.levels.ERROR)
  end
  local cmd = M.adapter().chat(M.command(), id)
  local cwd = M.session_cwd(root)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  local job
  local opts = {
    cwd = cwd,
    on_exit = function()
      if chats[root] == job then
        chats[root] = nil
      end
    end,
  }
  local ok
  if vim.fn.has("nvim-0.11") == 1 then
    opts.term = true
    ok, job = pcall(vim.fn.jobstart, cmd, opts)
  else
    ok, job = pcall(vim.fn.termopen, cmd, opts)
  end
  if not ok or job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    return notify("could not start " .. M.command() .. (ok and "" or (": " .. tostring(job))), vim.log.levels.ERROR)
  end
  chats[root] = job
  vim.cmd.startinsert()
end

---Stop the running process of this root (the session is kept). A queued prompt
---is dropped and reported as cancelled.
---@return boolean stopped
function M.stop(root)
  local run = runs[root]
  if run and run.status == "working" then
    -- keep the stopped run's text for the output window; the stub also makes
    -- the old run's callbacks see runs[root] ~= run
    local lines = vim.list_slice(run.lines, 1, #run.lines)
    lines[#lines + 1] = "(stopped)"
    runs[root] = { lines = lines, status = "stopped", queue = {} }
    progress.set(run.id, "failed", "stopped")
    for _, q in ipairs(run.queue) do
      progress.set(q.id, "failed", "cancelled: the run was stopped")
    end
    if run.handle then
      run.handle.kill()
    end
    if #run.queue > 0 then
      local texts = {}
      for _, q in ipairs(run.queue) do
        texts[#texts + 1] = '"' .. one_line(q.text, 40) .. '"'
      end
      notify(string.format("stopped; %d queued prompt(s) cancelled: %s", #run.queue, table.concat(texts, ", ")),
        vim.log.levels.WARN)
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
