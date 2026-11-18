-- agent-poke_nvim-ei4.2: a process releases the state lock only if it still owns it.
--
-- Holder A (a child `nvim -l`) takes the lock in state.set and pauses inside its
-- critical section. The test ages A's lock past the stale limit, so holder B (a
-- second child) breaks it and takes the lock, then pauses inside its own critical
-- section. A is then let go; its release must leave B's lock in place.
--
-- Both children pause at the state-file rename (vim.uv.fs_rename to a *.json path),
-- coordinated through marker files. Every wait is bounded and children still running
-- at the end are killed.
-- assumption: a lock is stale by age (older than the stale limit, as now), not by
-- checking whether the holder process is still alive.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local WAIT_MS = 10000
local CHILD_WAIT_MS = 15000
local STALE_AGE_SECS = 3600

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

---Child: patch fs_rename before loading state so the pause works even if the module
---captures it. On the first rename to a *.json path write <role>_holding, then wait
---(bounded) for <role>_go. Exits 4 when the go signal never comes.
local CHILD = [[
local repo, root, marks, role, key = _G.arg[1], _G.arg[2], _G.arg[3], _G.arg[4], _G.arg[5]
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
local uv = vim.uv or vim.loop
local orig = uv.fs_rename
local paused = false
local function pause(dest)
  if paused or type(dest) ~= "string" or not dest:match("%%.json$") then
    return
  end
  paused = true
  local f = assert(io.open(marks .. "/" .. role .. "_holding", "wb"))
  f:write("1")
  f:close()
  local deadline = uv.hrtime() + %d * 1e6
  while not uv.fs_stat(marks .. "/" .. role .. "_go") do
    if uv.hrtime() > deadline then
      io.stderr:write(role .. ": go signal never came\n")
      os.exit(4)
    end
    uv.sleep(10)
  end
end
uv.fs_rename = function(src, dest, ...)
  pause(dest)
  return orig(src, dest, ...)
end
local orig_os_rename = os.rename
os.rename = function(src, dest)
  pause(dest)
  return orig_os_rename(src, dest)
end
local state = require("agent-poke.state")
local ok, err = pcall(state.set, root, key, { by = role })
if not ok then
  io.stderr:write(role .. ": state.set raised: " .. tostring(err) .. "\n")
  os.exit(2)
end
os.exit(0)
]]

describe("agent-poke.state lock ownership", function()
  it("an old holder whose stale lock was broken and retaken does not remove the new holder's lock", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    tmp = assert(vim.uv.fs_realpath(tmp))
    local state_home = tmp .. "/state"
    local root = tmp .. "/root"
    local marks = tmp .. "/marks"
    local state_dir = state_home .. "/nvim/agent-poke" -- stdpath("state") = $XDG_STATE_HOME/$NVIM_APPNAME
    vim.fn.mkdir(state_dir, "p")
    vim.fn.mkdir(root, "p")
    vim.fn.mkdir(marks, "p")
    local state_file = state_dir .. "/" .. vim.fn.sha256((assert(vim.uv.fs_realpath(root)))) .. ".json"
    local lock = state_file .. ".lock"
    local script = tmp .. "/child.lua"
    write(script, CHILD:format(CHILD_WAIT_MS))

    local env = { XDG_STATE_HOME = state_home, NVIM_APPNAME = "nvim" }
    local function spawn(role, key)
      return vim.system(
        { vim.v.progpath, "--headless", "--clean", "-i", "NONE", "-l", script, REPO, root, marks, role, key },
        { env = env, text = true }
      )
    end

    local procs = {}
    local results = {}
    local function finish(role)
      if results[role] == nil and procs[role] then
        results[role] = procs[role]:wait(WAIT_MS)
      end
      return results[role]
    end
    local function describe_child(role)
      local r = results[role]
      if not r then
        return role .. ": still running"
      end
      return ("%s: code=%s signal=%s stderr=%s"):format(role, tostring(r.code), tostring(r.signal), tostring(r.stderr))
    end

    local ok, err = pcall(function()
      procs.a = spawn("a", "from_a")
      local a_in = vim.wait(WAIT_MS, function()
        return exists(marks .. "/a_holding")
      end, 10)
      assert.is_true(a_in, "holder A never reached its critical section; " .. describe_child("a"))
      assert.is_true(exists(lock), "holder A is in its critical section but no lock exists at " .. lock)

      -- Make A's lock stale (the dir and anything inside it).
      local old = os.time() - STALE_AGE_SECS
      if vim.fn.isdirectory(lock) == 1 then
        for name in vim.fs.dir(lock) do
          vim.uv.fs_utime(lock .. "/" .. name, old, old)
        end
      end
      assert(vim.uv.fs_utime(lock, old, old))

      procs.b = spawn("b", "from_b")
      local b_in = vim.wait(WAIT_MS, function()
        return exists(marks .. "/b_holding") or procs.b:is_closing()
      end, 10)
      if not exists(marks .. "/b_holding") then
        finish("b")
      end
      assert.is_true(
        exists(marks .. "/b_holding") and b_in,
        "holder B never broke the stale lock and reached its critical section; " .. describe_child("b")
      )

      -- Let A finish while B still holds the lock.
      write(marks .. "/a_go", "1")
      local ra = finish("a")
      assert.are.same(0, ra.code, "holder A failed; " .. describe_child("a"))

      assert.is_true(exists(lock), "holder A's release removed the lock now held by holder B (" .. lock .. ")")

      write(marks .. "/b_go", "1")
      local rb = finish("b")
      assert.are.same(0, rb.code, "holder B failed; " .. describe_child("b"))
      assert.is_false(exists(lock), "holder B did not release its own lock")

      local f = assert(io.open(state_file, "rb"))
      local data = vim.json.decode(f:read("a"))
      f:close()
      assert.are.same({ by = "b" }, data.from_b)
    end)

    -- Cleanup: release both children, wait (bounded), kill any still running.
    write(marks .. "/a_go", "1")
    write(marks .. "/b_go", "1")
    for _, role in ipairs({ "a", "b" }) do
      local p = procs[role]
      if p and results[role] == nil then
        local r = p:wait(WAIT_MS)
        if r.code == 124 or r.signal ~= 0 then
          pcall(p.kill, p, 9)
          pcall(p.wait, p, 2000)
        end
      end
    end
    vim.fn.delete(tmp, "rf")

    if not ok then
      error(err, 0)
    end
  end)
end)
