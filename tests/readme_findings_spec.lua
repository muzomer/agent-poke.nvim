-- agent-poke_nvim-wtd.6 review finding: the README install examples must clone
-- from the owner's GitHub account (muzomer), not a guessed one.
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local README = ROOT .. "/README.md"

local function readme()
  assert.are.equal(1, vim.fn.filereadable(README), "no README.md at the repository root")
  return table.concat(vim.fn.readfile(README), "\n")
end

describe("README.md install examples", function()
  it("lazy.nvim spec uses muzomer/agent-poke.nvim", function()
    assert.is_truthy(readme():find('"muzomer/agent-poke.nvim"', 1, true))
  end)

  it("vim.pack URL uses https://github.com/muzomer/agent-poke.nvim", function()
    assert.is_truthy(readme():find("https://github.com/muzomer/agent-poke.nvim", 1, true))
  end)

  it("names no other GitHub owner for the plugin", function()
    local text = readme()
    for owner in text:gmatch("([%w_.-]+)/agent%-poke%.nvim") do
      if owner ~= "github.com" then
        assert.are.equal("muzomer", owner)
      end
    end
  end)
end)
