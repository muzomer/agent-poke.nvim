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

return M
