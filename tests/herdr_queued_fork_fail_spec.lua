-- agent-poke_nvim-5h5 (owner's answer to the nit at headless.lua:418): a herdr
-- fork delivery queued behind a running background poke that later cannot
-- start copies the user's UNWRAPPED prompt (not the fork wrapper) to the "
-- register and notifies once, on one line.
--
-- Harness: tests/herdr_fakes (fake herdr + claude, PATH = fakes + /usr/bin:/bin).
-- Its fake `claude` is replaced by a gated one (same recording prelude, built
-- with tests/helpers.install_fakes) that waits until <log>/release exists, so
-- the first run holds the queue. The fork cannot start because its session's
-- directory is removed while it waits (vim.system throws on a missing cwd).
local F = require("tests.herdr_fakes")
local helpers = require("tests.helpers")

local GATED_BODY = [[
trap 'touch "$d/done"; exit 143' TERM
sid=fake-session; prev=
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  prev=$a
done
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
i=0
while [ ! -e "$log/release" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\",\"session_id\":\"$sid\"}"
touch "$d/done"
]]

describe("herdr target: a fork queued behind a running poke that cannot start", function()
  local h = F.harness()
  local gated

  before_each(function()
    local path = vim.env.PATH
    gated = helpers.install_fakes({ bodies = { claude = GATED_BODY } })
    vim.env.PATH = path -- only its claude is used, copied over the harness' one
    local src = assert(io.open(gated.bin .. "/claude", "rb"))
    local body = src:read("a")
    src:close()
    local dst = assert(io.open(h.fakes.bin .. "/claude", "wb"))
    dst:write(body)
    dst:close()
    vim.uv.fs_chmod(h.fakes.bin .. "/claude", tonumber("755", 8))
    vim.fn.setreg('"', "")
  end)

  after_each(function()
    if gated then
      gated.flag("release")
      local headless = package.loaded["agent-poke.headless"]
      if headless then
        pcall(headless.stop_all)
      end
      vim.wait(5000, gated.all_done, 20)
    end
  end)

  it("copies the unwrapped prompt to the \" register and notifies once", function()
    h.ap.setup({ targets = { "herdr" }, isolate = "fork" })
    local headless = require("agent-poke.headless")
    local sess_dir, pane_dir = F.new_dir(), F.new_dir()
    F.transcript("sess-123", sess_dir)
    h.fakes.agents({ F.pane("w1:p1", "Review PR", pane_dir, "sess-123") })
    local r = F.new_dir()
    h.state.set(r, "target", { target = "herdr", id = "w1:p1" })

    -- a background run of this root holds the queue
    local started = headless.poke(r, "holding prompt")
    assert.is_true(started, "notes: " .. vim.inspect(h.notes))
    h.wait_for("the holding run", function()
      return #gated.calls("claude") >= 1
    end)

    local prompt = "please check the comments\nin src/main.lua"
    local status = h.ap.poke(r, prompt)
    assert.are.equal("queued", status, "the fork was not queued; notes: " .. vim.inspect(h.notes))
    assert.are.equal(0, #h.fakes.prompts(), "the prompt was typed instead of forked")

    vim.fn.delete(sess_dir, "rf") -- the fork's session directory is gone: it cannot start
    vim.fn.setreg('"', "")
    local before = #h.notes
    gated.flag("release")

    h.wait_for("the holding run to end", function()
      local s = headless.status(r)
      return s and s.status ~= "working"
    end)
    vim.wait(300)

    assert.are.equal(1, #gated.calls("claude"), "the fork started after all: " .. vim.inspect(gated.calls("claude")))
    local after = vim.list_slice(h.notes, before + 1)
    assert.are.equal(1, #after, "expected exactly one notification for the fork that could not start: "
      .. vim.inspect(after))
    assert.is_nil(after[1].msg:find("\n", 1, true), "the notification spans more than one line: " .. after[1].msg)
    assert.are.equal(vim.log.levels.ERROR, after[1].level)
    assert.are.equal(prompt, vim.fn.getreg('"'),
      "the user's unwrapped prompt was not copied to the \" register (the fork wrapper must not be)")
  end)
end)
