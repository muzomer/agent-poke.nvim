-- Test helpers: fake `claude` and `herdr` executables on PATH.
local M = {}

local SCRIPT = [[#!/bin/sh
# fake %s: record argv (one per record) and stdin, print canned output
log="%s/%s"
n=$(cat "$log.n" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$log.n"
d="$log.$n"
mkdir -p "$d"
: > "$d/argv"
for a in "$@"; do printf '%%s\0' "$a" >> "$d/argv"; done
cat > "$d/stdin"
%s
]]

local CLAUDE_OUT = [[
printf '%%s\n' '{"type":"system","subtype":"init","session_id":"fake-session"}'
printf '%%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"fake-session"}'
printf '%%s\n' '{"type":"result","subtype":"success","result":"ok","session_id":"fake-session"}'
]]

local HERDR_OUT = [[printf '%%s\n' '{"result":{}}']]

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

---@return { dir: string, calls: fun(name: string): { argv: string[], stdin: string }[], restore: fun() }
function M.install_fakes()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/bin", "p")
  vim.fn.mkdir(dir .. "/log", "p")
  local bin = dir .. "/bin"
  for name, out in pairs({ claude = CLAUDE_OUT, herdr = HERDR_OUT }) do
    local path = bin .. "/" .. name
    local f = assert(io.open(path, "w"))
    f:write(string.format(SCRIPT, name, dir .. "/log", name, string.format(out)))
    f:close()
    vim.uv.fs_chmod(path, tonumber("755", 8))
  end
  local old = vim.env.PATH
  vim.env.PATH = bin .. ":" .. old
  return {
    dir = bin,
    calls = function(name)
      local list = {}
      local n = tonumber(vim.trim(read(dir .. "/log/" .. name .. ".n") or "0")) or 0
      for i = 1, n do
        local d = dir .. "/log/" .. name .. "." .. i
        local argv = {}
        for a in (read(d .. "/argv") or ""):gmatch("([^%z]*)%z") do
          argv[#argv + 1] = a
        end
        list[#list + 1] = { argv = argv, stdin = read(d .. "/stdin") or "" }
      end
      return list
    end,
    restore = function()
      vim.env.PATH = old
    end,
  }
end

return M
