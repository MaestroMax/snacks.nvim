---@module 'luassert'

local Item = require("snacks.gh.item")

describe("gh.sync", function()
  local repo = "snacks-test/gh-sync"
  local file = vim.fn.stdpath("cache") .. "/snacks/gh-sync/snacks-test__gh-sync__pr.json"

  local lean_fields = {
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

  local real_api = package.loaded["snacks.gh.api"]
  local queue ---@type snacks.gh.Item[][] queued responses (one per `Api.list` call)
  local calls ---@type snacks.picker.gh.list.Config[] recorded `Api.list` options

  --- Stub for `snacks.gh.api` that serves canned responses synchronously
  local api = {}

  ---@param what "issue" | "pr"
  function api.opts(what)
    return {
      type = what,
      fields = vim.deepcopy(lean_fields),
      text = { "author", "hash", "label", "title" },
      options = {},
    }
  end

  ---@param what "issue" | "pr"
  ---@param cb fun(items?: snacks.picker.gh.Item[])
  ---@param opts snacks.picker.gh.list.Config
  function api.list(what, cb, opts)
    calls[#calls + 1] = opts
    local raws = table.remove(queue, 1)
    if raws then
      local api_opts = api.opts(what)
      api_opts.fields = opts.fields or api_opts.fields
      ---@param raw snacks.gh.Item
      cb(vim.tbl_map(function(raw)
        return Item.new(vim.deepcopy(raw), api_opts)
      end, raws))
    else
      cb()
    end
    return {
      wait = function() end,
      running = function()
        return false
      end,
      did_exit = true,
    }
  end

  --- Fresh `snacks-gh-sync.sync` module with the api stub in place
  ---@return snacks-gh-sync.sync
  local function load()
    package.loaded["snacks.gh.api"] = api
    package.loaded["snacks-gh-sync.sync"] = nil
    return require("snacks-gh-sync.sync")
  end

  ---@param number number
  ---@param updated string
  ---@param title? string
  ---@return snacks.gh.Item
  local function pr(number, updated, title)
    return {
      number = number,
      title = title or ("PR #%d"):format(number),
      state = "OPEN",
      isDraft = false,
      createdAt = "2024-01-01T00:00:00Z",
      updatedAt = updated,
      url = ("https://github.com/%s/pull/%d"):format(repo, number),
      author = { login = "folke" },
      labels = {},
    }
  end

  before_each(function()
    queue, calls = {}, {}
    os.remove(file)
  end)

  after_each(function()
    package.loaded["snacks.gh.api"] = real_api
    package.loaded["snacks-gh-sync.sync"] = nil
  end)

  it("full sync builds the index and persists it", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z"), pr(2, "2024-06-02T10:00:00Z") } }

    local changed ---@type number?
    Sync.sync(repo, {
      notify = false,
      on_done = function(_, c)
        changed = c
      end,
    })

    assert.equals(2, changed)
    assert.equals(1, #calls)
    assert.equals("all", calls[1].state)
    assert.equals(10000, calls[1].limit)
    assert.is_nil(calls[1].search)
    assert.same(lean_fields, calls[1].fields)
    assert.equals(10 * 60 * 1000, calls[1].timeout)

    local items = Sync.items(repo)
    assert.equals(2, #items)
    assert.is_true(Item.is(items[1]))
    assert.equals(2, items[1].number) -- most recently updated first
    assert.equals(1, items[2].number)
    assert.equals(repo, items[1].repo)
    assert.equals("gh://" .. repo .. "/pr/2", items[1].uri)

    assert.equals("2024-06-02T10:00:00Z", Sync.load(repo).data.synced)
    assert.equals(1, vim.fn.filereadable(Sync.path(repo)))
    assert.equals(file, Sync.path(repo))
  end)

  it("reloads the persisted index from disk", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z"), pr(2, "2024-06-02T10:00:00Z", "Fix all the things") } }
    Sync.sync(repo, { notify = false })

    Sync = load() -- fresh module, so state can only come from disk
    local entry = Sync.load(repo)
    assert.equals("2024-06-02T10:00:00Z", entry.data.synced)
    assert.same(lean_fields, entry.data.fields)
    assert.equals(2, #entry.pending) -- items stay undecoded until hydration
    assert.equals(0, vim.tbl_count(entry.items))

    local items = Sync.items(repo)
    assert.equals(2, #items)
    assert.is_true(Item.is(items[1]))
    assert.equals(2, items[1].number)
    assert.equals("Fix all the things", items[1].title)
    assert.equals("folke", items[1].author)
    assert.equals("open", items[1].state)
    assert.equals("gh://" .. repo .. "/pr/2", items[1].uri)
    assert.equals(0, #entry.pending) -- fully hydrated now
    assert.equals(items[1], Sync.load(repo).items[2])
    assert.equals(1, #calls) -- only the initial full sync hit the api
  end)

  it("delta sync upserts by number and advances the watermark", function()
    local Sync = load()
    queue = {
      { pr(1, "2024-06-01T10:00:00Z"), pr(2, "2024-06-02T10:00:00Z") },
      {
        pr(3, "2024-06-03T10:00:00Z"), -- new
        pr(2, "2024-06-03T09:00:00Z", "Updated title"), -- updated
        pr(1, "2024-06-01T10:00:00Z"), -- unchanged boundary item (`>=` re-fetches it)
      },
    }
    Sync.sync(repo, { notify = false })

    local changed ---@type number?
    Sync.sync(repo, {
      notify = false,
      on_done = function(_, c)
        changed = c
      end,
    })

    assert.equals(2, changed)
    assert.equals(2, #calls)
    -- a day before the watermark: the search index lags and can index out of order
    assert.equals("updated:>=2024-06-01T10:00:00Z sort:updated-asc", calls[2].search)
    assert.equals("all", calls[2].state)
    assert.equals(1000, calls[2].limit)

    local items = Sync.items(repo)
    assert.equals(3, #items)
    assert.same(
      { 3, 2, 1 },
      vim.tbl_map(function(item)
        return item.number
      end, items)
    )
    assert.equals("Updated title", items[2].title)
    assert.equals("2024-06-03T10:00:00Z", Sync.load(repo).data.synced)

    -- the upsert was persisted
    Sync = load()
    assert.equals(3, #Sync.items(repo))
    assert.equals("2024-06-03T10:00:00Z", Sync.load(repo).data.synced)
  end)

  it("delta sync pages instead of discarding the index when it hits the cap", function()
    local Sync = load()
    local capped = {} ---@type snacks.gh.Item[]
    for i = 1, 1000 do
      capped[i] = pr(100 + i, "2024-06-03T10:00:00Z")
    end
    queue = {
      { pr(1, "2024-06-01T10:00:00Z"), pr(2, "2024-06-02T10:00:00Z") },
      capped, -- a full page: may have been truncated by the 1000-result cap
      { pr(3, "2024-06-04T10:00:00Z") },
    }
    Sync.sync(repo, { notify = false })

    local changed ---@type number?
    Sync.sync(repo, {
      notify = false,
      on_done = function(_, c)
        changed = c
      end,
    })

    assert.equals(3, #calls)
    assert.is_not_nil(calls[2].search)
    -- paged, never escalated to a full sync: that would have wiped the index
    assert.is_not_nil(calls[3].search)
    assert.equals("updated:>=2024-06-03T10:00:00Z sort:updated-asc", calls[3].search)

    assert.equals(1001, changed)
    local items = Sync.items(repo)
    assert.equals(1003, #items) -- everything kept: 2 seeded + 1000 paged + 1
    assert.is_not_nil(Sync.load(repo).items[1]) -- the pre-delta index survived
    assert.equals(3, items[1].number) -- newest first
    assert.equals("2024-06-04T10:00:00Z", Sync.load(repo).data.synced)
  end)

  it("discards a persisted index with a different version", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z") } }
    Sync.sync(repo, { notify = false })

    local fd = assert(io.open(file, "r"))
    local lines = vim.split(fd:read("*a"), "\n", { plain = true })
    fd:close()
    local header = vim.json.decode(lines[1])
    header.version = 999
    lines[1] = vim.json.encode(header)
    fd = assert(io.open(file, "w"))
    fd:write(table.concat(lines, "\n"))
    fd:close()

    Sync = load()
    local entry = Sync.load(repo)
    assert.is_nil(entry.data.synced) -- treated as never-synced
    assert.equals(0, #Sync.items(repo))
  end)

  it("hydrates the persisted index incrementally, most recent first", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z"), pr(2, "2024-06-02T10:00:00Z"), pr(3, "2024-06-03T10:00:00Z") } }
    Sync.sync(repo, { notify = false })

    Sync = load() -- fresh module, so state can only come from disk
    assert.equals(3, #Sync.load(repo).pending) -- nothing decoded yet
    local seen = {} ---@type number[]
    local entry = Sync.hydrate(repo, function(item)
      seen[#seen + 1] = item.number
    end)
    assert.same({ 3, 2, 1 }, seen) -- persisted pre-sorted by updatedAt desc
    assert.equals(0, #entry.pending)
    assert.equals(3, vim.tbl_count(entry.items))
  end)

  it("full sync limit and timeout are configurable", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z") } }
    Sync.sync(repo, { notify = false, limit = 80000, timeout = 30 * 60 * 1000 })
    assert.equals(80000, calls[1].limit)
    assert.equals(30 * 60 * 1000, calls[1].timeout)
  end)

  it("body option extends the indexed fields and toggling resyncs", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z") } }
    Sync.sync(repo, { notify = false, body = true })
    assert.is_true(vim.tbl_contains(calls[1].fields, "body"))
    assert.is_true(vim.tbl_contains(calls[1].fields, "title"))

    Sync = load() -- same option round-trips from disk
    local entry = Sync.load(repo, { body = true })
    assert.equals("2024-06-01T10:00:00Z", entry.data.synced)
    assert.equals(1, #entry.pending)

    Sync = load() -- toggling the option discards the persisted index
    entry = Sync.load(repo)
    assert.is_nil(entry.data.synced) -- treated as never-synced
    assert.equals(0, #entry.pending)
  end)

  it("records a watermark for a repo with no PRs", function()
    local Sync = load()
    queue = { {}, {} }
    Sync.sync(repo, { notify = false })
    assert.is_not_nil(Sync.load(repo).data.synced) -- else every open would full-resync

    Sync.sync(repo, { notify = false, refresh = 0 })
    assert.equals(2, #calls)
    assert.is_not_nil(calls[2].search) -- a delta, not a second full sync
  end)

  it("rebuilds the memoized index when the field set changes", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z") }, { pr(1, "2024-06-01T10:00:00Z") } }
    Sync.sync(repo, { notify = false })
    assert.is_false(vim.tbl_contains(calls[1].fields, "body"))

    -- same module instance: toggling `body` must not reuse the memoized entry
    Sync.sync(repo, { notify = false, body = true })
    assert.equals(2, #calls)
    assert.is_true(vim.tbl_contains(calls[2].fields, "body"))
    assert.is_nil(calls[2].search) -- a full resync, not a delta
  end)

  it("debounces delta syncs", function()
    local Sync = load()
    queue = { { pr(1, "2024-06-01T10:00:00Z") }, {} }
    Sync.sync(repo, { notify = false })
    Sync.sync(repo, { notify = false, refresh = 1000 }) -- first delta (empty)
    assert.equals(2, #calls)

    local changed ---@type number?
    Sync.sync(repo, {
      notify = false,
      refresh = 1000,
      on_done = function(_, c)
        changed = c
      end,
    })
    assert.equals(2, #calls) -- skipped
    assert.equals(0, changed)
  end)
end)
