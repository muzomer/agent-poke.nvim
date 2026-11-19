-- agent-poke_nvim-ei4.5: the README and the code comments match the code.
-- Option paths are checked in full (headless.agent is not the deprecated agent),
-- against the real config tree (defaults.lua, nil defaults included) and the
-- options of the built-in targets (targets.<name>.<option>).
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function read(path)
  assert.are.equal(1, vim.fn.filereadable(path), "missing " .. path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function readme()
  return read(ROOT .. "/README.md")
end

---Paths of every `key = ...` in a Lua table literal, by nesting:
---`headless = { agent = "x" }` gives "headless" and "headless.agent".
---Comments are dropped; string contents are ignored.
local function table_paths(src)
  src = src:gsub("%-%-[^\n]*", "")
  src = src:gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
  local paths, stack = {}, {}
  local i = 1
  while i <= #src do
    local s, e, key = src:find("^([%a_][%w_]*)%s*=%s*", i)
    if s and src:sub(i - 1, i - 1):match("[%w_%.]") == nil and src:sub(e + 1, e + 1) ~= "=" then
      local named = {}
      for _, k in ipairs(stack) do
        if k then
          named[#named + 1] = k
        end
      end
      named[#named + 1] = key
      local path = table.concat(named, ".")
      paths[path] = true
      if src:sub(e + 1, e + 1) == "{" then
        stack[#stack + 1] = key
        i = e + 2
      else
        i = e + 1
      end
    else
      local c = src:sub(i, i)
      if c == "{" then
        stack[#stack + 1] = false -- an anonymous table: keep depth, no name
      elseif c == "}" then
        stack[#stack] = nil
      end
      i = i + 1
    end
  end
  local clean = {}
  for p in pairs(paths) do
    clean[#clean + 1] = p
  end
  return clean
end

---Paths set in the README's `setup({ ... })` examples (inside ```lua blocks).
local function readme_setup_paths()
  local found = {}
  for block in readme():gmatch("```lua\n(.-)```") do
    for args in block:gmatch("%.setup(%b())") do
      for _, p in ipairs(table_paths(args:sub(2, -2):match("^%s*(%b{})") or "{}")) do
        found[p] = true
      end
    end
  end
  return found
end

---The real option tree: every key of defaults.lua (nil defaults too) and,
---for each built-in target, the options it reads (M.opts.<name>).
local function config_paths()
  local src = read(ROOT .. "/lua/agent-poke/defaults.lua")
  local body = src:match("return%s*function%s*%(%)%s*return%s*(%b{})")
  assert.is_truthy(body, "defaults.lua is not `return function() return { ... } end`")
  local paths = {}
  for _, p in ipairs(table_paths(body:sub(2, -2))) do
    paths[#paths + 1] = p
  end
  for _, f in ipairs(vim.fn.glob(ROOT .. "/lua/agent-poke/targets/*.lua", false, true)) do
    local name = vim.fn.fnamemodify(f, ":t:r")
    local seen = {}
    for opt in read(f):gmatch("M%.opts%.([%a_][%w_]*)") do
      if not seen[opt] then
        seen[opt] = true
        paths[#paths + 1] = "targets." .. name .. "." .. opt
      end
    end
  end
  table.sort(paths)
  return paths
end

describe("README option paths", function()
  it("the parser reads nested paths (self-check)", function()
    local got = table_paths('{ a = 1, -- x = 2\n b = { c = "d = e", f = {} }, g = { "h" } }')
    table.sort(got)
    assert.are.same({ "a", "b", "b.c", "b.f", "g" }, got)
  end)

  it("the config tree includes headless.agent, nil defaults and targets.herdr.isolate", function()
    local set = {}
    for _, p in ipairs(config_paths()) do
      set[p] = true
    end
    for _, p in ipairs({ "targets", "headless.agent", "headless.cmd", "headless.permission_mode",
      "targets.herdr.isolate" }) do
      assert.is_true(set[p] == true, "config tree misses " .. p)
    end
  end)

  it("every option of the config tree is set at its full path in a README setup() example", function()
    local shown = readme_setup_paths()
    local missing = {}
    for _, p in ipairs(config_paths()) do
      if not shown[p] then
        missing[#missing + 1] = p
      end
    end
    assert.are.same({}, missing, "README setup() examples lack: " .. table.concat(missing, ", "))
  end)

  it("headless.agent is documented separately from the deprecated top-level agent", function()
    local shown = readme_setup_paths()
    assert.is_true(shown["headless.agent"] == true, "no headless = { agent = ... } in a setup() example")
    assert.is_nil(shown["agent"], "a README setup() example still sets the deprecated top-level agent")
  end)
end)

describe("README autocmd timing", function()
  it("does not claim that no autocmds exist until setup() (the background agent adds VimLeavePre when used)", function()
    local text = readme()
    assert.is_falsy(text:find("No autocmds[^\n]*until you call[^\n]*setup", 1),
      "README claims no autocmds until setup(); headless.lua creates VimLeavePre when it is loaded")
    assert.is_truthy(text:find("VimLeavePre", 1, true), "README does not name the VimLeavePre autocmd")
  end)

  it("passes already: require and setup({}) create no autocmd; the first background use does", function()
    package.loaded["agent-poke"] = nil
    package.loaded["agent-poke.headless"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "agent-poke-headless")
    local ap = require("agent-poke")
    ap.config = require("agent-poke.defaults")()
    ap.setup({})
    assert.is_false((pcall(vim.api.nvim_get_autocmds, { group = "agent-poke-headless" })),
      "an agent-poke autocmd exists after require + setup({})")
    ap.status(vim.fn.getcwd()) -- loads the background agent
    local ok, list = pcall(vim.api.nvim_get_autocmds, { group = "agent-poke-headless", event = "VimLeavePre" })
    assert.is_true(ok and #list == 1, "no VimLeavePre autocmd once the background agent is used")
  end)
end)

describe("comments and README match the backends", function()
  it("the permission_mode comment in defaults.lua names opencode", function()
    -- the permission_mode line plus any comment-only lines that continue it
    local src = vim.split(read(ROOT .. "/lua/agent-poke/defaults.lua"), "\n", { plain = true })
    local line
    for i, l in ipairs(src) do
      if l:find("permission_mode%s*=") then
        local parts = { l }
        for j = i + 1, #src do
          if not src[j]:match("^%s*%-%-") then
            break
          end
          parts[#parts + 1] = src[j]
        end
        line = table.concat(parts, "\n")
        break
      end
    end
    assert.is_truthy(line, "no permission_mode in defaults.lua")
    for _, a in ipairs({ "claude", "codex", "gemini", "opencode" }) do
      assert.is_truthy(line:find(a, 1, true), "permission_mode comment omits " .. a .. ": " .. line)
    end
  end)

  it("the README says chat() on gemini resumes its latest session, not the stored one", function()
    local text = readme()
    local chat = text:match("\n%- `chat%(root%)`:(.-)\n%- `")
    assert.is_truthy(chat, "no `chat(root)` entry in the API list")
    assert.is_truthy(chat:find("gemini", 1, true), "chat(root) entry does not mention gemini: " .. chat)
    assert.is_truthy(chat:find("latest", 1, true), "chat(root) entry does not say gemini resumes its latest session")
  end)
end)
