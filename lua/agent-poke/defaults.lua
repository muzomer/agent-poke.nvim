---Defaults, as in code-review.nvim.
return function()
  return {
    targets = {}, -- extra places to poke besides the background agent: names of built-in targets or specs
    agent = "auto", -- legacy ("auto", "headless", ...); superseded by targets
    isolate = "fork", -- keep the work out of a target agent's session: "fork", "subagent", or false (typed in as is)
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
