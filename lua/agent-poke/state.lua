---Per-project-root state (picked target, background session) stored under
---stdpath("state")/agent-poke/, one JSON file per root, written atomically
---under a lock. Corrupt or missing files read as empty.
local M = {}

local uv = vim.uv or vim.loop

local LOCK_STALE_SECS = 10
local LOCK_TIMEOUT_MS = 30000

local function dir()
  return vim.fn.stdpath("state") .. "/agent-poke"
end

---Trim trailing slashes and resolve symlinks (when the path exists) so equivalent
---spellings of a root share one state file.
local function normalize(root)
  local r = root
  if #r > 1 then
    r = r:gsub("/+$", "")
    if r == "" then
      r = "/"
    end
  end
  return uv.fs_realpath(r) or r
end

local function path_for(root)
  root = normalize(root)
  return dir() .. "/" .. vim.fn.sha256(root) .. ".json"
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("a")
  f:close()
  return text
end

local function decode_object(text)
  if not text then
    return nil
  end
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    return nil
  end
  if next(data) ~= nil and vim.islist(data) then
    return nil
  end
  return data
end

local function write_atomic(path, data)
  local text = next(data) == nil and "{}" or vim.json.encode(data)
  local tmp = string.format("%s.%d.%d.tmp", path, uv.os_getpid(), uv.hrtime())
  local f, oerr = io.open(tmp, "wb")
  if not f then
    error(oerr)
  end
  local wok, werr = f:write(text)
  local cok, cerr = f:close()
  if not (wok and cok) then
    os.remove(tmp)
    error(tostring(werr or cerr))
  end
  local ok, err = uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    error(err)
  end
end

---Legacy code-review.nvim session id: <root>/.code-review/headless.json.
local function legacy_state(root)
  root = normalize(root)
  local d = decode_object(read_file(root .. "/.code-review/headless.json"))
  if d and type(d.session_id) == "string" and d.session_id ~= "" then
    local agent = type(d.agent) == "string" and d.agent ~= "" and d.agent or "claude"
    return { session = { id = d.session_id, agent = agent } }
  end
  return nil
end

---Run fn while holding the root's lock (mkdir is atomic).
local token_seq = 0

---Remove the lock dir only if it still holds our owner token. The dir is first
---renamed aside (atomic) so a concurrent new holder's lock is never half-deleted.
local function release(lock, token)
  if read_file(lock .. "/owner") ~= token then
    return
  end
  local aside = string.format("%s.rel.%d.%d", lock, uv.os_getpid(), uv.hrtime())
  if uv.fs_rename(lock, aside) then
    vim.fn.delete(aside, "rf")
  end
end

local function with_lock(path, fn)
  local lock = path .. ".lock"
  token_seq = token_seq + 1
  local token = string.format("%d:%d:%d", uv.os_getpid(), uv.hrtime(), token_seq)
  local deadline = uv.hrtime() + LOCK_TIMEOUT_MS * 1e6
  while true do
    local made, merr, ename = uv.fs_mkdir(lock, 448)
    if made then
      break
    end
    if ename ~= "EEXIST" then
      error("agent-poke: cannot create state lock " .. lock .. ": " .. tostring(merr), 0)
    end
    if uv.hrtime() > deadline then
      error("agent-poke: timed out waiting for state lock " .. lock, 0)
    end
    local st = uv.fs_stat(lock)
    if st and os.time() - st.mtime.sec > LOCK_STALE_SECS then
      local aside = string.format("%s.stale.%d.%d", lock, uv.os_getpid(), uv.hrtime())
      local removed, rerr, rname = uv.fs_rename(lock, aside)
      if removed then
        vim.fn.delete(aside, "rf")
      elseif rname ~= "ENOENT" then
        error("agent-poke: cannot remove stale state lock " .. lock .. ": " .. tostring(rerr), 0)
      end
    elseif st then
      uv.sleep(2)
    end
    -- lock vanished between mkdir and stat: retry at once (deadline checked above)
  end
  local ofile = io.open(lock .. "/owner", "wb")
  local wrote = false
  if ofile then
    local wok = ofile:write(token)
    local cok = ofile:close()
    wrote = (wok and cok) and true or false
  end
  if not wrote then
    vim.fn.delete(lock, "rf")
    error("agent-poke: cannot write state lock owner token in " .. lock, 0)
  end
  local ok, err = pcall(fn)
  release(lock, token)
  if not ok then
    error(err, 0)
  end
end

---mkdir -p that tolerates a concurrent creator (E739 when the path already is a directory).
local function ensure_dir()
  local d = dir()
  local ok, err = pcall(vim.fn.mkdir, d, "p")
  if not ok and vim.fn.isdirectory(d) ~= 1 then
    error(err, 0)
  end
end

---Everything stored for root; {} when nothing. Imports the legacy session on first read.
---@param root string
---@return table
function M.get(root)
  local path = path_for(root)
  local text = read_file(path)
  if text then
    return decode_object(text) or {}
  end
  local legacy = legacy_state(root)
  if not legacy then
    return {}
  end
  ensure_dir()
  local result = legacy
  with_lock(path, function()
    local again = read_file(path)
    if again then
      result = decode_object(again) or {}
    else
      write_atomic(path, legacy)
    end
  end)
  return result
end

---Locked read-modify-write of one key; nil clears it.
---@param root string
---@param key string
---@param value any
function M.set(root, key, value)
  local path = path_for(root)
  ensure_dir()
  with_lock(path, function()
    local text = read_file(path)
    local data
    if text then
      data = decode_object(text) or {}
    else
      data = legacy_state(root) or {}
    end
    data[key] = value
    write_atomic(path, data)
  end)
end

return M
