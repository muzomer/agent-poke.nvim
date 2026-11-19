-- agent-poke_nvim-0d8.3: the README explains core vs targets: a section on the
-- background agent (the default, no multiplexer needed), a targets section
-- (the target interface for adapter authors and enabling the herdr adapter),
-- and a migration table from the old `agent` option (owner: agent = "herdr" |
-- "auto" -> targets = { "herdr" }; agent = "headless" -> the default).
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local README = ROOT .. "/README.md"

local function lines()
  assert.are.equal(1, vim.fn.filereadable(README), "no README.md at the repository root")
  return vim.fn.readfile(README)
end

---Text of the first section whose heading matches `pat` (case-insensitive),
---up to the next heading of the same or a higher level. Headings inside
---code blocks are ignored.
local function section(pat)
  local ls = lines()
  local in_code, start, level = false, nil, nil
  local out = {}
  for _, l in ipairs(ls) do
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

local function has(text, needle)
  return text:find(needle, 1, true) ~= nil
end

describe("README.md core vs targets", function()
  describe("background agent section", function()
    it("exists with a heading naming the background agent", function()
      section("background agent")
    end)

    it("says the background agent is the default", function()
      assert.is_truthy(section("background agent"):lower():find("default", 1, true),
        "the background agent section does not say it is the default")
    end)
  end)

  describe("targets section", function()
    it("exists with a heading naming targets", function()
      section("targets?")
    end)

    it("shows how to register a target with register_target(", function()
      assert.is_truthy(section("targets?"):find("%.register_target%("), "no `.register_target(` example")
    end)

    it("shows enabling targets through setup({ targets = ... })", function()
      assert.is_truthy(section("targets?"):find("targets%s*="), "no `targets = ...` in the targets section")
    end)

    it("documents the target interface fields name, available, list and deliver", function()
      local text = section("targets?")
      local missing = {}
      for _, f in ipairs({ "name", "available", "list", "deliver" }) do
        if not text:find("%f[%w_]" .. f .. "%f[^%w_]") then
          missing[#missing + 1] = f
        end
      end
      assert.are.same({}, missing, "target fields not documented: " .. table.concat(missing, ", "))
    end)

    it("shows the herdr adapter with its options: targets = { herdr = { isolate = ... } }", function()
      local text = section("targets?")
      assert.is_truthy(text:find("targets%s*=%s*{%s*herdr%s*=%s*{%s*isolate%s*="),
        "no `targets = { herdr = { isolate = ... } }` example")
    end)
  end)

  describe("migration section", function()
    it("exists with a heading naming migration", function()
      section("migrat")
    end)

    it("has a markdown table", function()
      local text = section("migrat")
      assert.is_truthy(text:find("\n%s*|[^\n]*|"), "the migration section has no table")
      assert.is_truthy(text:find("\n%s*|[%s:|-]*%-%-%-[%s:|-]*\n"), "the migration table has no header separator row")
    end)

    local function rows()
      local out = {}
      for l in section("migrat"):gmatch("[^\n]+") do
        if l:match("^%s*|") then
          out[#out + 1] = l
        end
      end
      return out
    end

    local function row_for(agent)
      for _, r in ipairs(rows()) do
        if r:find("agent%s*=%s*[\"']" .. agent .. "[\"']") then
          return r
        end
      end
    end

    for _, agent in ipairs({ "herdr", "auto" }) do
      it('maps agent = "' .. agent .. '" to targets = { "herdr" } in one table row', function()
        local r = row_for(agent)
        assert.is_truthy(r, 'no table row for agent = "' .. agent .. '"')
        assert.is_truthy(r:find("targets%s*=%s*{%s*[\"']herdr[\"']%s*,?%s*}"),
          'the row for agent = "' .. agent .. '" does not give targets = { "herdr" }: ' .. r)
      end)
    end

    it('maps agent = "headless" to the default (no targets) in one table row', function()
      local r = row_for("headless")
      assert.is_truthy(r, 'no table row for agent = "headless"')
      local ok = r:lower():find("default", 1, true) or r:find("targets%s*=%s*{%s*}") or r:find("setup%(%s*{%s*}%s*%)")
      assert.is_truthy(ok, 'the row for agent = "headless" does not map to the default: ' .. r)
      assert.is_falsy(r:find("targets%s*=%s*{%s*[\"']herdr"), 'agent = "headless" must not enable herdr: ' .. r)
    end)

    it("says the old option still works for now but is deprecated", function()
      assert.is_truthy(section("migrat"):lower():find("deprecat", 1, true), "the migration section does not say deprecated")
    end)
  end)
end)
