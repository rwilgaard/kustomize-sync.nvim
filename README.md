# kustomize-sync.nvim

Keep a Kustomize `.resources` list in step with the files on disk, from Neo-tree, Oil.nvim, or the buffer you're already in.

## Features

- **Resource syncing:** Diffs the `.resources` list against what's actually in the directory, adding what's missing and dropping what's gone. In a directory with no kustomization yet, one run creates it and syncs it.
- **Bootstrap on add:** Create a directory in your explorer and you're asked whether to add it. If it has no kustomization file yet, confirming runs `kustomize create` inside it first, so the parent never ends up pointing at a directory that can't be built. The generated file is normalized to match the formatting of a synced one.
- **Interactive selector:** A checkbox menu for toggling individual resources in and out.
- **Auto-prompt on file changes:** Create or delete a file in Neo-tree or Oil and you get asked whether to update `kustomization.yaml`.
- **Build preview:** Render a kustomization with `kustomize build` into a read-only buffer, nothing written to disk. Horizontal split, vertical split, or float, set by `build.output`.
- **Build diff:** The first render becomes a baseline. Edit, rebuild, and changed lines are highlighted in place with a running hunk count; `]c` / `[c` walk between them and `d` opens a side-by-side diff. Answers whether a patch did what you meant, or whether a refactor changed nothing.
- **Healthcheck:** `:checkhealth kustomize-sync` checks the external CLIs.
- **Lazy CLI checks:** Missing `yq` or `kustomize` is reported when you run something that needs it, not at startup.

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
  build = {
    output = "split", -- "split" | "vsplit" | "float"
  },
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
      build = {
        output = "split", -- "split" | "vsplit" | "float"
      },
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
  format_command = nil,  -- e.g. { "yamlfmt" }; runs over kustomization.yaml after each write
  build = {
    output = "split", -- "split" | "vsplit" | "float"
    keymaps = {      -- string, list of strings, or false to leave unmapped
      rebuild      = "R",
      next_change  = "]c",
      prev_change  = "[c",
      diff         = "d",
      set_baseline = "D",
      close        = "q",
    },
  },
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

## Formatting

Left alone, `kustomization.yaml` comes out however `yq` writes it: two-space
indented list entries, no blank lines. Point `format_command` at your formatter
and it runs over the file after each write, so your settings win instead:

```lua
format_command = { "yamlfmt" }        -- or "yamlfmt", or any tool that formats in place
format_command = { "prettier", "-w" } -- extra flags go in the list
```

The command is run with the kustomization's directory as the working directory,
so a project `.yamlfmt` is picked up where one exists and your global config
applies everywhere else — no per-project setup. Any tool that rewrites the file
it's given works; the path is appended to the command.

Every file this plugin writes goes through it, including a `kustomization.yaml`
created for you when you add a directory — both that new file and the parent
gaining the entry. It runs once per sync rather than once per resource, and a
missing or failing command is reported without failing the sync. Blank lines are still stripped
beforehand, since `yq` leaves them behind and formatters tend to preserve them.

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
    kustomize_build = function(state)
      local ctx = require("kustomize-sync.integrations.neo-tree").get_ctx(state)
      require("kustomize-sync").build(ctx)
    end,
  },
  window = {
    mappings = {
      ["K"] = "sync_kustomization",
      ["I"] = "kustomize_interactive",
      ["B"] = "kustomize_build",
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
    ["B"] = {
      callback = function()
        local ctx = require("kustomize-sync.integrations.oil").get_ctx()
        if ctx then require("kustomize-sync").build(ctx) end
      end,
      desc = "Kustomize build",
    },
  }
})
```

## Global Commands

The plugin also exposes standard global commands for active file buffers:

- `:KustomizeSync` - Syncs resources of the directory containing the active buffer.
- `:KustomizeInteractiveSync` - Opens the interactive menu for the directory containing the active buffer.
- `:KustomizeBuild` - Renders the kustomization for the active buffer's directory (or nearest parent) into a read-only window.
- `:KustomizeBuild!` - Same, but discards the stored baseline so this render becomes the new one.

## Build Window Keymaps

| Action | Default | Effect |
| --- | --- | --- |
| `rebuild` | `R` | Rebuild. Reports how far the output has moved from the baseline. |
| `next_change` / `prev_change` | `]c` / `[c` | Jump to the next / previous changed region (wraps). |
| `diff` | `d` | Diff the current render against the baseline, side by side in a new tab. |
| `set_baseline` | `D` | Set the baseline to what is currently on screen. |
| `close` | `q` | Close the build window. The diff tab reuses this key. |

Every action takes a string, a list of strings, or `false` to leave it unmapped:

```lua
build = {
  keymaps = {
    diff        = "<CR>",         -- rebind
    close       = { "q", "<Esc>" }, -- several keys
    next_change = false,          -- leave unmapped
  },
}
```

Unspecified actions keep their defaults. The hint line in the window is built
from whatever you bind, and disabled actions drop out of it.

All of these are buffer-local, so they only apply inside the build window and
leave your global mappings alone.

`]c` / `[c` follow the gitsigns convention for hunk navigation in a normal
buffer. The build output isn't a real diff window, so these are ordinary
buffer-local mappings rather than the builtin diff motions. Inside the diff tab
the builtins do the same job, untouched.

The build and diff windows are pinned to their buffers with
[`winfixbuf`](https://neovim.io/doc/user/options.html#'winfixbuf'), so `:edit`,
`:bnext`, or a file picker can't drop a file into them and lose the render.
They fail with `E1513` instead. Close the window and the pin goes with it.

Lines that differ from the baseline are highlighted in the render itself
(`DiffAdd` / `DiffChange`, with removed blocks marked as virtual text), and the
window carries a running count: `± 3 hunks since baseline 14:02:11`, or
`= baseline 14:02:11` when the two match. The count sits in the winbar for
`split` / `vsplit` and in the float's bottom border. It stays put, so you can
look away and still know where you stand when you come back.

The first render of a directory becomes its baseline, kept per directory for the
rest of the Neovim session. Closing the build window doesn't discard it, which
is what makes `float` usable: the window covers the screen, so editing means
closing it first.

```
:KustomizeBuild   → baseline captured
q                 → edit your manifests
:KustomizeBuild   → status reads "± 2 hunks since baseline 14:02:11"
d                 → side-by-side diff of both renders
```

In `split` / `vsplit`, press `R` instead of reopening. Once you're happy with a
change, `D` (or `:KustomizeBuild!`) moves the baseline forward so the next one
measures from there.

## Healthcheck

Verify everything is correctly installed by running:

```vim
:checkhealth kustomize-sync
```

## License

MIT
