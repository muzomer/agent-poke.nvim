# agent-poke.nvim

Send a prompt from Neovim to a coding agent. If you run an agent in
[herdr](https://herdr.dev), you pick it once per project root and the prompt is
delivered to it. Otherwise (or when herdr is gone) a background agent
(`claude -p`, codex, opencode or gemini) runs the prompt headlessly in one
resumable conversation per project root.

Requires Neovim 0.10+. No autocmds or mappings are created until you call `require("agent-poke").setup()`.

## Install

lazy.nvim:

```lua
{
  "muzomer/agent-poke.nvim",
  config = function()
    require("agent-poke").setup({})
  end,
}
```

vim.pack (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/muzomer/agent-poke.nvim" })
require("agent-poke").setup({})
```

## Setup options

These are the defaults; pass only what you want to change.

```lua
require("agent-poke").setup({
  agent = "auto",     -- who gets poked: "auto", "herdr" or "headless"
  isolate = "fork",   -- "fork", "subagent" or false
  headless = {        -- the background agent
    agent = "claude", -- "claude", "codex", "opencode" or "gemini"
    cmd = nil,          -- its executable (default: the agent's own)
    allowed_tools = nil, -- claude: replaces the default tool list (Read, Grep, Glob)
    extra_tools = {},   -- claude: rules added to the default list
    permission_mode = nil, -- claude: --permission-mode; codex: --sandbox
                           -- (default "workspace-write"); gemini: --approval-mode;
                           -- opencode: "auto" skips permission prompts
    args = {},          -- extra arguments for every run
  },
})
```

- `agent`: `"auto"` pokes a herdr agent you pick, else the background agent;
  `"herdr"` only herdr (errors when it is not running); `"headless"` always the
  background agent.
- `isolate`: how to keep the work out of a herdr agent's own session.
  `"fork"` runs a throwaway fork of its session as a background run (needs an
  agent that can fork: claude or opencode); if that is not possible the prompt
  is typed into the pane (with a subagent note when the agent supports subagents). `"subagent"` types the prompt into the pane with a
  note asking the agent to use a subagent (agents that support it). `false`
  types the prompt in as is.

## API

All functions take the project `root` (a directory path).

```lua
local ap = require("agent-poke")

ap.setup({ agent = "headless" })          -- configure; returns the config
ap.poke(vim.fn.getcwd(), "run the tests") -- send a prompt
ap.pick(vim.fn.getcwd(), function() end)  -- choose the agent (herdr panes or the background agent); callback is optional
ap.output(vim.fn.getcwd())                -- toggle a window following the current/last background run
ap.chat(vim.fn.getcwd())                  -- open the background session interactively in a terminal
ap.stop(vim.fn.getcwd())                  -- stop the background run
```

- `poke(root, prompt)`: delivers to the picked herdr pane, else the background
  agent. A poke while a run is in flight is queued and runs when it finishes.
- `pick(root, on_pick)`: lets you choose between the agents running in herdr
  and the background agent; the choice is remembered for the root.
- `output(root)`: a second call closes the window. It refreshes while the run
  is in flight.
- `chat(root)`: resumes the stored session with the agent's own CLI; needs a
  session (poke first) and no run in flight.
- `stop(root)`: stops the run; notifies when there is none.
- `config`: the current configuration table.

## State

Per-root state (picked target, background session id) is stored as JSON under
`vim.fn.stdpath("state") .. "/agent-poke/"`, one file per root, written
atomically under a lock.

Legacy import: if a root has no state yet but a code-review.nvim session file
`<root>/.code-review/headless.json` exists, its session id (and agent) is
imported on first read.

## Backends

The background agent (`headless.agent`):

| agent      | executable | fork | notes |
|------------|------------|------|-------|
| `claude`   | `claude`   | yes  | `claude -p`, stream-json; tools limited by `allowed_tools`/`extra_tools` |
| `codex`    | `codex`    | no   | `codex exec --json`; sandbox from `permission_mode` |
| `opencode` | `opencode` | yes  | `permission_mode = "auto"` skips permission prompts |
| `gemini`   | `gemini`   | no   | `permission_mode` becomes `--approval-mode` |

Use `headless.cmd` to point at a different executable.
