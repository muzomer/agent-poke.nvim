-- agent-poke_nvim-0d8.3 (review findings): after the epic herdr is an opt-in
-- target (setup({}) registers none), so the README must not say herdr is used
-- automatically: the intro names the background agent as the default and herdr
-- as a target turned on with targets = { "herdr" }; the pick()/poke() docs say
-- herdr panes appear only when the herdr target is enabled; the register_target
-- docs say it is called after setup() (setup() resets the target list) and that
-- configure(opts) is only called for built-ins under lua/agent-poke/targets/.
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local README = ROOT .. "/README.md"

local function lines()
  assert.are.equal(1, vim.fn.filereadable(README), "no README.md at the repository root")
  return vim.fn.readfile(README)
end

---The intro: the lines after the `# title` up to the first other heading.
local function intro()
  local out, seen_title = {}, false
  for _, l in ipairs(lines()) do
    if l:match("^#%s") and not seen_title then
      seen_title = true
    elseif l:match("^#+%s") then
      break
    elseif seen_title then
      out[#out + 1] = l
    end
  end
  return table.concat(out, "\n")
end

---Text of the first section whose heading matches `pat` (case-insensitive),
---up to the next heading of the same or a higher level (code blocks ignored).
local function section(pat)
  local in_code, start, level = false, nil, nil
  local out = {}
  for _, l in ipairs(lines()) do
    if l:match("^%s*```") then
      in_code = not in_code
    end
    local hashes, title = nil, nil
    if not in_code then
      hashes, title = l:match("^(#+)%s+(.*)$")
    end
    if start then
      if hashes and #hashes <= level then
        break
      end
      out[#out + 1] = l
    elseif hashes and title:lower():find(pat) then
      start, level = true, #hashes
      out[#out + 1] = l
    end
  end
  assert.is_true(start ~= nil, "README has no section whose heading matches " .. pat)
  return table.concat(out, "\n")
end

---The top-level bullet in `text` starting with "- `<name>(" with its
---continuation lines (up to the next top-level bullet or blank line).
local function bullet(text, name)
  local out, on = {}, false
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    if on then
      if l:match("^%- ") or l:match("^%s*$") then
        break
      end
      out[#out + 1] = l
    elseif l:find("^%- `" .. name .. "%(") then
      on = true
      out[#out + 1] = l
    end
  end
  assert.is_true(on, "no `- `" .. name .. "(...)` bullet in the API section")
  return table.concat(out, "\n")
end

local function flat(s)
  return (s:gsub("%s+", " "))
end

describe("README.md herdr is an opt-in target", function()
  describe("intro (before the first section heading)", function()
    it("says the background agent is the default", function()
      local text = flat(intro()):lower()
      assert.is_truthy(text:find("background agent", 1, true), "the intro does not mention the background agent")
      assert.is_truthy(text:find("default", 1, true), "the intro does not say the background agent is the default")
    end)

    it('says herdr is a target turned on with targets = { "herdr" }', function()
      local text = flat(intro())
      assert.is_truthy(text:find("targets%s*=%s*{%s*[\"']herdr[\"']%s*}"),
        'the intro does not show herdr is enabled with targets = { "herdr" }: ' .. text)
    end)

    it("does not say a running herdr agent is picked automatically", function()
      local text = flat(intro()):lower()
      assert.is_falsy(text:find("if you run an agent in", 1, true),
        "the intro still says herdr is used when you run an agent in it: " .. text)
      assert.is_falsy(text:find("when herdr is gone", 1, true),
        "the intro still presents the background agent as the fallback for herdr: " .. text)
    end)
  end)

  describe("pick()/poke() docs", function()
    it("the ap.pick(...) example comment says herdr panes need the herdr target enabled", function()
      local api = section("^api")
      local line
      for l in api:gmatch("[^\n]+") do
        if l:find("ap%.pick%(") then
          line = l
          break
        end
      end
      assert.is_truthy(line, "no ap.pick(...) line in the API example")
      if line:lower():find("herdr", 1, true) then
        assert.is_truthy(line:lower():find("enabl", 1, true),
          "the ap.pick comment speaks of herdr panes without saying the herdr target must be enabled: " .. line)
      end
    end)

    for _, name in ipairs({ "pick", "poke" }) do
      it("the " .. name .. "() bullet says herdr applies only when the herdr target is enabled", function()
        local b = flat(bullet(section("^api"), name)):lower()
        if b:find("herdr", 1, true) then
          assert.is_truthy(b:find("enabl", 1, true),
            "the " .. name .. "() docs speak of herdr without saying the herdr target must be enabled: " .. b)
        end
      end)
    end
  end)

  describe("register_target docs (targets section)", function()
    it("say register_target is called after setup()", function()
      local text = flat(section("targets?")):lower()
      assert.is_truthy(text:find("after[^.]-setup") or text:find("after[^.]-%)%.setup"),
        "the targets section does not say register_target must be called after setup(): " .. text)
    end)

    it("say setup() resets the target list", function()
      local text = flat(section("targets?")):lower()
      assert.is_truthy(text:find("reset", 1, true) or text:find("clear", 1, true),
        "the targets section does not say setup() resets/clears the registered targets")
    end)

    it("say configure(opts) is only called for built-in targets under lua/agent-poke/targets/", function()
      local text = flat(section("targets?"))
      assert.is_truthy(text:find("lua/agent-poke/targets/", 1, true),
        "the targets section does not name lua/agent-poke/targets/ for configure")
      assert.is_truthy(text:lower():find("built%-in"), "the targets section does not say built-in")
    end)
  end)
end)
