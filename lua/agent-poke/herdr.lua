---Poke an agent running in herdr (https://herdr.dev), which can submit a prompt
---to any agent pane from outside (`herdr agent prompt <pane> <text>`). The agent
---is chosen once per root in a picker and remembered with agent-poke.state; the
---background agent (agent-poke.headless) is offered in the picker and is the
---fallback when herdr or the chosen pane is gone.
local state = require("agent-poke.state")
local headless = require("agent-poke.headless")

local M = {}

M.TIMEOUT_MS = 8000

M.HEADLESS = "headless" -- pane_id of the background agent in a stored target

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

---Run herdr without blocking Neovim: `cb(result)` runs on the main loop, once,
---also when herdr is not installed or does not answer in time.
local function run_async(args, cb)
  local ok, err = pcall(vim.system, args, { text = true, timeout = M.TIMEOUT_MS }, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = -1, stdout = "", stderr = tostring(err) })
    end)
  end
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

local function list_agents(cb)
  run_async({ "herdr", "agent", "list" }, function(res)
    cb(agent_list(res))
  end)
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

-- Picking ------------------------------------------------------------------------------

local function background_target()
  return { pane_id = M.HEADLESS, title = vim.fs.basename(headless.command()) .. " (background)" }
end

local function remember(root, t)
  local ok, err = pcall(state.set, root, "target", { pane_id = t.pane_id, title = t.title })
  if not ok then
    notify("could not remember the agent: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function offer(root, agents, on_pick, list_err)
  local items = vim.list_extend({}, agents)
  if config().agent ~= "herdr" then
    local h = background_target()
    h.status = headless.session_id(root) and "resume" or "new"
    h.cwd = "runs without a terminal"
    items[#items + 1] = h
  end
  if #items == 0 then
    return notify("no other agent is running in herdr", vim.log.levels.WARN)
  end
  local function choose(choice)
    if not choice then
      return
    end
    remember(root, choice)
    if on_pick then
      local ok, err = pcall(on_pick, choice)
      if not ok then
        notify("poke failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end
  if #agents == 0 and not list_err and config().agent ~= "herdr" then -- nothing to choose from
    return choose(items[1])
  end
  local function open()
    vim.ui.select(items, {
      prompt = "Poke which agent?",
      format_item = function(a)
        return string.format("%-40s %-8s %s", a.title, a.status or "", a.cwd or "")
      end,
    }, choose)
  end
  -- Opened from insert mode (a mapping), its `stopinsert` only applies after the
  -- mapping returns and would knock a picker that opened meanwhile out of its
  -- input: open it after that.
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.schedule(open)
  else
    open()
  end
end

---Let the user choose the agent to poke for `root`: the agents running in herdr
---(this pane left out) plus the background agent. The choice is remembered per root.
---@param on_pick? fun(target: table) called with the choice
function M.pick(root, on_pick)
  if not M.available() then
    return offer(root, {}, on_pick)
  end
  list_agents(function(agents, err)
    if not agents then
      notify("cannot list agents: " .. tostring(err), vim.log.levels.WARN)
      agents = {}
    end
    offer(root, agents, on_pick, err)
  end)
end

-- Sending ------------------------------------------------------------------------------

local function background(root, prompt, fork)
  if not headless.available() and not fork then
    return notify(headless.command() .. " not found; set config.headless.cmd", vim.log.levels.ERROR)
  end
  headless.poke(root, prompt, fork and { fork = fork } or nil)
end

---Deliver `prompt` to a live herdr agent: a throwaway fork of its session when
---isolate = "fork" and it can fork, else typed into its pane.
local function deliver(root, prompt, target)
  local isolate = config().isolate
  if isolate == nil then
    isolate = "fork"
  end
  local name = target.agent or "claude"
  local adapter = headless.adapter(name)
  if isolate == "fork" and adapter and adapter.fork and headless.available(name) then
    local fork = M.session_of(target)
    if fork then
      notify("poked " .. target.title .. " (fork)")
      return background(root, M.STYLE.fork .. "\n\n" .. prompt, fork)
    end
    notify(string.format("could not find the session of %s to fork; typing the prompt into its pane instead", target.title),
      vim.log.levels.WARN)
  end
  local text = prompt
  if isolate and adapter and adapter.subagents then
    text = prompt .. "\n\n" .. M.STYLE.subagent
  end
  run_async({ "herdr", "agent", "prompt", target.pane_id, text }, function(res)
    local result, err = decode(res)
    if result then
      notify("poked " .. target.title)
    else
      notify(string.format("could not poke %s: %s", target.title, tostring(err)), vim.log.levels.ERROR)
    end
  end)
end

---Poke root's agent with `prompt`: the remembered one, else one picked now.
---Without herdr, or when the remembered pane is gone, the background agent gets it.
function M.poke(root, prompt)
  local mode = config().agent or "auto"
  if mode == "headless" or (mode == "auto" and not M.available()) then
    return background(root, prompt)
  end
  if not M.available() then
    return notify("herdr is not running here (config.agent = \"herdr\")", vim.log.levels.ERROR)
  end
  local saved = state.get(root).target
  if type(saved) ~= "table" or not saved.pane_id then
    return M.pick(root, function(target)
      if target.pane_id == M.HEADLESS then
        return background(root, prompt)
      end
      list_agents(function(agents, err)
        for _, a in ipairs(agents or {}) do
          if a.pane_id == target.pane_id then
            return deliver(root, prompt, a)
          end
        end
        notify("cannot reach " .. target.title .. (err and (": " .. tostring(err)) or ""), vim.log.levels.ERROR)
      end)
    end)
  end
  if saved.pane_id == M.HEADLESS then
    return background(root, prompt)
  end
  list_agents(function(agents, err)
    local ok, perr = pcall(function()
      if not agents then -- herdr hiccup: the prompt must not get lost
        notify("cannot list agents: " .. tostring(err), vim.log.levels.WARN)
        return mode == "auto" and background(root, prompt) or nil
      end
      for _, a in ipairs(agents) do
        if a.pane_id == saved.pane_id then
          return deliver(root, prompt, a) -- the live record: its session may have changed
        end
      end
      if mode == "auto" then
        notify("the agent you used before is gone; the background agent gets the prompt", vim.log.levels.WARN)
        return background(root, prompt)
      end
      notify("the agent you used before is gone; choose another", vim.log.levels.WARN)
      M.pick(root, function(target)
        list_agents(function(now)
          for _, a in ipairs(now or {}) do
            if a.pane_id == target.pane_id then
              return deliver(root, prompt, a)
            end
          end
        end)
      end)
    end)
    if not ok then
      notify("poke failed: " .. tostring(perr), vim.log.levels.ERROR)
    end
  end)
end

return M
