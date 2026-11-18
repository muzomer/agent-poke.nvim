-- agent-poke_nvim-ei4.2 finding (state.lua:126): when the lock's owner token cannot be
-- written (io.open fails, or the write fails and leaves the owner file empty), the
-- lock must not leak. After state.set returns or raises, the lock dir is gone and the
-- next state.set does not wait for the stale limit.
--
-- Each case runs in a child `nvim -l` with io.open stubbed for the lock's owner file
-- only. The child is bounded by a timeout and killed if it is still running.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local CHILD_TIMEOUT_MS = 20000
local FAST_MS = 3000

-- mode "open_nil": io.open returns nil for <lock>/owner opened for writing.
-- mode "write_fail": io.open succeeds but write returns nil, ENOSPC (file left empty).
local CHILD = [[
local repo, root, mode = _G.arg[1], _G.arg[2], _G.arg[3]
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
local uv = vim.uv or vim.loop
local real_open = io.open
local function is_owner(path, m)
  return type(path) == "string" and path:match("%.lock/owner$") and type(m) == "string" and m:find("[wa]")
end
io.open = function(path, m, ...)
  if is_owner(path, m) then
    if mode == "open_nil" then
      return nil, path .. ": No space left on device", 28
    end
    local f, err, code = real_open(path, m, ...)
    if not f then
      return f, err, code
    end
    return setmetatable({}, {
      __index = function(_, k)
        if k == "write" then
          return function()
            return nil, "No space left on device", 28
          end
        end
        local v = f[k]
        if type(v) == "function" then
          return function(_, ...)
            return v(f, ...)
          end
        end
        return v
      end,
    })
  end
  return real_open(path, m, ...)
end
local state = require("agent-poke.state")
local lock = vim.fn.stdpath("state") .. "/agent-poke/" .. vim.fn.sha256(assert(uv.fs_realpath(root))) .. ".json.lock"
local first_ok, first_err = pcall(state.set, root, "k", 1)
local leaked = uv.fs_stat(lock) ~= nil
local out = { first_ok = first_ok, first_err = first_ok and nil or tostring(first_err), leaked = leaked, lock = lock }
if not leaked then
  io.open = real_open
  local t0 = uv.hrtime()
  local ok2, err2 = pcall(state.set, root, "k", 2)
  out.second_ok = ok2
  out.second_err = ok2 and nil or tostring(err2)
  out.second_ms = (uv.hrtime() - t0) / 1e6
  out.leaked_after_second = uv.fs_stat(lock) ~= nil
end
io.stdout:write(vim.json.encode(out))
os.exit(0)
]]

local function run_child(mode)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  tmp = assert(vim.uv.fs_realpath(tmp))
  local root = tmp .. "/root"
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(tmp .. "/state/nvim/agent-poke", "p")
  local script = tmp .. "/child.lua"
  local f = assert(io.open(script, "wb"))
  f:write(CHILD)
  f:close()
  local proc = vim.system(
    { vim.v.progpath, "--headless", "--clean", "-i", "NONE", "-l", script, REPO, root, mode },
    { env = { XDG_STATE_HOME = tmp .. "/state", NVIM_APPNAME = "nvim" }, text = true }
  )
  local r = proc:wait(CHILD_TIMEOUT_MS)
  if r.code == 124 or (r.signal and r.signal ~= 0) then
    pcall(proc.kill, proc, 9)
    pcall(proc.wait, proc, 2000)
  end
  vim.fn.delete(tmp, "rf")
  assert.are.same(0, r.code, ("child failed: code=%s signal=%s stderr=%s"):format(r.code, r.signal, r.stderr))
  local ok, out = pcall(vim.json.decode, r.stdout or "")
  assert.is_true(ok and type(out) == "table", "child printed no result: " .. tostring(r.stdout) .. " " .. tostring(r.stderr))
  return out
end

local function check(out)
  assert.is_false(
    out.leaked,
    "lock left behind after state.set when the owner token could not be written (" .. tostring(out.lock) .. ")"
  )
  assert.is_true(out.second_ok, "next state.set failed: " .. tostring(out.second_err))
  assert.is_true(out.second_ms < FAST_MS, ("next state.set waited %d ms for the lock"):format(out.second_ms))
  assert.is_false(out.leaked_after_second, "next state.set left its lock behind")
end

describe("agent-poke.state lock when the owner token cannot be written", function()
  it("does not leak the lock when opening the owner file fails", function()
    check(run_child("open_nil"))
  end)

  it("does not leak the lock when writing the owner token fails and leaves the file empty", function()
    check(run_child("write_fail"))
  end)
end)
