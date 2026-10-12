local H = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = H.hooks })

local function keys(input)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), "x", false)
end

-- The one menu test. The rest of the nui surface is checked by hand; this is
-- here because what it guards is a write, not a layout.
T["a toggle is written at once and shows in the open kustomization"] = function()
  local root = H.project({
    "a.yaml", "b.yaml",
    ["kustomization.yaml"] = H.kustomization({ "a.yaml" }),
  })
  local file = root .. "/kustomization.yaml"
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()

  require("kustomize-sync").interactive_sync({ path = file, is_dir = false, refresh = function() end })
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[x] a.yaml", "[ ] b.yaml" })

  keys("j<Space>")
  eq(H.listed(root), { "a.yaml", "b.yaml" })
  -- Still in the menu, and the buffer behind it already has the entry.
  eq(vim.api.nvim_get_current_win() ~= win, true)
  eq(vim.api.nvim_buf_get_lines(buf, 3, -1, false), { "  - a.yaml", "  - b.yaml" })

  keys("gg<Space>")
  eq(vim.api.nvim_buf_get_lines(buf, 3, -1, false), { "  - b.yaml" })
  -- The kustomization was reloaded where it is, not loaded into the menu.
  eq(vim.api.nvim_win_get_buf(win), buf)
end

return T
