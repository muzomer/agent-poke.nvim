-- Small helpers shared by init, headless and the optional adapters.
local M = {}

---Notify with the plugin prefix.
function M.notify(msg, level)
  vim.notify("agent-poke: " .. msg, level or vim.log.levels.INFO)
end

---Collapse whitespace and cut to max characters.
function M.one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  return #s > max and (s:sub(1, max - 1) .. "…") or s
end

return M
