# agent-poke.nvim

Send a prompt from Neovim to a coding agent. By default a background agent
(`claude -p`, codex, opencode or gemini) runs the prompt headlessly in one
resumable conversation per project root. [herdr](https://herdr.dev) is an
opt-in target: enable it with `targets = { "herdr" }` to poke an agent running
in herdr instead.

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
  targets = {},       -- extra targets besides the background agent (e.g. { "herdr" })
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

- `targets`: see [Targets](#targets). The old `agent` option is deprecated, see [Migration](#migration).
- `isolate`: how to keep the work out of a herdr agent's own session.
  `"fork"` runs a throwaway fork of its session as a background run (needs an
  agent that can fork: claude or opencode); if that is not possible the prompt
  is typed into the pane (with a subagent note when the agent supports subagents). `"subagent"` types the prompt into the pane with a
  note asking the agent to use a subagent (agents that support it). `false`
  types the prompt in as is.

## Background agent

The default. agent-poke works without any multiplexer: with no targets
enabled, `poke()` runs the prompt in a background agent (`headless.agent`,
see [Backends](#backends)), one resumable conversation per project root.

## Targets

A target is an extra place to poke besides the background agent. Enable
built-in ones in `setup`:

```lua
require("agent-poke").setup({ targets = { "herdr" } })
-- with options:
require("agent-poke").setup({ targets = { herdr = { isolate = "fork" } } })
```

The herdr adapter pokes an agent running in [herdr](https://herdr.dev); the
background agent stays offered in the picker and is the fallback when herdr
is gone. herdr is used only when this target is enabled.

Adapter authors register a target (a table) with `register_target`. Call it
after `setup()`, because `setup()` resets the target list. `configure(opts)` is
only called for built-in targets under `lua/agent-poke/targets/`, not for
tables passed to `register_target`:

```lua
require("agent-poke").register_target({
  name = "x",                                   -- unique name
  available = function() return true end,       -- optional: is the target usable now?
  list = function(root, ctx) return { { id = "1", title = "my agent" } } end, -- optional: entries to pick from
  deliver = function(root, entry, prompt, opts, ctx) return "typed" end,    -- required: returns a status, or false, err; an optional third value is the handle for progress
  progress = function(handle) return "working" end, -- optional: see Progress
  configure = function(opts) end,               -- optional: built-in targets only, receives its options from setup
})
```

## Migration

The old `agent` option still works for now but is deprecated: `setup()` shows
a one-line notice when you pass it.

| old                   | new                      |
|-----------------------|--------------------------|
| `agent = "herdr"`     | `targets = { "herdr" }`  |
| `agent = "auto"`      | `targets = { "herdr" }`  |
| `agent = "headless"`  | the default, `setup({})` |

## API

All functions take the project `root` (a directory path).

```lua
local ap = require("agent-poke")

ap.setup({})                              -- configure; returns the config
ap.register_target({ name = "x", deliver = function(root, entry, prompt, opts) return "typed" end }) -- add a target
ap.poke(vim.fn.getcwd(), "run the tests") -- send a prompt
ap.pick(vim.fn.getcwd(), function() end)  -- choose the agent (herdr panes only when the herdr target is enabled, or the background agent); callback is optional
local _, id = ap.poke(vim.fn.getcwd(), "run the tests") -- the second value names the poke
ap.progress(id)                           -- "sent"|"queued"|"working"|"done"|"failed", err?
ap.status(vim.fn.getcwd())                -- state of the background run: nil, or { status = "working"|"done"|"failed"|"stopped", error? }
ap.lines(vim.fn.getcwd())                 -- readable output lines of the current/last background run
ap.output(vim.fn.getcwd())                -- toggle a window following the current/last background run
ap.chat(vim.fn.getcwd())                  -- open the background session interactively in a terminal
ap.stop(vim.fn.getcwd())                  -- stop the background run
```

- `poke(root, prompt, opts)`: delivers to the picked herdr pane (only when the herdr target is
  enabled), else the background agent. A poke while a run is in flight is queued and runs when it finishes.
  It returns, synchronously, `"started"` (a background run began), `"queued"`
  (a run is in flight), `"typed"` (typed into the herdr pane), `"forked"` (a
  throwaway fork of the herdr agent's session runs) or `false` (it failed, or a
  picker is still open). `opts` is optional:
  - `cwd`: the background agent runs, and later resumes, there instead of in `root`.
  - `dirs`: extra directories, each passed as the agent's add-dir flag
    (`--add-dir` for claude and codex, `--include-directories` for gemini).
  - `tools`: extra tool rules (e.g. `{ "Bash(beads-ask:*)" }`) added to claude's `--allowedTools` for this poke only,
    and for its run from the queue. Backends without per-tool allow lists (gemini, codex, opencode)
    ignore it, as does a poke through a herdr target.
  - `env`: a table merged into the background agent's environment (e.g. `PATH`).
  - `on_start`: `function()` called when a background run starts (later for a queued poke).
  - `pick`: `true` opens the picker even when an agent is remembered.
- `progress(id)`: the stage of a poke, `id` being the second value `poke` returns: `"sent"` (delivered to a
  target), `"queued"` (waits for a background run), `"working"`, `"done"` or `"failed"` (plus an error message as
  the second value). `nil` for an unknown id; the last 100 handles are kept. See [Progress](#progress).
- `status(root)`: `nil` before any background run, else (after `stop()`, `"stopped"` and `lines()` ends with `(stopped)`) `{ status = "working" | "done" | "failed" | "stopped", error? }`.
- `lines(root)`: the readable output lines of the current/last background run.
- `pick(root, on_pick)`: lets you choose between the agents running in herdr (when the herdr
  target is enabled) and the background agent; the choice is remembered for the root.
- `output(root)`: a second call closes the window. It refreshes while the run
  is in flight.
- `chat(root)`: resumes the stored session with the agent's own CLI; needs a
  session (poke first) and no run in flight.
- `stop(root)`: stops the run; notifies when there is none.
- `config`: the current configuration table.

## Progress

Every poke gets an id (the second return value of `poke`). `progress(id)` returns its stage:

| stage       | meaning |
|-------------|---------|
| `"sent"`    | delivered to a target; stays so unless the target reports more |
| `"queued"`  | waits for the running background run |
| `"working"` | a background run is in progress |
| `"done"`    | finished |
| `"failed"`  | failed, dropped from the queue or stopped; `progress` also returns the error |

Background runs report every stage. A target may report the stage of a delivered prompt through an optional
`progress(handle)` returning a stage (and an error for `"failed"`); `handle` is the third value its `deliver`
returned (else the poke id). It is called only when `progress(id)` is, never in the background, and a throwing
or `nil` result leaves the stage as it was. A herdr fork follows its background run; a prompt typed into a pane
stays `"sent"`.

Each stage change fires a `User` autocmd, `AgentPokeProgress`, with `data = { id, root, stage, target }`
(`target` is `"background"` for the background agent):

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "AgentPokeProgress",
  callback = function(ev) print(ev.data.id, ev.data.stage) end,
})
```

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
