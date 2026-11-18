-- agent-poke_nvim-wtd.2 finding: the state lock loop must fail fast on errors that
-- retrying cannot fix (e.g. EACCES on a read-only state dir) instead of spinning.
--
-- Each case runs in a child `nvim -l` killed after a short timeout, so a hanging
-- lock loop fails the test instead of hanging the suite.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local TIMEOUT_MS = 10000

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---Run `body` (Lua using `state` and `root`) in a child nvim with a read-only
---stdpath("state")/agent-poke/. The child prints "ERRORED: <msg>" and exits 0 when
---the call raises, exits 3 when it returns normally.
local function run_readonly(body, setup_root)
  local tmp = vim.fn.tempname()
  local state_home = tmp .. "/state"
  local root = tmp .. "/root"
  local state_dir = state_home .. "/nvim/agent-poke" -- stdpath("state") = $XDG_STATE_HOME/$NVIM_APPNAME
  vim.fn.mkdir(state_dir, "p")
  vim.fn.mkdir(root, "p")
  if setup_root then
    setup_root(root)
  end
  assert(vim.uv.fs_chmod(state_dir, tonumber("555", 8)))
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

describe("agent-poke.state lock on an unwritable state dir", function()
  it("set() errors promptly instead of spinning when the lock dir cannot be created (EACCES)", function()
    local res, elapsed = run_readonly("state.set(root, 'target', { title = 'x' })")
    assert.is_true(
      elapsed < TIMEOUT_MS,
      ("state.set did not return within %dms (lock loop hangs); stdout=%s stderr=%s"):format(
        TIMEOUT_MS,
        tostring(res.stdout),
        tostring(res.stderr)
      )
    )
    assert.are.same(0, res.code, "child failed: stdout=" .. tostring(res.stdout) .. " stderr=" .. tostring(res.stderr))
    assert.is_truthy(tostring(res.stdout):find("ERRORED:", 1, true), "state.set did not raise: " .. tostring(res.stdout))
  end)

  it("get() with a legacy session to import returns or errors promptly instead of spinning (EACCES)", function()
    local res, elapsed = run_readonly("state.get(root)", function(root)
      write(root .. "/.code-review/headless.json", vim.json.encode({ session_id = "legacy-1", agent = "claude" }))
    end)
    assert.is_true(
      elapsed < TIMEOUT_MS,
      ("state.get did not return within %dms (lock loop hangs); stdout=%s stderr=%s"):format(
        TIMEOUT_MS,
        tostring(res.stdout),
        tostring(res.stderr)
      )
    )
    -- Either raising or returning (e.g. the legacy session, unimported) is fine; spinning is not.
    assert.is_truthy(
      res.code == 0 or res.code == 3,
      "child failed: code=" .. tostring(res.code) .. " stdout=" .. tostring(res.stdout) .. " stderr=" .. tostring(res.stderr)
    )
  end)
end)
