local M = {}

local defaults = require("agent-poke.defaults")

M.config = defaults()

local KNOWN_AGENTS = { claude = true, codex = true, opencode = true, gemini = true }

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
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  return M.config
end

---Poke root's agent with `prompt`: the picked herdr pane, else the background agent.
---opts: { cwd?, dirs?, env?, on_start?, pick? }.
---@return "started"|"queued"|"typed"|"forked"|false
function M.poke(root, prompt, opts)
  return require("agent-poke.herdr").poke(root, prompt, opts)
end

---State of root's background run: nil before any, else { status = "working"|"done"|"failed"|"stopped", error? }.
function M.status(root)
  return require("agent-poke.headless").status(root)
end

---Readable output lines of root's current/last background run.
function M.lines(root)
  return require("agent-poke.headless").lines(root)
end

---Choose root's agent (herdr panes and the background agent).
function M.pick(root, on_pick)
  require("agent-poke.herdr").pick(root, on_pick)
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
