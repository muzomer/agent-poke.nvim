local M = {}

---Defaults, as in code-review.nvim.
local function defaults()
  return {
    agent = "auto", -- who gets poked: "auto" (a herdr agent you pick, else the background agent), "herdr", "headless"
    isolate = "fork", -- keep the work out of a herdr agent's session: "fork", "subagent", or false (typed in as is)
    headless = { -- the background agent: one resumable conversation
      agent = "claude", -- "claude", "codex", "opencode" or "gemini"
      cmd = nil, -- its executable (default: the agent's own)
      allowed_tools = nil, -- claude: replaces the default tool list
      extra_tools = {}, -- claude: rules added to the default list
      permission_mode = nil, -- claude: --permission-mode; codex: --sandbox; gemini: --approval-mode
      args = {}, -- extra arguments for every run
    },
  }
end

M.config = defaults()

---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults(), vim.deepcopy(opts or {}))
  return M.config
end

---Poke root's agent with `prompt`: the picked herdr pane, else the background agent.
function M.poke(root, prompt)
  require("agent-poke.herdr").poke(root, prompt)
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
