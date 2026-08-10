local Api = require("snacks.gh.api")
local Async = require("snacks.picker.util.async")
local Item = require("snacks.gh.item")

---@class snacks.gh.sync
local M = {}

local uv = vim.uv or vim.loop

--- Lean field set for the synced index. Excludes the expensive fields and `body`/`id`;
--- `Api.view`'s `need()` back-fills anything missing when a PR is opened.
local LEAN_FIELDS = {
  "author",
  "baseRefName",
  "closedAt",
  "createdAt",
  "isDraft",
  "labels",
  "mergedAt",
  "number",
  "state",
  "title",
  "updatedAt",
  "url",
}

local VERSION = 2 -- bump to invalidate persisted indexes
local DELTA_LIMIT = 1000 -- the GitHub search API caps any query at 1000 results
-- resolved at module load, so `M.path` is safe in fast events
local CACHE_DIR = vim.fn.stdpath("cache") .. "/snacks/gh-sync"

--- Persisted as one JSON line per item (sorted by `updatedAt` desc), preceded by a header line,
--- so loading can decode and wrap items incrementally instead of in one blocking call.
---@class snacks.gh.sync.Data
---@field version number
---@field repo string GitHub repository (owner/repo)
---@field type "pr"
---@field synced? string ISO-8601 `updatedAt` watermark of the last sync
---@field fields string[] fields the items were fetched with

---@class snacks.gh.sync.Entry
---@field data snacks.gh.sync.Data persisted header
---@field items table<number, snacks.picker.gh.Item> hydrated items by PR number
---@field list snacks.picker.gh.Item[] hydrated items, sorted by `updatedAt` desc unless `dirty`
---@field dirty? boolean whether `list` needs a re-sort
---@field enc table<number, string> encoded line per PR number (avoids re-encoding unchanged items on save)
---@field pending string[] undecoded item lines from disk
---@field pi? number cursor into `pending`
---@field hydrating? boolean

---@class snacks.gh.sync.Opts
---@field body? boolean also index PR bodies. Bigger cache/sync; matching stays title-only. Toggling triggers a full resync
---@field force? boolean force a full sync
---@field limit? number max PRs to fetch on a full sync (default: 10000). Set above the repo's PR count for full history
---@field refresh? number min seconds between delta syncs (default: 60)
---@field timeout? number timeout in ms for a full sync (default: 10 minutes). Raise for very large repos
---@field notify? boolean show notifications for full syncs (default: true)
---@field on_done? fun(entry: snacks.gh.sync.Entry, changed: number)

---@class snacks.gh.sync.Handle: snacks.picker.Waitable
---@field active fun(): boolean whether the sync is still in-flight

local indexes = {} ---@type table<string, snacks.gh.sync.Entry>
local syncing = {} ---@type table<string, snacks.gh.sync.Handle>
local last_delta = {} ---@type table<string, number> last delta sync per repo (`uv.now()` ms)
local repos = {} ---@type table<string, string|false> resolved repo per git root

--- Run `fn` on the main loop when called from a fast event (proc exit), directly otherwise.
---@param fn fun()
local function schedule(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

--- The fields to index. Only delta-safe fields are eligible: editing a body bumps
--- `updatedAt`, so the watermark sees it, while `mergeable`, `statusCheckRollup` etc.
--- change without bumping it and must stay on-demand (`Api.view`) to render fresh.
---@param opts? snacks.gh.sync.Opts
local function fields_for(opts)
  local ret = vim.deepcopy(LEAN_FIELDS)
  if opts and opts.body then
    table.insert(ret, "body")
    table.sort(ret)
  end
  return ret
end

--- Api options used to wrap raw items, with the indexed field set,
--- so `need()` is accurate for cache-restored items.
---@param entry snacks.gh.sync.Entry
---@return snacks.gh.api.Config
local function api_opts(entry)
  local ret = Api.opts("pr", "list")
  ret.fields = vim.deepcopy(entry.data.fields)
  return ret
end

---@param entry snacks.gh.sync.Entry
local function sorted(entry)
  if entry.dirty then
    -- ISO-8601 `Z` timestamps compare lexicographically
    table.sort(entry.list, function(a, b)
      return (a.item.updatedAt or "") > (b.item.updatedAt or "")
    end)
    entry.dirty = nil
  end
  return entry.list
end

--- Path of the persisted index for a repo
---@param repo string
function M.path(repo)
  return CACHE_DIR .. "/" .. repo:gsub("/", "__") .. "__pr.json"
end

--- Load the index header for a repo. Cheap: items stay as undecoded lines
--- until `M.hydrate` (or `M.items`) processes them. A persisted index with
--- a different version or field set is discarded (treated as never-synced).
---@param repo string
---@param opts? snacks.gh.sync.Opts picks the indexed field set on first load
---@return snacks.gh.sync.Entry
function M.load(repo, opts)
  if indexes[repo] then
    return indexes[repo]
  end
  ---@type snacks.gh.sync.Entry
  local entry = {
    data = { version = VERSION, repo = repo, type = "pr", fields = fields_for(opts) },
    items = {},
    list = {},
    enc = {},
    pending = {},
  }
  indexes[repo] = entry
  local fd = io.open(M.path(repo), "r")
  if not fd then
    return entry
  end
  local raw = fd:read("*a")
  fd:close()
  local lines = vim.split(raw, "\n", { plain = true })
  local ok, header = pcall(vim.json.decode, lines[1] or "")
  ---@cast header snacks.gh.sync.Data
  if
    not ok
    or type(header) ~= "table"
    or header.version ~= VERSION
    or not vim.deep_equal(header.fields, entry.data.fields)
  then
    return entry -- stale format
  end
  entry.data.synced = type(header.synced) == "string" and header.synced or nil
  table.remove(lines, 1)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  entry.pending = lines
  return entry
end

--- Hydrate the index for a repo, decoding and wrapping pending items in small
--- cooperative chunks (yielding in async contexts). `cb` receives every item,
--- most recently updated first, as soon as it is available — already-hydrated
--- items immediately, pending ones as they are decoded.
---@param repo string
---@param cb? fun(item: snacks.picker.gh.Item)
---@return snacks.gh.sync.Entry
function M.hydrate(repo, cb)
  local entry = M.load(repo)
  while entry.hydrating do -- another hydration is streaming; wait for it to finish
    if Async.running() then
      Async.sleep(10)
    else
      vim.wait(10)
    end
  end
  if not entry.pending[entry.pi or 1] then
    entry.pending, entry.pi = {}, nil
    if cb then
      for _, item in ipairs(sorted(entry)) do
        cb(item)
      end
    end
    return entry
  end
  entry.hydrating = true
  local ok, err = pcall(function()
    if cb then
      for _, item in ipairs(entry.list) do
        cb(item)
      end
    end
    local aopts, yield = api_opts(entry), Async.yielder()
    while true do
      local line = entry.pending[entry.pi or 1]
      if not line then
        break
      end
      entry.pi = (entry.pi or 1) + 1
      local lok, raw = pcall(vim.json.decode, line)
      if lok and type(raw) == "table" and raw.number and not entry.items[raw.number] then
        local item = Item.new(raw, aopts)
        entry.items[raw.number] = item
        entry.list[#entry.list + 1] = item
        entry.enc[raw.number] = line
        if cb then
          cb(item)
        end
      end
      yield()
    end
    entry.pending, entry.pi = {}, nil
  end)
  entry.hydrating = false
  if not ok then
    error(err, 0) -- re-raise aborts; the cursor keeps partial progress
  end
  return entry
end

--- Indexed items for a repo, sorted by `updatedAt` desc (most recently updated first).
--- Hydrates the index when needed.
---@param repo string
---@return snacks.picker.gh.Item[]
function M.items(repo)
  return sorted(M.hydrate(repo))
end

--- Atomically persist an index to disk. The entry must be fully hydrated.
---@param entry snacks.gh.sync.Entry
function M.save(entry)
  local path = M.path(entry.data.repo)
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fd = assert(io.open(path .. ".tmp", "w"), "failed to open `" .. path .. ".tmp`")
    assert(fd:write(vim.json.encode(entry.data), "\n"))
    for _, item in ipairs(sorted(entry)) do
      local nr = item.item.number
      entry.enc[nr] = entry.enc[nr] or vim.json.encode(item.item)
      assert(fd:write(entry.enc[nr], "\n"))
    end
    fd:close()
    assert(uv.fs_rename(path .. ".tmp", path)) -- os.rename cannot replace an existing file on Windows
  end)
  if not ok then
    Snacks.notify.error(("Failed to save the `gh` index for `%s`:\n%s"):format(entry.data.repo, err), {
      title = "Snacks GH",
      once = true,
    })
  end
end

--- Upsert items into the index and advance the watermark.
--- A full snapshot replaces the index (which also purges deleted PRs).
---@param entry snacks.gh.sync.Entry
---@param items snacks.picker.gh.Item[]
---@param full? boolean
---@return number changed
local function apply(entry, items, full)
  local changed = 0
  if full then
    entry.items, entry.list, entry.enc, entry.pending, entry.pi, entry.data.synced = {}, {}, {}, {}, nil, nil
  end
  for _, item in ipairs(items) do
    if item.number then
      local prev = entry.items[item.number]
      if not (prev and prev.item.updatedAt == item.item.updatedAt) then
        if prev then
          for i, it in ipairs(entry.list) do
            if it == prev then
              entry.list[i] = item
              break
            end
          end
        else
          entry.list[#entry.list + 1] = item
        end
        entry.items[item.number] = item
        entry.enc[item.number] = nil -- re-encode on the next save
        changed = changed + 1
      end
      local updated = item.item.updatedAt
      if updated and (not entry.data.synced or updated > entry.data.synced) then
        entry.data.synced = updated
      end
    end
  end
  entry.dirty = entry.dirty or changed > 0
  return changed
end

--- Sync the PR index for a repo:
--- * full sync when never synced (or with `opts.force`), using `gh pr list --state all`,
---   since the search API caps any query at 1000 results
--- * cheap delta otherwise, searching for PRs updated since the `updatedAt` watermark.
---   `>=` re-fetches the boundary item; upserts by number make that idempotent.
---   A delta hitting the cap falls back to a full sync.
--- Returns the in-flight handle when a sync for the repo is already running.
---@param repo string
---@param opts? snacks.gh.sync.Opts
---@return snacks.gh.sync.Handle
function M.sync(repo, opts)
  opts = opts or {}

  local inflight = syncing[repo]
  if inflight and inflight.active() then
    return inflight
  end

  local entry = M.load(repo, opts)
  local notify = opts.notify ~= false
  local procs = {} ---@type snacks.spawn.Proc[]
  local finishing = false

  ---@type snacks.gh.sync.Handle
  local handle = {
    active = function()
      if finishing then
        return true
      end
      for _, proc in ipairs(procs) do
        if proc:running() or not proc.did_exit then
          return true
        end
      end
      return #procs == 0
    end,
    ---@async
    wait = function()
      local i = 1
      while procs[i] do
        procs[i]:wait()
        i = i + 1
      end
    end,
  }

  --- Run `fn` (disk writes, notifications) and `opts.on_done` outside of fast events
  ---@param changed number
  ---@param fn? fun()
  local function finish(changed, fn)
    finishing = true
    schedule(function()
      if fn then
        fn()
      end
      syncing[repo] = nil
      if opts.on_done then
        opts.on_done(entry, changed)
      end
    end)
  end

  ---@param full? boolean
  local function start(full)
    if full and notify then
      Snacks.notify(("Syncing all pull requests for `%s` …"):format(repo), { title = "Snacks GH" })
    end
    ---@param items? snacks.picker.gh.Item[]
    procs[#procs + 1] = Api.list("pr", function(items)
      if not items then
        return finish(0)
      elseif not full and #items >= DELTA_LIMIT then
        -- the search cap may have truncated the delta, so sync everything instead
        return start(true)
      end
      local changed = apply(entry, items, full)
      if changed == 0 and not full then
        return finish(0)
      end
      finish(changed, function()
        M.save(entry)
        if full and notify then
          Snacks.notify(("Synced %d pull requests for `%s`"):format(changed, repo), { title = "Snacks GH" })
        end
      end)
    end, {
      repo = repo,
      state = "all",
      limit = full and (opts.limit or 10000) or DELTA_LIMIT,
      search = not full and ("updated:>=%s sort:updated-desc"):format(entry.data.synced) or nil,
      fields = vim.deepcopy(entry.data.fields),
      -- a full sync of thousands of PRs can take minutes
      timeout = full and (opts.timeout or 10 * 60 * 1000) or 60 * 1000,
    })
  end

  local full = opts.force or not entry.data.synced
  if not full then
    -- debounce deltas
    local now = uv.now()
    if last_delta[repo] and now - last_delta[repo] < (opts.refresh or 60) * 1000 then
      if opts.on_done then
        schedule(function()
          opts.on_done(entry, 0)
        end)
      end
      return handle
    end
    last_delta[repo] = now
    M.hydrate(repo) -- delta upserts (and saves) need the complete index
  end

  syncing[repo] = handle
  start(full)
  return handle
end

--- Resolve the GitHub repo (owner/repo) for the current git root
---@async
---@return string?
function M.get_repo()
  local root = Snacks.git.get_root(uv.cwd() or ".") or uv.cwd() or "."
  local repo = repos[root]
  if repo == nil then
    local out = Api.cmd_sync({
      args = { "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" },
      notify = false,
    })
    repo = out and vim.trim(out) or false
    repos[root] = repo
  end
  return repo or nil
end

return M
