local config = require("kustomize-sync.config")
local ks = require("kustomize-sync")

local M = {}

-- The path behind a local `oil://` url. Nil for anything else: oil's other
-- adapters (`oil-trash://`, `oil-ssh://`) name places no kustomization here
-- governs, and cutting a fixed prefix off them leaves a path that isn't one.
local function url_path(url)
  return url and url:match("^oil://(.*)$")
end

local function refresher(bufnr)
  return function()
    require("oil.view").render_buffer_async(bufnr, {}, function() end)
  end
end

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
    refresh = refresher(bufnr),
  }
end

function M.setup()
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
          local path = url_path(action.url)
          local src, dest = url_path(action.src_url), url_path(action.dest_url)

          if (action.type == "create" or action.type == "delete") and path then
            table.insert(changes, {
              op         = action.type == "create" and "add" or "remove",
              filepath   = path,
              entry_type = action.entry_type,
            })
          elseif action.type == "copy" and dest then
            -- The source stays where it is, so only the new file is a change.
            table.insert(changes, { op = "add", filepath = dest, entry_type = action.entry_type })
          elseif action.type == "move" and src and dest then
            -- Folded into this batch rather than prompted separately, so a
            -- rename alongside other edits stays one confirmation.
            table.insert(changes, { op = "move", src = src, dest = dest })
          elseif action.type == "move" and src then
            -- Moved somewhere oil's local adapter doesn't reach, which is how
            -- delete-to-trash arrives. From here that is a removal.
            table.insert(changes, { op = "remove", filepath = src, entry_type = action.entry_type })
          elseif action.type == "move" and dest then
            -- And the way back: restored from the trash, so it is new here.
            table.insert(changes, { op = "add", filepath = dest, entry_type = action.entry_type })
          end
        end
        vim.schedule(function()
          ks.batch_handle_changes(changes, refresher(bufnr))
        end)
      end,
    })
  end
end

return M
