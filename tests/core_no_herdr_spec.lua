-- agent-poke_nvim-0d8.1: core does not know about herdr. The literal 'herdr'
-- (case-sensitive, as grep finds it) appears in no file under lua/agent-poke/
-- except the optional adapter lua/agent-poke/targets/herdr.lua.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

describe("core without herdr", function()
  it("finds 'herdr' under lua/agent-poke/ only in targets/herdr.lua", function()
    local base = repo .. "/lua/agent-poke"
    assert.are.equal(1, vim.fn.isdirectory(base))
    local hits = {}
    for name, kind in vim.fs.dir(base, { depth = math.huge }) do
      if kind == "file" and name ~= "targets/herdr.lua" then
        local f = assert(io.open(base .. "/" .. name, "rb"))
        local text = f:read("a")
        f:close()
        if text:find("herdr", 1, true) then
          hits[#hits + 1] = name
        end
      end
    end
    table.sort(hits)
    assert.are.same({}, hits)
  end)
end)
