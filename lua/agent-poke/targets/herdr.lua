---Poke an agent running in herdr (https://herdr.dev), which can submit a prompt
---to any agent pane from outside (`herdr agent prompt <pane> <text>`). The agent
---is chosen once per root in core's picker (agent-poke) and remembered with
---agent-poke.state. This is a target: core offers its panes next to the
---background agent and falls back to the background agent when herdr is down
---or the chosen pane is gone. Forked deliveries run through agent-poke.headless.
local headless = require("agent-poke.headless")

local M = {}

M.name = "herdr"
M.legacy_agents = { "herdr", "auto" } -- the deprecated config.agent values that enable this target

M.TIMEOUT_MS = 8000

M.STYLE = {
  subagent = "Handle this in a subagent (Task tool) so this conversation stays small: give it this whole message."
    .. " When it is done, answer here with one line only.",
  fork = "You are a temporary copy of the conversation above, started only to handle this request:"
    .. " nothing you say here is kept, so put everything that matters into your actions. End with one line only.",
}

local function notify(msg, level)
  vim.notify("agent-poke: " .. msg, level or vim.log.levels.INFO)
end

local function config()
  return require("agent-poke").config
end

---Options of this adapter (setup({ targets = { herdr = { isolate = ... } } })).
M.opts = {}

---Called by setup() each time the target is enabled.
function M.configure(opts)
  M.opts = type(opts) == "table" and opts or {}
end

---Why a herdr call failed, from its result.
local function failure(res)
  if res.code == 124 or (res.signal == 15 and (res.stderr or "") == "") then
    return string.format("herdr did not answer within %ds", M.TIMEOUT_MS / 1000)
  end
  local err = vim.trim(res.stderr or "")
  if err ~= "" then
    return err
  end
  local out = vim.trim(res.stdout or "")
  return out ~= "" and out or ("herdr exited with " .. tostring(res.code))
end

---Run herdr and wait for it (at most TIMEOUT_MS): its result, also when herdr
---is not installed or does not answer in time. poke() returns its status
---synchronously, so these calls are short and bounded.
---A deadline (ms, monotonic clock) for all the synchronous calls of one step.
local function new_deadline()
  return vim.uv.hrtime() / 1e6 + M.TIMEOUT_MS
end

---`deadline` is shared by the calls of one poke step, so that together they
---block for at most TIMEOUT_MS, not TIMEOUT_MS each.
local function run_sync(args, deadline)
  deadline = deadline or new_deadline()
  local left = math.floor(deadline - vim.uv.hrtime() / 1e6)
  if left < 1 then
    return { code = 124, stdout = "", stderr = "" }
  end
  local ok, res = pcall(function()
    return vim.system(args, { text = true, timeout = left }):wait(left + 2000)
  end)
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  return res
end

---Decode the JSON herdr prints. Errors come as {"error": {code, message}} and
---are reported even when the exit code is 0.
---@return table? result
---@return string? err
local function decode(res)
  if not res then
    return nil, "herdr did not answer"
  end
  local ok, data = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
  if ok and type(data) == "table" then
    if data.error then
      return nil, string.format("%s: %s", data.error.code or "error", data.error.message or "")
    end
    return data.result or data
  end
  if res.code ~= 0 then
    return nil, failure(res)
  end
  if vim.trim(res.stdout or "") ~= "" then
    return nil, "herdr printed something unexpected: " .. vim.split(vim.trim(res.stdout), "\n")[1]:sub(1, 120)
  end
  return {}
end

---Is there a herdr to talk to?
function M.available()
  return (vim.env.HERDR_SOCKET_PATH or "") ~= "" and vim.fn.executable("herdr") == 1
end

---Agents herdr knows about (this pane excluded).
---@return table[]? agents { pane_id, title, status, cwd, agent, session, dir }
---@return string? err
local function agent_list(res)
  local result, err = decode(res)
  if not result then
    return nil, err
  end
  local own = vim.env.HERDR_PANE_ID
  local list = {}
  for _, a in ipairs(result.agents or {}) do
    if a.pane_id ~= own then
      list[#list + 1] = {
        id = a.pane_id,
        pane_id = a.pane_id,
        title = a.terminal_title_stripped or a.terminal_title or a.agent or a.pane_id,
        status = a.agent_status or "?",
        cwd = ((a.cwd or ""):gsub("^" .. vim.pesc(vim.env.HOME or "\0"), "~")),
        agent = a.agent,
        session = a.agent_session and a.agent_session.value, -- herdr's guess of its session
        dir = a.cwd, -- where the pane is now (cwd above is for display)
      }
    end
  end
  return list
end

local function list_agents(deadline)
  return agent_list(run_sync({ "herdr", "agent", "list" }, deadline))
end

-- Sessions of herdr panes ------------------------------------------------------
-- To fork the session of a pane we need its id and the directory it was started
-- in. herdr reports the id; for Claude Code it is only used when its transcript
-- is found, and the directory is read from that transcript.

local function claude_dir()
  local env = vim.env.CLAUDE_CONFIG_DIR
  return vim.fs.normalize(env and env ~= "" and env or "~/.claude")
end

---How Claude Code names the directory of a project: every non-alphanumeric
---character becomes "-".
function M.project_dir_name(cwd)
  return (cwd:gsub("[^%w]", "-"))
end

---The directory a session was started in, read from its transcript (the first
---recorded cwd that matches the transcript's project directory).
---@return string? cwd
function M.session_cwd(transcript)
  local f = io.open(transcript, "r")
  if not f then
    return nil
  end
  local dir = vim.fs.basename(vim.fs.dirname(transcript))
  local found
  for _ = 1, 200 do
    local line = f:read("l")
    if not line then
      break
    end
    local cwd = line:match('"cwd":"(.-)"')
    if cwd and M.project_dir_name(cwd) == dir then
      found = cwd
      break
    end
  end
  f:close()
  return found
end

---The session to fork for a herdr agent: for Claude Code only when its
---transcript is found, for other agents from the pane's directory.
---@return { id: string, cwd: string, agent: string }?
function M.session_of(target)
  local agent = target.agent or "claude"
  if agent ~= "claude" then
    return target.session and target.dir and { id = target.session, cwd = target.dir, agent = agent } or nil
  end
  if not target.session then
    return nil
  end
  local transcript = vim.fn.glob(claude_dir() .. "/projects/*/" .. target.session .. ".jsonl", false, true)[1]
  local cwd = transcript and M.session_cwd(transcript)
  if cwd then
    return { id = target.session, cwd = cwd, agent = "claude" }
  end
end

-- Sending ------------------------------------------------------------------------------

---Run fn with vim.notify captured; returns the messages and fn's results.
local function capture(fn)
  local orig, msgs = vim.notify, {}
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg = msg, level = level }
  end
  local res = vim.F.pack_len(pcall(fn))
  vim.notify = orig
  if not res[1] then
    error(res[2], 0)
  end
  return msgs, res[2], res[3]
end

---Report a failed delivery once, on one line, and keep the prompt in the " register.
local function fail(what, prompt, reason)
  reason = vim.trim(tostring(reason or "")):gsub("^agent%-poke: ", ""):gsub("%s*\n%s*", " ")
  local kept = pcall(vim.fn.setreg, '"', prompt)
  notify(
    string.format("could not poke %s%s%s", what, reason ~= "" and (": " .. reason) or "", kept and " (prompt copied to the \" register)" or ""),
    vim.log.levels.ERROR
  )
  return false
end

---@return "started"|"queued"|"forked"|false
local function background(root, prompt, fork, opts, what, sent)
  what = what or "the background agent"
  if not headless.available() and not fork then
    return fail(what, prompt, headless.command() .. " not found; set config.headless.cmd")
  end
  local o = vim.tbl_extend("force", {}, opts or {})
  o.fork = fork
  local msgs, _, status = capture(function()
    return headless.poke(root, sent or prompt, o)
  end)
  if not status then
    local last = msgs[#msgs]
    local reason = last and last.msg or "it did not start"
    if reason:find('prompt copied to the " register', 1, true) then -- already kept by headless
      for _, m in ipairs(msgs) do
        vim.notify(m.msg, m.level)
      end
      return false
    end
    return fail(what, prompt, reason)
  end
  if fork and status == "started" then
    notify("poked " .. what .. " (fork)")
  end
  for _, m in ipairs(msgs) do
    vim.notify(m.msg, m.level)
  end
  if fork and status == "started" then
    return "forked"
  end
  return status
end

---Deliver `prompt` to a live herdr agent: a throwaway fork of its session when
---isolate = "fork" and it can fork, else typed into its pane.
---@return "typed"|"forked"|"queued"|false
local function deliver(root, prompt, target, opts, deadline)
  local isolate = M.opts.isolate
  if isolate == nil then
    isolate = config().isolate
  end
  if isolate == nil then
    isolate = "fork"
  end
  local name = target.agent or "claude"
  local adapter = headless.adapter(name)
  local no_session = false
  if isolate == "fork" and adapter and adapter.fork and headless.available(name) then
    local fork = M.session_of(target)
    if fork then
      return background(root, prompt, fork, opts, target.title, M.STYLE.fork .. "\n\n" .. prompt)
    end
    no_session = true
  end
  local text = prompt
  if isolate and adapter and adapter.subagents then
    text = prompt .. "\n\n" .. M.STYLE.subagent
  end
  local result, err = decode(run_sync({ "herdr", "agent", "prompt", target.pane_id, text }, deadline))
  if result then
    notify("poked " .. target.title .. (no_session and " (typed: its session was not found to fork)" or ""))
    return "typed"
  end
  return fail(target.title, prompt, err)
end

---Target interface ---------------------------------------------------------------
---`ctx` is shared by the calls of one poke step (list, then deliver): the
---synchronous herdr calls together block for at most TIMEOUT_MS.

---Agents running in herdr (this pane left out); nothing when herdr is not here.
---@return table[]? entries, string? err
function M.list(_, ctx)
  if not M.available() then
    return {}
  end
  if ctx then
    ctx.deadline = ctx.deadline or new_deadline()
  end
  local agents, err = list_agents(ctx and ctx.deadline)
  if not agents then
    return nil, err
  end
  for _, a in ipairs(agents) do
    a.label = string.format("%-40s %-8s %s", a.title, a.status or "", a.cwd or "")
  end
  return agents
end

---Deliver `prompt` to a listed entry. A failure is reported here, once.
---@return "typed"|"forked"|"queued"|false
function M.deliver(root, entry, prompt, opts, ctx)
  local ok, res = pcall(deliver, root, prompt, entry, opts or {}, ctx and (ctx.deadline or new_deadline()) or new_deadline())
  if not ok then
    return fail(entry.title or "the agent", prompt, res)
  end
  return res
end

return M
