# snacks-gh-sync.nvim

Instant fuzzy search over a GitHub repo's **entire PR history** for
[snacks.nvim](https://github.com/folke/snacks.nvim)'s picker.

The stock `gh_pr` picker either live-searches the API on every keystroke
(slow on big repos) or fuzzy-matches only the last `--limit` PRs. This plugin
keeps a **synced local index**: one full `gh pr list` fetch, persisted to
`stdpath("cache")`, then kept current with cheap `updatedAt`-watermark delta
syncs. Every keystroke is pure local fuzzy matching.

Measured on `python/cpython` (75k PRs): first results paint in **~77ms**,
full corpus searchable while hydration streams in cooperatively. A quiet
repo's per-session sync cost is a single API request.

## Requirements

- [snacks.nvim](https://github.com/folke/snacks.nvim) with the `gh` list
  field/timeout override patches (PR pending upstream; until merged, use a
  fork that includes them: `Api.opts()`, `M.list` `opts.fields`/`opts.timeout`)
- The [`gh` CLI](https://cli.github.com/), authenticated

## Install (lazy.nvim)

For now this plugin lives as a subfolder of the snacks.nvim fork that carries
its upstream prerequisites — point lazy at the folder:

```lua
{
  "MaestroMax/snacks.nvim", -- fork with the gh list field/timeout patches
  { dir = vim.fn.stdpath("data") .. "/lazy/snacks.nvim/snacks-gh-sync.nvim",
    dependencies = { "snacks.nvim" },
    opts = {}, -- calls setup(), registering the gh_pr_sync picker source
  },
}
```

Once split into its own repository (`git subtree split --prefix=snacks-gh-sync.nvim`):

```lua
{
  "MaestroMax/snacks-gh-sync.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
}
```

## Usage

```lua
Snacks.picker.gh_pr_sync()                          -- current repo
Snacks.picker.gh_pr_sync({ repo = "NixOS/nix" })    -- explicit repo
Snacks.picker.gh_pr_sync({ state = "open" })        -- stock gh_pr default view
```

First open runs the full sync behind the picker spinner (about a minute per
10k PRs). Prewarm it from your config instead:

```lua
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    require("snacks-gh-sync").sync("NixOS/nix")
  end,
})
```

Toggle the picker's **live mode** to use GitHub search syntax, evaluated
locally with zero API calls: `is:open`, `author:@me`, `label:"help wanted"`,
`base:main`, `draft:false`, `sort:created-asc`, `-` negation, free text over
titles (and bodies with `body = true`). Qualifiers the index can't answer
(`review:`, `involves:`, ...) warn instead of returning silently wrong
results.

The two modes match differently, by design:

| mode | matching | ranking + highlights |
| ---- | -------- | -------------------- |
| normal (default) | snacks fuzzy over author, `#number`, labels, title | yes |
| live (toggled) | GitHub qualifiers + substring, like GitHub itself | no |

The picker feeds live input to the finder rather than to the matcher, so live
mode is deliberately GitHub-shaped: qualifiers filter, free text matches as a
plain substring. Stay in normal mode for fuzzy search over the whole history;
switch to live when you want `is:open author:@me` semantics. Config filters
(`state`, `author`, `label`, `base`, `draft`) apply in **both** modes, so the
common cases need no typing at all.

## Options

| option    | default | description |
| --------- | ------- | ----------- |
| `repo`    | current git repo | GitHub repository (owner/repo) |
| `body`    | `false` | index PR bodies: complete previews, live queries match bodies; bigger cache/sync |
| `state`   | `"all"` | `open`/`closed`/`merged`/`all` (full history is the point) |
| `draft`   | `nil`   | filter draft PRs |
| `author`  | `nil`   | filter by author (`@me` supported) |
| `label`   | `nil`   | filter by label |
| `base`    | `nil`   | filter by base branch |
| `limit`   | `10000` | max PRs on a full sync; set above the repo's PR count |
| `refresh` | `60`    | min seconds between delta syncs |
| `timeout` | `600000`| full-sync timeout in ms; raise for very large repos |

## Design notes

- **Full sync** uses plain `gh pr list --state all` (the search API caps any
  query at 1,000 results); **deltas** search `updated:>=<watermark>` where the
  watermark is the max `updatedAt` seen — clock-skew proof, idempotent at the
  boundary. A delta hitting the cap falls back to a full resync.
- Only **delta-safe fields** are indexed. `mergeable`, CI status and reactions
  change without bumping `updatedAt`, so they stay on-demand (`Api.view`) —
  the only way those badges are ever fresh.
- The cache is **plaintext JSON** under `stdpath("cache")/snacks/gh-sync/`,
  one line per item, pre-sorted for streaming hydration. Private-repo metadata
  (titles, authors, labels) lands there too — same exposure class as `gh`'s
  own cache. Deleted PRs linger until a `force` resync.

## Tests

```sh
nvim -l tests/minit.lua --busted tests
```

Set `SNACKS_DIR=/path/to/snacks.nvim` to test against a local snacks checkout.
