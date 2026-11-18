-- agent-poke_nvim-wtd.2: per-root state with lock, atomic writes and legacy import.
--
-- Interface (lua/agent-poke/state.lua):
--   state.get(root)             -> table of everything stored for root ({} when nothing)
--   state.set(root, key, value) -- locked read-modify-write of one key
-- Keys used by the plugin: `target` (the picked agent, e.g. { title, pane_id })
-- and `session` (the background session: { id = <session id>, agent = <name> }).
local REPO = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function fresh()
  package.loaded["agent-poke.state"] = nil
  return require("agent-poke.state")
end

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.fn.fnamemodify(d, ":p"):gsub("/$", "")
end

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---The state files under stdpath("state")/agent-poke/, lock files left out.
local function state_files()
  local out = {}
  for _, p in ipairs(vim.fn.glob(vim.fn.stdpath("state") .. "/agent-poke/*", true, true)) do
    if vim.fn.isdirectory(p) == 0 and not p:find("lock", 1, true) and not p:find("%.tmp") then
      out[#out + 1] = p
    end
  end
  return out
end

describe("agent-poke.state", function()
local old_state_home

before_each(function()
  old_state_home = vim.env.XDG_STATE_HOME
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
end)

after_each(function()
  vim.env.XDG_STATE_HOME = old_state_home
end)

describe("agent-poke.state get/set", function()
  it("gives an empty table for a root with no state (and no state dir yet)", function()
    local state = fresh()
    assert.are.same(0, vim.fn.isdirectory(vim.fn.stdpath("state") .. "/agent-poke"))
    assert.are.same({}, state.get(new_root()))
  end)

  it("round-trips target and session for a root", function()
    local state = fresh()
    local root = new_root()
    state.set(root, "target", { title = "code-review-tool", pane_id = "w6W:p3" })
    state.set(root, "session", { id = "abc-123", agent = "claude" })
    local got = state.get(root)
    assert.are.same({ title = "code-review-tool", pane_id = "w6W:p3" }, got.target)
    assert.are.same({ id = "abc-123", agent = "claude" }, got.session)
  end)

  it("persists across module reloads (read from disk)", function()
    local root = new_root()
    fresh().set(root, "session", { id = "persisted", agent = "codex" })
    assert.are.same({ id = "persisted", agent = "codex" }, fresh().get(root).session)
  end)

  it("stores the file under stdpath('state')/agent-poke/", function()
    local state = fresh()
    state.set(new_root(), "target", { title = "x" })
    assert.are.same(1, #state_files())
  end)

  it("keeps two roots independent", function()
    local state = fresh()
    local a, b = new_root(), new_root()
    state.set(a, "target", { title = "A" })
    assert.are.same({}, state.get(b))
    state.set(b, "target", { title = "B" })
    state.set(a, "session", { id = "sa", agent = "claude" })
    assert.are.same({ title = "A" }, state.get(a).target)
    assert.are.same({ title = "B" }, state.get(b).target)
    assert.is_nil(state.get(b).session)
    assert.are.same(2, #state_files())
  end)

  it("a later set of the same key replaces the value; nil clears it", function()
    local state = fresh()
    local root = new_root()
    state.set(root, "target", { title = "one" })
    state.set(root, "target", { title = "two" })
    assert.are.same({ title = "two" }, state.get(root).target)
    state.set(root, "target", nil)
    assert.is_nil(state.get(root).target)
  end)
end)

describe("agent-poke.state concurrent writers", function()
  local N = 150

  local function writer_script(dir)
    local path = dir .. "/writer.lua"
    write(
      path,
      table.concat({
        "package.path = " .. string.format("%q", REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;") .. " .. package.path",
        "local state = require('agent-poke.state')",
        "local root, key, tag, n = _G.arg[1], _G.arg[2], _G.arg[3], tonumber(_G.arg[4])",
        "for i = 1, n do",
        "  state.set(root, key, { tag = tag, i = i })",
        "end",
      }, "\n")
    )
    return path
  end

  local function run_two(root, key_a, key_b)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local script = writer_script(dir)
    local env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME }
    local function spawn(key, tag)
      return vim.system(
        { vim.v.progpath, "--headless", "--clean", "-i", "NONE", "-l", script, root, key, tag, tostring(N) },
        { env = env, text = true }
      )
    end
    local pa = spawn(key_a, "A")
    local pb = spawn(key_b, "B")
    local ra = pa:wait(120000)
    local rb = pb:wait(120000)
    assert.are.same(0, ra.code, "writer A failed: " .. tostring(ra.stderr))
    assert.are.same(0, rb.code, "writer B failed: " .. tostring(rb.stderr))
  end

  it("two nvim processes writing the same key leave a valid file; the last write wins", function()
    local root = new_root()
    run_two(root, "target", "target")
    local files = state_files()
    assert.are.same(1, #files)
    local f = assert(io.open(files[1], "rb"))
    local text = f:read("a")
    f:close()
    local ok, data = pcall(vim.json.decode, text)
    assert.is_true(ok, "state file is not valid JSON: " .. text)
    assert.are.same("table", type(data))
    local got = fresh().get(root).target
    assert.is_table(got)
    assert.are.same(N, got.i) -- one of the two writers' last writes
    assert.is_truthy(got.tag == "A" or got.tag == "B")
  end)

  it("two nvim processes writing different keys lose neither (set is locked)", function()
    local root = new_root()
    run_two(root, "target", "session")
    local got = fresh().get(root)
    assert.are.same({ tag = "A", i = N }, got.target)
    assert.are.same({ tag = "B", i = N }, got.session)
  end)
end)

describe("agent-poke.state legacy import", function()
  local function legacy(root, text)
    write(root .. "/.code-review/headless.json", text)
  end

  it("imports <root>/.code-review/headless.json's session id on first read", function()
    local state = fresh()
    local root = new_root()
    legacy(root, '{"session_id":"legacy-1","agent":"codex"}\n')
    assert.are.same({ id = "legacy-1", agent = "codex" }, state.get(root).session)
  end)

  it("a legacy file without agent means claude", function()
    local state = fresh()
    local root = new_root()
    legacy(root, '{"session_id":"legacy-0"}')
    assert.are.same({ id = "legacy-0", agent = "claude" }, state.get(root).session)
  end)

  it("imports once, then reads from the new location", function()
    local root = new_root()
    legacy(root, '{"session_id":"legacy-1","agent":"claude"}')
    assert.are.same("legacy-1", fresh().get(root).session.id)
    assert.are.same(1, #state_files()) -- written to the new location
    legacy(root, '{"session_id":"legacy-2","agent":"claude"}')
    assert.are.same("legacy-1", fresh().get(root).session.id)
    os.remove(root .. "/.code-review/headless.json")
    assert.are.same("legacy-1", fresh().get(root).session.id)
  end)

  it("a session set after the import is not overridden by the legacy file", function()
    local state = fresh()
    local root = new_root()
    legacy(root, '{"session_id":"legacy-1","agent":"claude"}')
    state.get(root)
    state.set(root, "session", { id = "new-1", agent = "claude" })
    assert.are.same("new-1", fresh().get(root).session.id)
  end)

  it("a corrupt legacy file is treated as empty", function()
    local state = fresh()
    local root = new_root()
    legacy(root, "{not json")
    local ok, got = pcall(state.get, root)
    assert.is_true(ok, tostring(got))
    assert.are.same({}, got)
  end)
end)

describe("agent-poke.state corrupt state file", function()
  for name, text in pairs({ garbage = "{\0garbage", empty = "", array = "[1,2]", string = '"x"' }) do
    it("treats a " .. name .. " state file as empty, and set still works", function()
      local state = fresh()
      local root = new_root()
      state.set(root, "target", { title = "before" })
      local files = state_files()
      assert.are.same(1, #files)
      write(files[1], text)
      local ok, got = pcall(state.get, root)
      assert.is_true(ok, tostring(got))
      assert.are.same({}, got)
      local ok2, err = pcall(state.set, root, "target", { title = "after" })
      assert.is_true(ok2, tostring(err))
      assert.are.same({ title = "after" }, fresh().get(root).target)
    end)
  end
end)
end)
