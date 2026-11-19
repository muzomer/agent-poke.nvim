-- agent-poke_nvim-5h5 (finding, blocker headless.lua:600,611,615): roots are
-- normalized only for internal lookup keys (runs, chats, queue); the progress
-- handles and AgentPokeProgress events of a background poke carry the root
-- string exactly as the caller passed it (trailing slash, symlink), as
-- init.lua does for the other targets. beads.nvim matches id-less events by
-- `x.root == data.root`.
--
-- The background agent is a fake `claude` (tests/helpers.install_fakes) that
-- waits until <log>/release exists, so a run can be held to queue a second
-- poke. PATH holds only the fakes and /usr/bin:/bin.
local helpers = require("tests.helpers")

local uv = vim.uv or vim.loop

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

local function new_root()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return assert(uv.fs_realpath(d))
end

local function unload()
  for name in pairs(package.loaded) do
    if name == "agent-poke" or name:match("^agent%-poke%.") then
      package.loaded[name] = nil
    end
  end
end

describe("AgentPokeProgress of a background poke carries the caller's root", function()
  local ap, headless, progress, fakes, notes, events, au
  local old_state_home, old_notify, old_path

  before_each(function()
    old_state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = vim.fn.tempname()
    old_path = vim.env.PATH
    fakes = helpers.install_fakes({ bodies = { claude = GATED_BODY } })
    vim.env.PATH = fakes.bin .. ":/usr/bin:/bin"
    old_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    events = {}
    au = vim.api.nvim_create_autocmd("User", {
      pattern = "AgentPokeProgress",
      callback = function(ev)
        events[#events + 1] = vim.deepcopy(ev.data)
      end,
    })
    unload()
    ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    headless = require("agent-poke.headless")
    progress = require("agent-poke.progress")
  end)

  after_each(function()
    local f = io.open(fakes.log .. "/release", "w")
    if f then
      f:close()
    end
    pcall(headless.stop_all)
    vim.wait(3000, function()
      return fakes.all_done == nil or fakes.all_done()
    end, 20)
    pcall(vim.api.nvim_del_autocmd, au)
    vim.notify = old_notify
    fakes.restore()
    vim.env.PATH = old_path
    vim.env.XDG_STATE_HOME = old_state_home
    unload()
    ap.config = require("agent-poke.defaults")()
  end)

  local function release()
    local f = assert(io.open(fakes.log .. "/release", "w"))
    f:close()
  end

  local function events_of(id)
    return vim.tbl_filter(function(e)
      return e.id == id
    end, events)
  end

  local function wait_stage(id, stage)
    assert(vim.wait(10000, function()
      for _, e in ipairs(events_of(id)) do
        if e.stage == stage then
          return true
        end
      end
      return false
    end, 20), "no " .. stage .. " event for " .. tostring(id) .. ": " .. vim.inspect(events) .. "; notes: " .. vim.inspect(notes))
  end

  local function assert_roots(id, root)
    local evs = events_of(id)
    assert.is_true(#evs > 0, "no event for " .. tostring(id))
    for _, e in ipairs(evs) do
      assert.are.equal(root, e.root, "an AgentPokeProgress event carries a root other than the caller's: "
        .. vim.inspect(evs))
    end
    assert.are.equal(root, progress.get(id).root, "the progress handle keeps a root other than the caller's")
  end

  it("headless.poke through /a/b/ (trailing slash): every event's root is '/a/b/'", function()
    local r = new_root()
    local caller = r .. "/"
    local started, how, id = headless.poke(caller, "slash prompt")
    assert.is_true(started, "notes: " .. vim.inspect(notes))
    assert.are.equal("started", how)
    release()
    wait_stage(id, "done")
    assert_roots(id, caller)
  end)

  it("headless.poke through a symlink: every event's root is the symlink's path", function()
    local r = new_root()
    local link = vim.fn.tempname()
    assert(uv.fs_symlink(r, link))
    local started, _, id = headless.poke(link, "link prompt")
    assert.is_true(started, "notes: " .. vim.inspect(notes))
    release()
    wait_stage(id, "done")
    assert_roots(id, link)
  end)

  it("core ap.poke (background agent) through /a/b/: every event's root is '/a/b/'", function()
    local r = new_root()
    local caller = r .. "/"
    local status, id = ap.poke(caller, "core prompt")
    assert.are.equal("started", status, "notes: " .. vim.inspect(notes))
    release()
    wait_stage(id, "done")
    assert_roots(id, caller)
  end)

  it("a poke queued through a symlink behind a run of /a/b: its events carry the symlink's path; status works through any spelling", function()
    local r = new_root()
    local link = vim.fn.tempname()
    assert(uv.fs_symlink(r, link))
    local s1, _, id1 = headless.poke(r, "first")
    assert.is_true(s1, "notes: " .. vim.inspect(notes))
    assert(vim.wait(5000, function()
      return #fakes.calls("claude") >= 1
    end, 20), "the first run never started")
    local s2, how2, id2 = headless.poke(link, "second")
    assert.is_false(s2)
    assert.are.equal("queued", how2, "the symlinked spelling was not queued behind the run of /a/b")
    assert.are.equal("working", (headless.status(link) or {}).status, "status() through the symlink sees no run")
    assert.are.equal("working", (headless.status(r .. "/") or {}).status, "status() through /a/b/ sees no run")
    release()
    wait_stage(id2, "done")
    assert_roots(id1, r)
    assert_roots(id2, link)
    local queued = vim.tbl_filter(function(e)
      return e.stage == "queued"
    end, events_of(id2))
    assert.are.equal(1, #queued, "no queued event for the second poke: " .. vim.inspect(events_of(id2)))
  end)

  it("passes already: a target other than the background agent emits the caller's root as given", function()
    ap.setup({ headless = { cmd = fakes.bin .. "/claude" } })
    assert.is_true(ap.register_target({
      name = "other",
      list = function()
        return { { id = "e1", title = "Other entry" } }
      end,
      deliver = function()
        return "typed"
      end,
    }))
    local r = new_root()
    local caller = r .. "/"
    require("agent-poke.state").set(r, "target", { target = "other", id = "e1" })
    local status, id = ap.poke(caller, "typed prompt")
    assert.are.equal("typed", status, "notes: " .. vim.inspect(notes))
    wait_stage(id, "sent")
    assert_roots(id, caller)
  end)
end)
