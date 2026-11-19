---Per-poke handles: where each poke is on its way ("sent"|"queued"|"working"|"done"|"failed").
---At most MAX handles are kept; a stage change fires the User autocmd AgentPokeProgress.
local M = {}

M.MAX = 100

local handles = {} -- id -> { id, root, target, stage, error?, background?, th? }
local order = {} -- ids, oldest first
local counter = 0
local salt = string.format("%x%x", (vim.uv or vim.loop).hrtime() % 0xffffffff, math.random(0, 0xffffff))

local function final(h)
  return h.stage == "done" or h.stage == "failed"
end

local function emit(h)
  local data = { id = h.id, root = h.root, stage = h.stage, target = h.target }
  vim.schedule(function()
    -- a throwing handler must not break the poke
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AgentPokeProgress", data = data, modeline = false })
  end)
end

---Drop old handles beyond MAX; a background poke still in flight is kept.
local function trim()
  local i = 1
  while #order > M.MAX and i < #order do -- the newest handle is never evicted
    local h = handles[order[i]]
    if h and h.background and not final(h) then
      i = i + 1
    else
      handles[order[i]] = nil
      table.remove(order, i)
    end
  end
end

---New handle at `stage`. `background` marks the core-tracked runs.
---@return string id
function M.new(root, target, stage, err, background)
  counter = counter + 1
  local id = string.format("poke-%s-%d", salt, counter)
  local h = { id = id, root = root, target = target, stage = stage, error = err, background = background }
  handles[id] = h
  order[#order + 1] = id
  trim()
  emit(h)
  return id
end

---Move a handle to `stage` (fires only on a change).
function M.set(id, stage, err)
  local h = id and handles[id]
  if not h or (h.stage == stage and h.error == err) then
    return
  end
  local changed = h.stage ~= stage
  h.stage, h.error = stage, err
  if changed then
    emit(h)
  end
end

function M.get(id)
  return type(id) == "string" and handles[id] or nil
end

---@return string? stage
---@return string? err
function M.stage(id)
  local h = M.get(id)
  if h then
    return h.stage, h.error
  end
end

return M
