-- Init for `make test`: this plugin and what the suite needs, nothing else.
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
for _, dep in ipairs({ "mini.test", "nui.nvim" }) do
  vim.opt.runtimepath:append(root .. "/deps/" .. dep)
end
vim.o.swapfile = false

require("mini.test").setup()
