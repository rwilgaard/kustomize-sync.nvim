# kustomize-sync.nvim

Keeps the `resources` list in `kustomization.yaml` in step with the files on
disk. Add, delete or rename a manifest in Neo-tree or Oil and you're asked
whether to update the kustomization. Or run one command and let it sort the
list out.

```
[x] - deploy/old.yaml
[x] + deploy/new.yaml
 <Space> toggle  <CR> apply  q cancel
```

## What it does

- **Sync on demand.** `:KustomizeSync` adds what's on disk but not listed and
  drops what's listed but gone.
- **Prompts from your file explorer.** Create, delete, rename or move something
  in Neo-tree or Oil and one prompt covers the change.
- **Checkbox menu.** `:KustomizeInteractiveSync` lets you tick resources in and
  out by hand.
- **Build preview.** `:KustomizeBuild` renders `kustomize build` into a
  read-only window and shows what changed since the last render.
- **Leaves the rest alone.** Patches, generator inputs, components, remote
  refs and commented-out entries are never added or removed.

## Requirements

- Neovim 0.11 or newer
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [yq](https://github.com/mikefarah/yq) v4
- [kustomize](https://kustomize.io/), for the build preview and for creating
  new `kustomization.yaml` files

`:checkhealth kustomize-sync` tells you if something is missing.

## Install

The defaults work as they are. `setup()` needs no arguments.

<details open>
<summary>vim.pack (Neovim 0.12+)</summary>

```lua
vim.pack.add({
  "https://github.com/rwilgaard/kustomize-sync.nvim",
  "https://github.com/MunifTanjim/nui.nvim",
})

require("kustomize-sync").setup()
```
</details>

<details>
<summary>lazy.nvim</summary>

```lua
{
  "rwilgaard/kustomize-sync.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  opts = {},
}
```
</details>

## Usage

Open any file next to a `kustomization.yaml` and run:

| Command | What it does |
| --- | --- |
| `:KustomizeSync` | Sync the list with the directory. Creates the kustomization if there isn't one. |
| `:KustomizeInteractiveSync` | Checkbox menu. `<Space>` toggles an entry or opens a folded directory. |
| `:KustomizeBuild` | Preview `kustomize build` for the nearest kustomization. |
| `:KustomizeBuild!` | Same, and start a new baseline to compare against. |

With Neo-tree or Oil installed the prompts need no setup. Change files in the
explorer and answer the prompt: `y` / `n` for a single change, or the checkbox
menu when there are several.

### Explorer keymaps

To run the commands on whatever is under the cursor in the explorer, bind
them to keys. Each integration has `sync`, `interactive_sync` and `build`.

Neo-tree:

```lua
local ks = require("kustomize-sync.integrations.neo-tree")

require("neo-tree").setup({
  window = {
    mappings = {
      ["K"] = ks.sync,
      ["I"] = ks.interactive_sync,
      ["B"] = ks.build,
    },
  },
})
```

Oil:

```lua
local ks = require("kustomize-sync.integrations.oil")

require("oil").setup({
  keymaps = {
    ["K"] = { callback = ks.sync, desc = "Sync kustomization" },
    ["I"] = { callback = ks.interactive_sync, desc = "Kustomize interactive" },
    ["B"] = { callback = ks.build, desc = "Kustomize build" },
  },
})
```

The plugin has to be loadable when that `require` runs. If your explorer is
configured first, wrap the call instead:
`function(state) require("kustomize-sync.integrations.neo-tree").sync(state) end`.

## Configuration

Everything is optional. These are the defaults:

```lua
require("kustomize-sync").setup({
  sort_resources = true, -- keep .resources sorted
  format_command = nil,  -- e.g. { "yamlfmt" }, run on the file after each write
  nested = "auto",       -- "auto" | "kustomization" | "path", see below
  build = {
    output = "split",    -- "split" | "vsplit" | "float"
    keymaps = {          -- a string, a list of strings, or false to unmap
      rebuild      = "R",
      next_change  = "<Tab>",
      prev_change  = "<S-Tab>",
      diff         = "d",
      set_baseline = "D",
      close        = "q",
    },
  },
  integrations = {
    neo_tree = { enabled = true, auto_prompt_on_change = true },
    oil      = { enabled = true, auto_prompt_on_change = true },
  },
})
```

`format_command` is any tool that formats a file in place. It runs from the
kustomization's directory, so a project config such as `.yamlfmt` is picked up.

## Build preview

`:KustomizeBuild` shows the rendered manifests without writing anything. The
first render of a directory is the baseline. Edit, rebuild, and the lines that
changed are highlighted, with a count in the window's status line.

| Key | Action |
| --- | --- |
| `R` | Rebuild |
| `<Tab>` / `<S-Tab>` | Next / previous change |
| `d` | Side-by-side diff against the baseline |
| `D` | Make the current render the baseline |
| `q` | Close |

```
:KustomizeBuild   baseline captured
q                 edit your manifests
:KustomizeBuild   "± 2 hunks since baseline 14:02:11"
d                 side-by-side diff
```

The keys only apply inside the build window and its diff tab.

## Subdirectories: whole or by path

A manifest in a subdirectory can be listed two ways, and the plugin follows
whichever one a directory already uses.

```yaml
resources:
  - apps                  # apps/ has its own kustomization.yaml
  - deploy/service.yaml   # listed by path, nothing else needed
```

For a file in a brand new directory the prompt picks the style your
kustomization already leans towards and offers the other one: `<Tab>` in the
checkbox menu, `s` in the yes/no prompt. Set `nested` to `"kustomization"` or
`"path"` to always lead with one.

Entries listed by path follow their files. Rename `deploy/` and they are
rewritten; delete it and they are offered for removal. Add a
`kustomization.yaml` to a directory listed by path and you're offered to list
it whole instead.

## Never added or removed

- Files reached through `patches`, `components`, `bases`, generators and the
  other keys that name files
- Directories that are a `kind: Component`
- Names starting with a dot, such as `.gitlab-ci.yml`
- Entries you commented out with `# - name`
- Remote refs (`https://`, `git@`, `github.com/org/repo`)
- Entries pointing elsewhere, like `../base`, as long as the path exists

## More

`:help kustomize-sync` has the details: how each prompt decides, formatting,
the build window, and every option.

## License

MIT
