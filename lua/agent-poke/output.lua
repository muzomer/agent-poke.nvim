---A window following the output of root's current (or last) background run,
---stream-json rendered as text. Refreshed while the run is in flight; a second
---toggle closes it.
local headless = require("agent-poke.headless")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

M.interval = 200 -- ms between refreshes while the run is in flight

local win, buf, timer

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
  win, buf = nil, nil
end

local function render(root, buf, win)
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines = headless.lines(root)
  if #lines == 0 then
    lines = { "(no output yet)" }
  end
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
  if headless.running(root) then
    local mine, mybuf = win, buf
    local t = uv.new_timer()
    timer = t
    t:start(M.interval, M.interval, vim.schedule_wrap(function()
      -- only ever stop the timer this callback was created for
      if t:is_closing() then
        return
      end
      if not api.nvim_win_is_valid(mine) or not api.nvim_buf_is_valid(mybuf) then
        stop_handle(t)
        if timer == t then
          timer = nil
        end
        return
      end
      local ok = pcall(render, root, mybuf, mine)
      if not ok or not headless.running(root) then
        stop_handle(t)
        if timer == t then
          timer = nil
        end
      end
    end))
  end
end

return M
