-- agent-poke_nvim-ei4.2: roots are normalized before hashing (trailing slash removed,
-- resolved with fs_realpath when the path exists), so /a/b, /a/b/ and a symlink to
-- /a/b share one state file.
local function fresh()
  package.loaded["agent-poke.state"] = nil
  return require("agent-poke.state")
end

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return assert(vim.uv.fs_realpath(d))
end

describe("agent-poke.state root normalization", function()
  local old_state_home

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
  end)

  after_each(function()
    vim.env.XDG_STATE_HOME = old_state_home
  end)

  it("a root with a trailing slash shares state with the same root without it", function()
    local state = fresh()
    local root = new_root()
    state.set(root .. "/", "target", { title = "slash" })
    assert.are.same({ title = "slash" }, state.get(root).target)
  end)

  it("a root without a trailing slash shares state with the same root with it", function()
    local state = fresh()
    local root = new_root()
    state.set(root, "target", { title = "plain" })
    assert.are.same({ title = "plain" }, state.get(root .. "/").target)
  end)

  it("a symlink to a root shares state with the real path", function()
    local state = fresh()
    local root = new_root()
    local link = vim.fn.tempname()
    assert(vim.uv.fs_symlink(root, link))
    state.set(link, "target", { title = "via-link" })
    assert.are.same({ title = "via-link" }, state.get(root).target)
    state.set(root, "session", { id = "s1", agent = "claude" })
    assert.are.same({ id = "s1", agent = "claude" }, state.get(link .. "/").session)
    os.remove(link)
  end)

  -- assumption: a root that does not exist (fs_realpath fails) is still trailing-slash trimmed.
  it("a non-existent root with and without a trailing slash shares state", function()
    local state = fresh()
    local root = vim.fn.tempname() .. "/does/not/exist"
    state.set(root .. "/", "target", { title = "missing" })
    assert.are.same({ title = "missing" }, state.get(root).target)
  end)

  it("different roots still get separate state (passes already: roots are not merged)", function()
    local state = fresh()
    local a, b = new_root(), new_root()
    state.set(a, "target", { title = "a" })
    assert.is_nil(state.get(b).target)
  end)
end)
