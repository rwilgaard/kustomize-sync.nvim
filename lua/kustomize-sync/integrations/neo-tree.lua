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

-- The three commands, run on the node under the cursor. Neo-tree calls a
-- function mapping with its state, so these can be bound to a key as they are.
for _, action in ipairs({ "sync", "interactive_sync", "build" }) do
  M[action] = function(state)
    ks[action](M.get_ctx(state))
  end
end

local registered = false

function M.setup()
  local nt_config = config.options.integrations.neo_tree

  -- Setup event handlers
  if nt_config.auto_prompt_on_change and not registered then
    registered = true
    local function register()
      local ok_ev, evs = pcall(require, "neo-tree.events")
      if not ok_ev then return end
      local function refresh()
        require("neo-tree.sources.manager").refresh("filesystem")
      end
      evs.subscribe({
        event = evs.FILE_ADDED,
        handler = function(filepath) ks.handle_change("add", filepath, refresh) end
      })
      evs.subscribe({
        event = evs.FILE_DELETED,
        handler = function(filepath) ks.handle_change("remove", filepath, refresh) end
      })
      -- Both of these fire with a { source, destination } table, unlike
      -- FILE_ADDED and FILE_DELETED, which pass the path on its own.
      for _, event in ipairs({ evs.FILE_MOVED, evs.FILE_RENAMED }) do
        evs.subscribe({
          event = event,
          handler = function(args)
            if type(args) ~= "table" or not args.source or not args.destination then return end
            ks.handle_move(args.source, args.destination, refresh)
          end
        })
      end
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

return M
