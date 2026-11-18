-- agent-poke_nvim-wtd.1: CLAUDE.md names the gate.
describe("CLAUDE.md", function()
  it("has a '## Quality gates' section with 'make test'", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local text = table.concat(vim.fn.readfile(root .. "/CLAUDE.md"), "\n")
    local s = text:find("\n## Quality gates\n", 1, true)
    assert.is_truthy(s, "no '## Quality gates' heading")
    local section = text:sub(s + 1)
    local nxt = section:find("\n## ", 2, true)
    if nxt then
      section = section:sub(1, nxt)
    end
    assert.is_truthy(section:find("make test", 1, true), "no 'make test' in the section")
  end)
end)
