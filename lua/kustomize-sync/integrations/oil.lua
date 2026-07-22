local config = require("kustomize-sync.config")
local ks = require("kustomize-sync")

local M = {}

M.get_ctx = function()
  local ok, oil = pcall(require, "oil")
  if not ok then return nil end
  local entry = oil.get_cursor_entry()
  local dir = oil.get_current_dir()
  if not entry or not dir then return nil end
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    path    = dir .. entry.name,
    is_dir  = entry.type == "directory",
    refresh = function()
      require("oil.view").render_buffer_async(bufnr, {}, function() end)
    end,
  }
end

local function setup()
  local oil_config = config.options.integrations.oil

  if oil_config.auto_prompt_on_change then
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("KustomizeSyncOil", { clear = true }),
      pattern = "OilActionsPost",
      callback = function(args)
        if args.data.err then return end
        local bufnr = vim.api.nvim_get_current_buf()
        local changes = {}
        for _, action in ipairs(args.data.actions) do
          if action.type == "create" or action.type == "delete" then
            table.insert(changes, {
              op         = action.type == "create" and "add" or "remove",
              filepath   = action.url:sub(7),
              entry_type = action.entry_type,
            })
          end
        end
        vim.schedule(function()
          ks.batch_handle_changes(changes, function()
            require("oil.view").render_buffer_async(bufnr, {}, function() end)
          end)
        end)
      end,
    })
  end
end

setup()

return M
