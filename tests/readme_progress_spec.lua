-- agent-poke_nvim-4kp: the README documents progress(), its stages, the
-- AgentPokeProgress autocmd and a target's optional progress(handle).
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local README = ROOT .. "/README.md"

local function text()
  assert.are.equal(1, vim.fn.filereadable(README), "no README.md at the repository root")
  return table.concat(vim.fn.readfile(README), "\n")
end

describe("README: per-poke progress", function()
  it("documents progress(id) and that poke returns an id", function()
    local t = text()
    assert.is_truthy(t:find("progress(", 1, true), "README does not mention progress()")
    assert.is_truthy(t:find("ap.progress", 1, true) or t:find("`progress(id", 1, true),
      "README does not document ap.progress(id)")
  end)

  it("names every stage", function()
    local t = text()
    for _, s in ipairs({ "sent", "queued", "working", "done", "failed" }) do
      assert.is_truthy(t:find('"' .. s .. '"', 1, true) or t:find("`" .. s .. "`", 1, true),
        "README does not name the stage " .. s)
    end
  end)

  it("documents the AgentPokeProgress autocmd and its data", function()
    local t = text()
    assert.is_truthy(t:find("AgentPokeProgress", 1, true), "README does not mention AgentPokeProgress")
    for _, k in ipairs({ "id", "root", "stage", "target" }) do
      assert.is_truthy(t:find("stage", 1, true) and t:find(k, 1, true), "README does not name the event field " .. k)
    end
  end)

  it("documents a target's optional progress(handle)", function()
    assert.is_truthy(text():find("progress(handle", 1, true), "README does not document progress(handle)")
  end)
end)
