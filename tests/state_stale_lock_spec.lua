-- agent-poke_nvim-wtd.2 finding (round 2): a stale lock dir (older than the stale
-- limit) that cannot be removed must make the lock loop give up with an error, not
-- spin forever retrying fs_rmdir.
--
-- Each case runs in a child `nvim -l` killed after a short timeout, so a hanging
-- lock loop fails the test instead of hanging the suite.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local TIMEOUT_MS = 10000
local STALE_AGE_SECS = 3600

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---Run `body` (Lua using `state` and `root`) in a child nvim whose state dir holds a
---stale, unremovable lock for `root`. `opts.blocker`: "file" puts a file inside the
---lock dir (rmdir fails ENOTEMPTY); "readonly" makes stdpath("state")/agent-poke/
---read-only (rmdir fails EACCES). The child prints "ERRORED: <msg>" and exits 0 when
---the call raises, exits 3 when it returns normally.
local function run_with_stale_lock(body, opts)
  local tmp = vim.fn.tempname()
  local state_home = tmp .. "/state"
  local root = tmp .. "/root"
  local state_dir = state_home .. "/nvim/agent-poke" -- stdpath("state") = $XDG_STATE_HOME/$NVIM_APPNAME
  vim.fn.mkdir(state_dir, "p")
  vim.fn.mkdir(root, "p")
  if opts.setup_root then
    opts.setup_root(root)
  end
  local lock = state_dir .. "/" .. vim.fn.sha256(root) .. ".json.lock"
  vim.fn.mkdir(lock, "p")
  if opts.blocker == "file" then
    write(lock .. "/owner", "12345")
  end
  local old = os.time() - STALE_AGE_SECS
  assert(vim.uv.fs_utime(lock, old, old))
  if opts.blocker == "readonly" then
    assert(vim.uv.fs_chmod(state_dir, tonumber("555", 8)))
  end
  local script = tmp .. "/child.lua"
  write(
    script,
    table.concat({
      "package.path = " .. string.format("%q", REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;") .. " .. package.path",
      "local state = require('agent-poke.state')",
      "local root = _G.arg[1]",
      "local ok, err = pcall(function() " .. body .. " end)",
      "if ok then io.stdout:write('RETURNED\\n') os.exit(3) end",
      "io.stdout:write('ERRORED: ' .. tostring(err) .. '\\n')",
      "os.exit(0)",
    }, "\n")
  )
  local t0 = vim.uv.hrtime()
  local res = vim.system(
    { vim.v.progpath, "--headless", "--clean", "-i", "NONE", "-l", script, root },
    { env = { XDG_STATE_HOME = state_home, NVIM_APPNAME = "nvim" }, text = true }
  ):wait(TIMEOUT_MS)
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  vim.uv.fs_chmod(state_dir, tonumber("755", 8))
  vim.fn.delete(tmp, "rf")
  return res, elapsed_ms
end

local function assert_prompt(res, elapsed, what)
  assert.is_true(
    elapsed < TIMEOUT_MS and res.code ~= 124 and res.signal == 0,
    ("%s did not return within %dms (stale-lock loop hangs); code=%s signal=%s stdout=%s stderr=%s"):format(
      what,
      TIMEOUT_MS,
      tostring(res.code),
      tostring(res.signal),
      tostring(res.stdout),
      tostring(res.stderr)
    )
  )
end

local function assert_raised(res, what)
  assert.are.same(0, res.code, what .. " child failed: stdout=" .. tostring(res.stdout) .. " stderr=" .. tostring(res.stderr))
  assert.is_truthy(tostring(res.stdout):find("ERRORED:", 1, true), what .. " did not raise: " .. tostring(res.stdout))
end

describe("agent-poke.state stale lock that cannot be removed", function()
  it("set() returns or errors promptly when the stale lock dir is not empty (ENOTEMPTY)", function()
    -- An implementation may clear its own owner file and take the lock, or raise;
    -- it must not spin retrying fs_rmdir.
    local res, elapsed = run_with_stale_lock("state.set(root, 'target', { title = 'x' })", { blocker = "file" })
    assert_prompt(res, elapsed, "state.set")
    assert.is_truthy(
      res.code == 0 or res.code == 3,
      "child failed: code=" .. tostring(res.code) .. " stdout=" .. tostring(res.stdout) .. " stderr=" .. tostring(res.stderr)
    )
  end)

  it("set() errors promptly when the state dir is read-only (stale lock rmdir EACCES)", function()
    local res, elapsed = run_with_stale_lock("state.set(root, 'target', { title = 'x' })", { blocker = "readonly" })
    assert_prompt(res, elapsed, "state.set")
    assert_raised(res, "state.set")
  end)

  it("get() with a legacy session to import returns or errors promptly behind an unremovable stale lock", function()
    local res, elapsed = run_with_stale_lock("state.get(root)", {
      blocker = "file",
      setup_root = function(root)
        write(root .. "/.code-review/headless.json", vim.json.encode({ session_id = "legacy-1", agent = "claude" }))
      end,
    })
    assert_prompt(res, elapsed, "state.get")
    -- Either raising or returning (e.g. the legacy session, unimported) is fine; spinning is not.
    assert.is_truthy(
      res.code == 0 or res.code == 3,
      "child failed: code=" .. tostring(res.code) .. " stdout=" .. tostring(res.stdout) .. " stderr=" .. tostring(res.stderr)
    )
  end)
end)
