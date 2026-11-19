-- agent-poke_nvim-7vr: creating the state dir must tolerate another process
-- creating it (or a parent) at the same time.
--
-- Neovim's mkdir(path, "p") raises E739 "file already exists" when a path
-- component appears between its existence check and its own mkdir. Two editors
-- writing state for the first time on a fresh state home hit this (seen as the
-- flaky "two nvim processes writing different keys" test in state_spec.lua).
-- The double below reproduces that interleaving deterministically: the
-- directory gets created (by the "other process"), then mkdir raises E739.

local function fresh()
  package.loaded["agent-poke.state"] = nil
  return require("agent-poke.state")
end

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.fn.fnamemodify(d, ":p"):gsub("/$", ""))
end

describe("agent-poke.state state dir created concurrently", function()
  local old_state_home, real_mkdir, state_home

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    state_home = vim.fn.tempname()
    vim.env.XDG_STATE_HOME = state_home
    real_mkdir = vim.fn.mkdir
    -- Another process wins the race: the dir exists afterwards, but our mkdir
    -- reports E739 exactly like Neovim does. Calls outside the state home pass through.
    vim.fn.mkdir = function(path, ...)
      if type(path) == "string" and path:sub(1, #state_home) == state_home then
        real_mkdir(path, "p")
        error("Vim:E739: Cannot create directory " .. state_home .. ": file already exists", 0)
      end
      return real_mkdir(path, ...)
    end
  end)

  after_each(function()
    vim.fn.mkdir = real_mkdir
    vim.env.XDG_STATE_HOME = old_state_home
  end)

  it("set() succeeds and persists when the state dir appears concurrently", function()
    local state = fresh()
    local root = new_root()
    local ok, err = pcall(state.set, root, "target", { title = "one" })
    vim.fn.mkdir = real_mkdir
    assert.is_true(ok, "set raised: " .. tostring(err))
    assert.are.same({ title = "one" }, fresh().get(root).target)
  end)

  it("get() imports the legacy session when the state dir appears concurrently", function()
    local root = new_root()
    real_mkdir(root .. "/.code-review", "p")
    local f = assert(io.open(root .. "/.code-review/headless.json", "wb"))
    f:write('{"session_id":"legacy-1","agent":"codex"}')
    f:close()
    local state = fresh()
    local ok, got = pcall(state.get, root)
    vim.fn.mkdir = real_mkdir
    assert.is_true(ok, "get raised: " .. tostring(got))
    assert.are.same({ id = "legacy-1", agent = "codex" }, got.session)
    -- imported to the new location
    os.remove(root .. "/.code-review/headless.json")
    assert.are.same({ id = "legacy-1", agent = "codex" }, fresh().get(root).session)
  end)
end)
