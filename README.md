# kustomize-sync.nvim

A modular Neovim plugin for synchronizing and managing Kubernetes Kustomize manifests directly from your Neovim file explorers (Neo-tree, Oil.nvim) and active buffers.

## Features

- **Resource Syncing:** Automatically detects and syncs directories with `kustomization.yaml` files.
- **Interactive Resource Selector:** Toggles manifests dynamically inside a directory using an interactive `nui.menu` checkbox selector.
- **Auto-prompt on File Changes:** Watches file creations and deletions in Neo-tree or Oil, automatically prompting you to add or remove resources from `kustomization.yaml`.
- **Healthcheck Support:** Built-in `:checkhealth kustomize-sync` to verify CLI tool dependencies.
- **Lazy CLI Checks:** Warns you about missing `yq` or `kustomize` executables only when an action is triggered.

## Dependencies

- Neovim >= 0.11.0
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- **External CLIs:**
  - [yq](https://github.com/mikefarah/yq) (v4 recommended)
  - [kustomize](https://kustomize.io/) (optional, needed to bootstrap new `kustomization.yaml` files via `kustomize create`)

## Installation

<details open>
<summary>Using native vim.pack (Neovim >= 0.12)</summary>

```lua
vim.pack.add({
  {
    src = "https://github.com/rwilgaard/kustomize-sync.nvim",
  },
  -- Dependencies
  "https://github.com/MunifTanjim/nui.nvim",
})

require("kustomize-sync").setup({
  sort_resources = true,
  integrations = {
    neo_tree = {
      enabled = true,
      auto_prompt_on_change = true,
    },
    oil = {
      enabled = true,
      auto_prompt_on_change = true,
    }
  }
})
```
</details>

<details>
<summary>Using lazy.nvim</summary>

```lua
{
  "rwilgaard/kustomize-sync.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim"
  },
  config = function()
    require("kustomize-sync").setup({
      sort_resources = true,
      integrations = {
        neo_tree = {
          enabled = true,
          auto_prompt_on_change = true,
        },
        oil = {
          enabled = true,
          auto_prompt_on_change = true,
        }
      }
    })
  end
}
```
</details>

## Configuration

The default configuration settings:

```lua
require("kustomize-sync").setup({
  sort_resources = true, -- Alphabetically sort .resources list
  integrations = {
    neo_tree = {
      enabled = true,
      auto_prompt_on_change = true, -- Ask to sync when file is added/deleted
    },
    oil = {
      enabled = true,
      auto_prompt_on_change = true, -- Ask to sync in batch on buffer write
    }
  }
})
```

## Integration Wiring

### 1. Neo-tree Integration

To use keymaps to sync Kustomize resources on the currently highlighted file or folder in Neo-tree, add custom commands to your Neo-tree configuration:

```lua
require("neo-tree").setup({
  commands = {
    sync_kustomization = function(state)
      local ctx = require("kustomize-sync.integrations.neo-tree").get_ctx(state)
      require("kustomize-sync").sync(ctx)
    end,
    kustomize_interactive = function(state)
      local ctx = require("kustomize-sync.integrations.neo-tree").get_ctx(state)
      require("kustomize-sync").interactive_sync(ctx)
    end,
  },
  window = {
    mappings = {
      ["K"] = "sync_kustomization",
      ["I"] = "kustomize_interactive",
    }
  }
})
```

### 2. Oil.nvim Integration

To map sync controls inside an active Oil.nvim directory buffer, define these keymaps in your Oil setup table:

```lua
require("oil").setup({
  keymaps = {
    ["K"] = {
      callback = function()
        local ctx = require("kustomize-sync.integrations.oil").get_ctx()
        if ctx then require("kustomize-sync").sync(ctx) end
      end,
      desc = "Sync kustomization",
    },
    ["I"] = {
      callback = function()
        local ctx = require("kustomize-sync.integrations.oil").get_ctx()
        if ctx then require("kustomize-sync").interactive_sync(ctx) end
      end,
      desc = "Kustomize interactive",
    },
  }
})
```

## Global Commands

The plugin also exposes standard global commands for active file buffers:

- `:KustomizeSync` - Syncs resources of the directory containing the active buffer.
- `:KustomizeInteractiveSync` - Opens the interactive menu for the directory containing the active buffer.

## Healthcheck

Verify everything is correctly installed by running:

```vim
:checkhealth kustomize-sync
```

## License

MIT
