if vim.g.loaded_kustomize_sync == 1 then
  return
end
vim.g.loaded_kustomize_sync = 1

-- Helper to get the context from current active window
local function get_current_buf_ctx()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("No active file or buffer", vim.log.levels.WARN)
    return nil
  end
  return {
    path = path,
    is_dir = vim.fn.isdirectory(path) == 1,
    refresh = function()
      vim.cmd("silent! edit")
    end,
  }
end

vim.api.nvim_create_user_command("KustomizeSync", function()
  local ctx = get_current_buf_ctx()
  if ctx then
    require("kustomize-sync").sync(ctx)
  end
end, {})

vim.api.nvim_create_user_command("KustomizeInteractiveSync", function()
  local ctx = get_current_buf_ctx()
  if ctx then
    require("kustomize-sync").interactive_sync(ctx)
  end
end, {})
