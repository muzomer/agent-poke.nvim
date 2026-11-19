-- Test helpers: fake `claude` and `herdr` executables on PATH.
local M = {}

local PRELUDE = [[#!/bin/sh
# fake %s: record argv (one per record), cwd and stdin, then run the body
log="%s"
name="%s"
n=$(cat "$log/$name.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$log/$name.n"
d="$log/$name.$n"; mkdir -p "$d"
: > "$d/argv.tmp"
for a in "$@"; do printf '%%s\0' "$a" >> "$d/argv.tmp"; done
mv "$d/argv.tmp" "$d/argv"
pwd -P > "$d/cwd"
%s
]]

local ENV_RECORD = [[
printf '%s' "${AP_TEST_VAR-<unset>}" > "$d/ap_test_var"
printf '%s' "${XDG_STATE_HOME-<unset>}" > "$d/xdg_state_home"
printf '%s' "${PATH-<unset>}" > "$d/path"
]]

local CLAUDE_OUT = [[
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake-session"}'
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"fake-session"}'
printf '%s\n' '{"type":"result","subtype":"success","result":"ok","session_id":"fake-session"}'
]]

local HERDR_OUT = [[printf '%s\n' '{"result":{}}']]

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

---Install fake executables first on PATH. Each call is recorded under
---<log>/<name>.<n>/ (argv, cwd, stdin, and a `done` marker that the default
---bodies touch); a body may use $log and $d (that directory).
---@param opts? { bodies?: table<string,string>, stdin?: boolean, env?: boolean }
---  bodies: name -> shell body (replaces the default claude + herdr fakes);
---  stdin: record stdin (default true unless bodies is given); env: also record
---  $AP_TEST_VAR, $XDG_STATE_HOME and $PATH.
function M.install_fakes(opts)
  opts = opts or {}
  local custom = opts.bodies ~= nil
  local record_stdin = opts.stdin
  if record_stdin == nil then
    record_stdin = not custom
  end
  local bodies = opts.bodies
    or { claude = CLAUDE_OUT .. 'touch "$d/done"\n', herdr = HERDR_OUT .. '\ntouch "$d/done"\n' }
  local dir = vim.fn.tempname()
  local bin, log = dir .. "/bin", dir .. "/log"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(log, "p")
  for name, body in pairs(bodies) do
    local path = bin .. "/" .. name
    local f = assert(io.open(path, "w"))
    local pre = (opts.env and ENV_RECORD or "") .. (record_stdin and 'cat > "$d/stdin"\n' or "")
    f:write(string.format(PRELUDE, name, log, name, pre .. body))
    f:close()
    vim.uv.fs_chmod(path, tonumber("755", 8))
  end
  local old = vim.env.PATH
  vim.env.PATH = bin .. ":" .. old
  local self = { dir = bin, bin = bin, log = log }
  function self.calls(name)
    local list = {}
    local n = tonumber(vim.trim(read(log .. "/" .. name .. ".n") or "0")) or 0
    for i = 1, n do
      local d = log .. "/" .. name .. "." .. i
      local raw = read(d .. "/argv")
      if raw then
        local argv = {}
        for a in raw:gmatch("([^%z]*)%z") do
          argv[#argv + 1] = a
        end
        list[#list + 1] = {
          argv = argv,
          stdin = read(d .. "/stdin") or "",
          cwd = vim.trim(read(d .. "/cwd") or ""),
          ap_test_var = read(d .. "/ap_test_var"),
          xdg_state_home = read(d .. "/xdg_state_home"),
          path = read(d .. "/path"),
          done = vim.uv.fs_stat(d .. "/done") ~= nil,
        }
      end
    end
    return list
  end
  ---True when every recorded call of every fake has finished.
  function self.all_done()
    for name in pairs(bodies) do
      local n = tonumber(vim.trim(read(log .. "/" .. name .. ".n") or "0")) or 0
      for i = 1, n do
        if not vim.uv.fs_stat(log .. "/" .. name .. "." .. i .. "/done") then
          return false
        end
      end
    end
    return true
  end
  function self.agents(list)
    vim.fn.mkdir(log, "p")
    local f = assert(io.open(log .. "/agents.json", "wb"))
    f:write(vim.json.encode({ result = { agents = list } }))
    f:close()
  end
  ---Create the empty marker file <log>/<name> (the fakes test for it).
  function self.flag(name)
    local f = assert(io.open(log .. "/" .. name, "wb"))
    f:close()
  end
  function self.restore()
    vim.env.PATH = old
  end
  return self
end

return M
