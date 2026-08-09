--- Synced local GitHub PR index for snacks.nvim: instant fuzzy search over a
--- repo's full PR history, kept current with cheap `updatedAt`-watermark deltas.
--- Registers the `gh_pr_sync` picker source.
---@class snacks-gh-sync
local M = {}

---@class snacks.picker.gh.pr_sync.Config: snacks.picker.Config
---@field repo? string GitHub repository (owner/repo). Defaults to current git repo
---@field body? boolean also index PR bodies, so previews render complete without a fetch and live queries match them. Bigger cache/sync; fuzzy matching stays title-only. Toggling triggers a full resync
---@field state? "open" | "closed" | "merged" | "all" filter by state (default: "all", unlike `gh_pr`, since full history is the point)
---@field draft? boolean filter draft PRs
---@field author? string filter by author (`@me` supported)
---@field label? string filter by label
---@field base? string filter by base branch
---@field limit? number max PRs to fetch on a full sync (default: 10000). Set above the repo's PR count for full history
---@field refresh? number min seconds between delta syncs (default: 60)
---@field timeout? number timeout in ms for a full sync (default: 10 minutes). Raise for very large repos

---@param opts snacks.picker.gh.pr_sync.Config
---@type snacks.picker.finder
function M.finder(opts, ctx)
  local Sync = require("snacks-gh-sync.sync")
  local search = ctx.filter.search
  ---@async
  return function(cb)
    local repo = opts.repo or Sync.get_repo()
    if not repo then
      Snacks.notify.error("snacks-gh-sync: failed to resolve the GitHub repo")
      return
    end

    -- config filters plus the live-mode query, evaluated locally
    local query = require("snacks-gh-sync.search").filter(opts, search)
    local emit = cb
    if query.pred then
      ---@param item snacks.picker.gh.Item
      emit = function(item)
        if query.pred(item) then
          cb(item)
        end
      end
    end

    local entry = Sync.load(repo, { body = opts.body })
    if not entry.data.synced then
      -- first sync fetches the full PR history, so wait for it (the picker shows a spinner)
      Sync.sync(repo, { body = opts.body, limit = opts.limit, timeout = opts.timeout }):wait()
      for _, item in ipairs(Sync.items(repo)) do
        emit(item)
      end
      return
    end
    if query.sort and not (query.sort.field == "updatedAt" and query.sort.desc) then
      -- a custom sort order needs the full set, so no streaming
      local items = vim.list_slice(Sync.items(repo))
      local field, desc = query.sort.field, query.sort.desc
      table.sort(items, function(a, b)
        local av, bv = a.item[field] or "", b.item[field] or ""
        if desc then
          return av > bv
        end
        return av < bv
      end)
      for _, item in ipairs(items) do
        emit(item)
      end
      return
    end
    -- stream the persisted index (most recently updated first) while it hydrates
    Sync.hydrate(repo, emit)
    -- background delta sync that refreshes the picker when something changed.
    -- The refresh-triggered finder run hits the delta debounce, so this doesn't loop.
    Sync.sync(repo, {
      body = opts.body,
      refresh = opts.refresh,
      limit = opts.limit,
      timeout = opts.timeout, -- used when a capped delta escalates to a full resync
      on_done = function(_, changed)
        if changed > 0 and not ctx.picker.closed then
          vim.schedule(function()
            ctx.picker:find({ refresh = true })
          end)
        end
      end,
    })
  end
end

--- Sync the index for a repo, e.g. from a VimEnter autocmd to prewarm:
--- `require("snacks-gh-sync").sync("NixOS/nix")`
---@param repo string
---@param opts? snacks.gh.sync.Opts
function M.sync(repo, opts)
  return require("snacks-gh-sync.sync").sync(repo, opts)
end

local did_setup = false

--- Register the `gh_pr_sync` picker source.
---@param opts? snacks.picker.gh.pr_sync.Config merged into the source defaults
function M.setup(opts)
  if did_setup then
    return
  end
  did_setup = true
  ---@type snacks.picker.gh.pr_sync.Config
  local source = vim.tbl_deep_extend("force", {
    title = "  Pull Requests (synced)",
    finder = M.finder,
    format = "gh_format",
    preview = "gh_preview",
    sort = { fields = { "score:desc", "idx" } },
    -- live mode evaluates GitHub search syntax (is:, author:, label:, base:, sort:)
    -- against the local index: same queries as `gh_pr`, no API calls
    supports_live = true,
    confirm = "gh_actions",
    win = {
      input = {
        keys = {
          ["<a-b>"] = { "gh_browse", mode = { "n", "i" } },
          ["<c-y>"] = { "gh_yank", mode = { "n", "i" } },
        },
      },
      list = {
        keys = {
          ["y"] = { "gh_yank", mode = { "n", "x" } },
        },
      },
    },
  }, opts or {})
  require("snacks.picker.config.sources").gh_pr_sync = source
end

return M
