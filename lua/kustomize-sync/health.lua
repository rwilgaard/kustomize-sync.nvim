local M = {}

M.check = function()
  vim.health.start("kustomize-sync.nvim")

  if vim.fn.executable("yq") == 1 then
    vim.health.ok("yq is installed.")
  else
    vim.health.error("yq is missing. Please install yq.")
  end

  if vim.fn.executable("kustomize") == 1 then
    vim.health.ok("kustomize is installed.")
  else
    vim.health.error("kustomize is missing. Please install kustomize.")
  end
end

return M
