local M = {}

local defaults = require("agent-poke.defaults")

M.config = defaults()

local KNOWN_AGENTS = { claude = true, codex = true, opencode = true, gemini = true }

local BACKGROUND = "background" -- name of the background agent in a stored target

local function notify(msg, level)
  vim.notify("agent-poke: " .. msg, level or vim.log.levels.INFO)
end

---Registered targets, in registration order.
M.targets = {}

---Register a target: { name, deliver(root, entry, prompt, opts) -> status, err,
---available?() -> boolean, list?(root) -> { {id, title, ...} } }.
---list and deliver get a `ctx` table shared by the calls of one poke step.
---A target may have configure(opts) (its options from setup).
---@return boolean registered
function M.register_target(spec)
  if type(spec) ~= "table" or type(spec.name) ~= "string" or spec.name == "" then
    notify("a target needs a name", vim.log.levels.ERROR)
    return false
  end
  if type(spec.deliver) ~= "function" then
    notify('target "' .. spec.name .. '" needs a deliver function', vim.log.levels.ERROR)
    return false
  end
  for _, t in ipairs(M.targets) do
    if t.name == spec.name then
      notify('target "' .. spec.name .. '" is already registered', vim.log.levels.WARN)
      return false
    end
  end
  M.targets[#M.targets + 1] = spec
  return true
end

local function find_target(name)
  for _, t in ipairs(M.targets) do
    if t.name == name then
      return t
    end
  end
end

local function add_target(t, topts)
  if type(t) == "string" then
    if find_target(t) then
      return -- a built-in asked for twice
    end
    local ok, mod = pcall(require, "agent-poke.targets." .. t)
    if not ok then
      return notify('unknown target "' .. t .. '"', vim.log.levels.ERROR)
    end
    if M.register_target(mod) and type(mod.configure) == "function" then
      mod.configure(type(topts) == "table" and topts or {})
    end
  else
    M.register_target(t)
  end
end

---Targets a legacy `agent` option stands for: the built-in adapters that list
---that value in `legacy_agents`; none for "headless" or anything else.
local function legacy_targets(agent)
  if type(agent) ~= "string" then
    return nil
  end
  local names = {}
  for _, f in ipairs(vim.api.nvim_get_runtime_file("lua/agent-poke/targets/*.lua", true)) do
    local name = vim.fn.fnamemodify(f, ":t:r")
    local ok, mod = pcall(require, "agent-poke.targets." .. name)
    if ok and type(mod) == "table" and vim.tbl_contains(mod.legacy_agents or {}, agent) then
      names[#names + 1] = name
    end
  end
  return names
end

---@param opts? table
function M.setup(opts)
  opts = vim.deepcopy(opts or {})
  local agent = type(opts.headless) == "table" and opts.headless.agent
  if agent ~= nil and agent ~= false and not KNOWN_AGENTS[agent] then
    vim.notify(
      string.format('agent-poke: unknown headless.agent "%s" (use claude, codex, opencode or gemini); keeping "%s"',
        tostring(agent), tostring(M.config.headless.agent)),
      vim.log.levels.ERROR
    )
    opts.headless.agent = nil
  end
  if opts.agent ~= nil then
    notify('the `agent` option is deprecated; use `targets` to enable adapters (the background agent is always on)',
      vim.log.levels.WARN)
  end
  local targets = opts.targets
  opts.targets = nil
  if targets == nil then
    targets = legacy_targets(opts.agent)
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  M.targets = {} -- a later setup() replaces the target list
  for _, t in ipairs(targets or {}) do
    local topts = type(t) == "string" and targets[t] or nil -- { "name", name = { ... } }
    add_target(t, topts)
  end
  local named = {} -- { name = { ...options } }
  for k, v in pairs(targets or {}) do
    if type(k) == "string" and v then
      named[#named + 1] = k
    end
  end
  table.sort(named)
  for _, k in ipairs(named) do
    add_target(k, targets[k])
  end
  return M.config
end

local function is_available(t)
  if type(t.available) ~= "function" then
    return true
  end
  local ok, res = pcall(t.available)
  return ok and res and true or false
end

local function background(root, prompt, opts)
  local _, status = require("agent-poke.headless").poke(root, prompt, opts)
  return status or false
end

---Deliver through a target entry; a throwing target must not escape.
local function deliver(t, root, entry, prompt, opts, ctx)
  local ok, status, err = pcall(t.deliver, root, entry, prompt, opts, ctx or {})
  if not ok then
    notify("poke failed: " .. tostring(status), vim.log.levels.ERROR)
    return false
  end
  if not status and err then
    notify("poke failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return status
end

local function entries_of(t, root, ctx)
  if type(t.list) ~= "function" or not is_available(t) then
    return {}
  end
  local ok, list, err = pcall(t.list, root, ctx or {})
  if not ok or type(list) ~= "table" then
    notify('cannot list "' .. t.name .. '": ' .. tostring(ok and err or list), vim.log.levels.WARN)
    return {}, true
  end
  return list
end

local function remember(root, value)
  local ok, err = pcall(require("agent-poke.state").set, root, "target", value)
  if not ok then
    notify("could not remember the agent: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function pick_generic(root, on_pick)
  local headless = require("agent-poke.headless")
  local items = {}
  local list_failed = false
  for _, t in ipairs(M.targets) do
    local list, failed = entries_of(t, root)
    list_failed = list_failed or failed or false
    for _, e in ipairs(list) do
      items[#items + 1] = { target = t, entry = e, title = tostring(e.label or e.title or e.id) }
    end
  end
  if headless.available() then
    items[#items + 1] = { title = vim.fs.basename(headless.command()) .. " (background)" }
  end
  if #items == 0 then
    return notify("no agent to poke: " .. headless.command() .. " not found; set config.headless.cmd", vim.log.levels.WARN)
  end
  local function choose(item)
    if not item then
      return
    end
    local value = item.target and { target = item.target.name, id = item.entry.id } or { target = BACKGROUND }
    if not on_pick then
      return remember(root, value)
    end
    local ok, res = pcall(on_pick, item)
    if not ok then
      notify("poke failed: " .. tostring(res), vim.log.levels.ERROR)
    elseif res then -- stored only once the prompt was delivered
      remember(root, value)
    end
  end
  if #items == 1 and not items[1].target and not list_failed then -- only the background agent: nothing to choose
    if not on_pick then
      notify("the background agent is the only target; no other agent to choose")
    end
    return choose(items[1])
  end
  local function open()
    vim.ui.select(items, {
      prompt = "Poke which agent?",
      format_item = function(i)
        return i.title
      end,
    }, choose)
  end
  -- From insert mode (a mapping) its `stopinsert` only applies after the mapping
  -- returns and would knock a picker opened meanwhile out of its input.
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.schedule(open)
  else
    open()
  end
end

---Poke root's agent with `prompt`: the remembered target entry, else the background agent.
---opts: { cwd?, dirs?, env?, on_start?, pick? }.
---@return "started"|"queued"|"typed"|"forked"|false
function M.poke(root, prompt, opts)
  opts = opts or {}
  if #M.targets == 0 then
    return background(root, prompt, opts)
  end
  if opts.pick then
    local result = false
    pick_generic(root, function(item)
      if item.target then
        result = deliver(item.target, root, item.entry, prompt, opts)
      else
        result = background(root, prompt, opts)
      end
      return result
    end)
    return result
  end
  local saved = require("agent-poke.state").get(root).target
  local target = type(saved) == "table" and saved.target and find_target(saved.target)
  if target then
    local ctx = {} -- list and deliver share one deadline
    local list, failed = entries_of(target, root, ctx)
    for _, e in ipairs(list) do
      if e.id == saved.id then
        return deliver(target, root, e, prompt, opts, ctx)
      end
    end
    if not failed then -- a failed list already said why
      notify("the agent you used before is gone; the background agent gets the prompt", vim.log.levels.WARN)
    end
  end
  return background(root, prompt, opts)
end

---State of root's background run: nil before any, else { status = "working"|"done"|"failed"|"stopped", error? }.
function M.status(root)
  return require("agent-poke.headless").status(root)
end

---Readable output lines of root's current/last background run.
function M.lines(root)
  return require("agent-poke.headless").lines(root)
end

---Choose root's agent (the targets' entries and the background agent).
function M.pick(root, on_pick)
  pick_generic(root, on_pick)
end

---Toggle a window following root's current/last background run.
function M.output(root)
  require("agent-poke.output").toggle(root)
end

---Open root's background session interactively in a terminal.
function M.chat(root)
  require("agent-poke.headless").chat(root)
end

---Stop root's background run.
function M.stop(root)
  if not require("agent-poke.headless").stop(root) then
    vim.notify("agent-poke: no background run to stop", vim.log.levels.INFO)
  end
end

return M
