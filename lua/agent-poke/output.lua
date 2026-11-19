---A window following the output of root's current (or last) background run,
---stream-json rendered as text. Refreshed while it is open, so later runs show too; a second
---toggle closes it.
local headless = require("agent-poke.headless")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

M.interval = 200 -- ms between refreshes while the run is in flight

local win, buf, timer, last -- last: lines last rendered

local function stop_handle(t)
  if t and not t:is_closing() then
    pcall(t.stop, t)
    pcall(t.close, t)
  end
end

local function stop_timer()
  stop_handle(timer)
  timer = nil
end

local function close()
  stop_timer()
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  win, buf, last = nil, nil, nil
end

local function render(root, buf, win)
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines = headless.lines(root)
  if #lines == 0 then
    lines = { "(no output yet)" }
  end
  -- only touch the buffer/cursor when the content changed, so the user can scroll or yank
  if last and vim.deep_equal(last, lines) then
    return
  end
  last = vim.deepcopy(lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(buf), 0 })
  end
end

---Toggle the output window of root.
function M.toggle(root)
  if win and api.nvim_win_is_valid(win) then
    return close()
  end
  close()
  local prev = api.nvim_get_current_win()
  vim.cmd("botright 15split")
  win = api.nvim_get_current_win()
  buf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(win, buf)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "agent-poke-output"
  vim.wo[win].wrap = true
  render(root, buf, win)
  if api.nvim_win_is_valid(prev) then
    api.nvim_set_current_win(prev)
  end
  -- always follow: a run started later shows without reopening the window
  local mine, mybuf = win, buf
  local t = uv.new_timer()
  timer = t
  t:start(M.interval, M.interval, vim.schedule_wrap(function()
    -- only ever stop the timer this callback was created for
    if t:is_closing() then
      return
    end
    local ok = api.nvim_win_is_valid(mine) and api.nvim_buf_is_valid(mybuf) and pcall(render, root, mybuf, mine)
    if not ok then
      stop_handle(t)
      if timer == t then
        timer = nil
      end
    end
  end))
end

return M
