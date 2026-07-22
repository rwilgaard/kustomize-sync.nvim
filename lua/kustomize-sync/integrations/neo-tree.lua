local config = require("kustomize-sync.config")
local ks = require("kustomize-sync")

local M = {}

M.get_ctx = function(state)
  local node = state.tree:get_node()
  return {
    path    = node.path,
    is_dir  = node.type == "directory",
    refresh = function()
      require("neo-tree.sources.manager").refresh(state.name)
    end,
  }
end

local function setup()
  local nt_config = config.options.integrations.neo_tree

  -- Setup event handlers
  if nt_config.auto_prompt_on_change then
    local function register()
      local ok_ev, evs = pcall(require, "neo-tree.events")
      if not ok_ev then return end
      evs.subscribe({
        event = evs.FILE_ADDED,
        handler = function(filepath)
          ks.handle_change("add", filepath, function()
            require("neo-tree.sources.manager").refresh("filesystem")
          end)
        end
      })
      evs.subscribe({
        event = evs.FILE_DELETED,
        handler = function(filepath)
          ks.handle_change("remove", filepath, function()
            require("neo-tree.sources.manager").refresh("filesystem")
          end)
        end
      })
    end

    if vim.v.vim_did_enter == 1 then
      register()
    else
      vim.api.nvim_create_autocmd("VimEnter", {
        callback = register
      })
    end
  end
end

setup()

return M
