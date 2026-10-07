# kustomize-sync.nvim

Keep a Kustomize `.resources` list in step with the files on disk, from Neo-tree, Oil.nvim, or the buffer you're already in.

## Features

- **Resource syncing:** Diffs the `.resources` list against what's actually in the directory, adding what's missing and dropping what's gone. In a directory with no kustomization yet, one run creates it and syncs it, then asks whether the kustomization above should list the directory, the same as if you had created the file from an explorer.
- **Bootstrap on add:** Create a directory in your explorer and you're asked whether to add it. If it has no kustomization file yet, confirming runs `kustomize create` inside it first, so the parent never ends up pointing at a directory that can't be built. Create `apps/new/file.yaml` in one go and both `apps` and `apps/new` get one, each listed in the one above; the prompt says how many it will write. The generated file is normalized to match the formatting of a synced one.
- **Two ways to list a subdirectory:** A file in a new directory can go in as the directory (which gets its own kustomization) or by its path, `apps/new/file.yaml`. The prompt picks whichever the kustomization already uses and offers the other: `<Tab>` in the checkbox menu, `s` in the yes/no prompt. Set `nested` to pin the default.
- **Interactive selector:** A checkbox menu for toggling individual resources in and out, including files listed by path. A directory nothing is listed from yet shows as one folded line; open it to pick files out of it.
- **Auto-prompt on file changes:** Create, delete, or rename a file in Neo-tree or Oil and you get asked whether to update `kustomization.yaml`. A rename is one prompt covering both halves, and a move across directories updates the kustomization at each end. Files listed by path follow along: rename `deploy/` and every `deploy/…` entry is rewritten, delete it and they are all offered for removal.
- **Knows what isn't a resource:** Patch files, generator inputs, and components are reached through their own keys, so they're never offered as resources.
- **Build preview:** Render a kustomization with `kustomize build` into a read-only buffer, nothing written to disk. Horizontal split, vertical split, or float, set by `build.output`.
- **Build diff:** The first render becomes a baseline. Edit, rebuild, and changed lines are highlighted in place with a running hunk count; `<Tab>` / `<S-Tab>` walk between them and `d` opens a side-by-side diff. Answers whether a patch did what you meant, or whether a refactor changed nothing.
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
  nested = "auto",       -- "auto" | "kustomization" | "path"; how a file in a new subdirectory is listed
  build = {
    output = "split", -- "split" | "vsplit" | "float"
    keymaps = {      -- string, list of strings, or false to leave unmapped
      rebuild      = "R",
      next_change  = "<Tab>",
      prev_change  = "<S-Tab>",
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

## Files in a new subdirectory

Create `apps/api/deploy.yaml` under a kustomization that knows nothing about
`apps` and there are two valid ways to list it:

```yaml
resources:
  - apps                  # apps/ and apps/api/ each get a kustomization.yaml
```

```yaml
resources:
  - apps/api/deploy.yaml  # nothing else is written
```

With `nested = "auto"` the prompt leads with the form the kustomization already
uses: by path if it lists paths and no whole directories, otherwise the
directory. `"kustomization"` and `"path"` fix the choice. Either way the other
form is one key away. In the checkbox menu the line is marked `⇄` and `<Tab>`
switches it; in the yes/no prompt a third line under `s` offers it.

`:KustomizeSync` follows the same preference without asking. With paths
preferred it lists the yaml files of a directory that has no kustomization;
with directories preferred it leaves such a directory alone, since it never
creates a kustomization in a subdirectory on its own.

This only decides the case nothing else does. A directory that has its own
kustomization, or that `.resources` already lists files out of, keeps the form
it has. And where a form has nothing to offer there is no prompt: a new empty
directory can't be listed by path, so with paths preferred it is left alone
until a manifest lands in it.

### Switching a directory that is already listed

The explorer events that change what a directory *is* offer to carry the
kustomization along.

Create `deploy/kustomization.yaml`, from an explorer or by running
`:KustomizeSync` in `deploy/`, while `.resources` lists `deploy/a.yaml` and
`deploy/b.yaml`, and the prompt offers to list `deploy` whole instead. Saying
yes moves those entries into the new kustomization (as `a.yaml`, `b.yaml`) and
replaces them with `deploy` in the parent, so the build renders the same
manifests as before. It is one line in the menu, `~ deploy (replaces 2 listed
by path)`, because doing half of it would either drop manifests or name them
twice. An empty file, which is what an explorer creates, is filled in for you;
one you wrote yourself keeps its contents and gains the missing entries.

Delete `deploy/kustomization.yaml` while `deploy` is listed, and the entry can
no longer be built. The prompt offers to remove it, and `<Tab>` switches to
removing it and listing the yaml in there by path. The deleted file took its
resource list with it, so every yaml is offered; untick the ones that were
never resources.

## What counts as a resource

A yaml file or a directory in the kustomization's own directory, unless the
kustomization already reaches it some other way. These are all left alone:

- Files named under `patches`, `patchesStrategicMerge`, `patchesJson6902`,
  `crds`, `configurations`, `transformers`, `generators`, `replacements`,
  `openapi`, `helmCharts`, or a `configMapGenerator` / `secretGenerator`
  (including the `key=path` form).
- Directories listed under `components` or the older `bases`, and any directory
  whose kustomization says `kind: Component`. A component belongs under `components`; listing one as
  a resource makes `kustomize build` fail.
- Directories with no kustomization file of their own, which can't be built.
  Creating one is offered when you add the directory from an explorer.
- Anything whose name starts with a dot. `.gitlab-ci.yml` and `.github/` are
  yaml, and none of it is a manifest.
- A file that isn't yaml in a new subdirectory. A README or a script is no
  reason to offer that directory as a resource.
- Entries commented out with `# - foo`, so you can disable a resource without it
  coming back on the next sync.
- Remote refs (`https://`, `git@`, `git::`, `github.com/org/repo`), which don't
  exist on disk.
- Entries that point outside the directory or into a subdirectory, like
  `../base` or `deploy/svc.yaml`, as long as the path exists. One that no longer
  exists is removed like any other stale entry, and deleting the file in an
  explorer asks about it.
- A directory you already list files out of that way. With `deploy/svc.yaml` in
  `.resources`, `deploy` itself is never added next to them, since listing both
  names every file twice. A new file created there from an explorer is offered by its path,
  like the ones beside it, and `:KustomizeSync` adds any yaml in there that
  isn't listed yet. It stops at a subdirectory with its own kustomization,
  which goes in as one entry (`deploy/sub`).

Anything in that list that's *already* in `.resources` stays there. Sync won't
add it, and won't quietly remove it either — that's yours to fix, and the
interactive menu will toggle it off.

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
- `:KustomizeInteractiveSync` - Opens the interactive menu for the directory containing the active buffer. `<Space>` or `<CR>` toggles an entry, or opens a folded directory.
- `:KustomizeBuild` - Renders the kustomization for the active buffer's directory (or nearest parent) into a read-only window.
- `:KustomizeBuild!` - Same, but discards the stored baseline so this render becomes the new one.

## Build Window Keymaps

| Action | Default | Effect |
| --- | --- | --- |
| `rebuild` | `R` | Rebuild. Reports how far the output has moved from the baseline. |
| `next_change` / `prev_change` | `<Tab>` / `<S-Tab>` | Jump to the next / previous changed region (wraps). |
| `diff` | `d` | Diff the current render against the baseline, side by side in a new tab. |
| `set_baseline` | `D` | Set the baseline to what is currently on screen. |
| `close` | `q` | Close the build window. The diff tab reuses this key, and the two change keys. |

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

`<Tab>` / `<S-Tab>` are one keystroke on any keyboard layout, which bracket
pairs like `]c` are not. Inside the build window `<Tab>` would otherwise only
be jumplist-forward, and the window is pinned to its buffer. The build output
isn't a real diff window, so these are ordinary buffer-local mappings. The diff
tab is one: the builtin `]c` / `[c` work there, and whatever you set for
`next_change` / `prev_change` is mapped onto them, so one pair of keys walks
changes in both places.

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
