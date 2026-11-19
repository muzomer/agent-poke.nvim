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
---A built-in adapter module may also provide poke(root, prompt, opts) and
---pick(root, on_pick), taking over those steps.
---@return boolean registered
function M.register_target(spec)
  if type(spec) ~= "table" or type(spec.name) ~= "string" or spec.name == "" then
    notify("a target needs a name", vim.log.levels.ERROR)
    return false
  end
  if type(spec.deliver) ~= "function" and type(spec.poke) ~= "function" then
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

local function add_target(t)
  if type(t) == "string" then
    if find_target(t) then
      return -- a built-in asked for twice
    end
    local ok, mod = pcall(require, "agent-poke.targets." .. t)
    if not ok then
      return notify('unknown target "' .. t .. '"', vim.log.levels.ERROR)
    end
    M.register_target(mod)
  else
    M.register_target(t)
  end
end

---Targets a legacy `agent` option stands for: "auto" the built-in adapters that
---flag `legacy_auto`, "headless" none, any other name the built-in of that name.
local function legacy_targets(agent)
  if agent == "auto" then
    local names = {}
    for _, f in ipairs(vim.api.nvim_get_runtime_file("lua/agent-poke/targets/*.lua", true)) do
      local name = vim.fn.fnamemodify(f, ":t:r")
      local ok, mod = pcall(require, "agent-poke.targets." .. name)
      if ok and type(mod) == "table" and mod.legacy_auto then
        names[#names + 1] = name
      end
    end
    return names
  end
  if type(agent) == "string" and agent ~= "headless"
    and #vim.api.nvim_get_runtime_file("lua/agent-poke/targets/" .. agent .. ".lua", false) > 0 then
    return { agent }
  end
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
  local targets = opts.targets
  opts.targets = nil
  if targets == nil then
    targets = legacy_targets(opts.agent)
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  for _, t in ipairs(targets or {}) do
    add_target(t)
  end
  return M.config
end

local function takeover(name)
  for _, t in ipairs(M.targets) do
    if type(t[name]) == "function" then
      return t
    end
  end
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
local function deliver(t, root, entry, prompt, opts)
  local ok, status, err = pcall(t.deliver, root, entry, prompt, opts)
  if not ok then
    notify("poke failed: " .. tostring(status), vim.log.levels.ERROR)
    return false
  end
  if not status and err then
    notify("poke failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return status
end

local function entries_of(t, root)
  if type(t.list) ~= "function" or not is_available(t) then
    return {}
  end
  local ok, list = pcall(t.list, root)
  if not ok or type(list) ~= "table" then
    notify('cannot list "' .. t.name .. '": ' .. tostring(list), vim.log.levels.WARN)
    return {}
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
  for _, t in ipairs(M.targets) do
    for _, e in ipairs(entries_of(t, root)) do
      items[#items + 1] = { target = t, entry = e, title = tostring(e.title or e.id) }
    end
  end
  items[#items + 1] = { title = vim.fs.basename(headless.command()) .. " (background)" }
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
  if #items == 1 then -- only the background agent: nothing to choose
    if not on_pick then
      notify("the background agent is the only target; no other agent to choose")
    end
    return choose(items[1])
  end
  vim.ui.select(items, {
    prompt = "Poke which agent?",
    format_item = function(i)
      return i.title
    end,
  }, choose)
end

---Poke root's agent with `prompt`: the remembered target entry, else the background agent.
---opts: { cwd?, dirs?, env?, on_start?, pick? }.
---@return "started"|"queued"|"typed"|"forked"|false
function M.poke(root, prompt, opts)
  opts = opts or {}
  local t = takeover("poke")
  if t then
    return t.poke(root, prompt, opts)
  end
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
    for _, e in ipairs(entries_of(target, root)) do
      if e.id == saved.id then
        return deliver(target, root, e, prompt, opts)
      end
    end
    notify("the agent you used before is gone; the background agent gets the prompt", vim.log.levels.WARN)
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
  local t = takeover("pick")
  if t then
    return t.pick(root, on_pick)
  end
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
