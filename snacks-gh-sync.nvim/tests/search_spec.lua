---@module 'luassert'

describe("gh.search", function()
  local real_api = package.loaded["snacks.gh.api"]

  before_each(function()
    package.loaded["snacks.gh.api"] = {
      user = function()
        return { login = "octocat" }
      end,
    }
    package.loaded["snacks-gh-sync.search"] = nil
  end)

  after_each(function()
    package.loaded["snacks.gh.api"] = real_api
    package.loaded["snacks-gh-sync.search"] = nil
  end)

  ---@return snacks-gh-sync.search
  local function search()
    return require("snacks-gh-sync.search")
  end

  ---@param o table
  ---@return snacks.picker.gh.Item
  local function item(o)
    return setmetatable({
      state = o.state or "open",
      draft = o.draft or false,
      author = o.author or "folke",
      title = o.title or "fix: something",
      body = o.body,
      item = {
        labels = o.labels or {},
        baseRefName = o.base or "main",
        updatedAt = o.updated or "2024-06-01T10:00:00Z",
        createdAt = o.created or "2024-01-01T10:00:00Z",
      },
    }, { __index = function() end }) --[[@as snacks.picker.gh.Item]]
  end

  it("filters by state", function()
    local q = search().parse("is:merged")
    assert.is_true(q.pred(item({ state = "merged" })))
    assert.is_false(q.pred(item({ state = "open" })))
    assert.same({}, q.unsupported)
  end)

  it("supports negation and quoted labels", function()
    local q = search().parse('-label:"help wanted" is:open')
    assert.is_true(q.pred(item({})))
    assert.is_false(q.pred(item({ labels = { { name = "Help Wanted" } } })))
    assert.is_false(q.pred(item({ state = "closed" })))
  end)

  it("resolves author:@me", function()
    local q = search().parse("author:@me")
    assert.is_true(q.pred(item({ author = "octocat" })))
    assert.is_false(q.pred(item({ author = "folke" })))
  end)

  it("filters by base branch", function()
    local q = search().parse("base:release-1.0")
    assert.is_true(q.pred(item({ base = "release-1.0" })))
    assert.is_false(q.pred(item({})))
  end)

  it("matches free text on title, and body only when indexed", function()
    local it1 = item({ title = "fix: locking bug", body = "the mutex was held" })
    assert.is_true(search().parse("locking").pred(it1))
    assert.is_false(search().parse("mutex").pred(it1))
    assert.is_true(search().parse("mutex", { body = true }).pred(it1))
    assert.is_false(search().parse("mutex locking missing", { body = true }).pred(it1))
  end)

  it("matches quoted free-text phrases", function()
    local it1 = item({ title = "fix: race condition in the scheduler" })
    assert.is_true(search().parse('"race condition"').pred(it1))
    assert.is_false(search().parse('"condition race"').pred(it1))
  end)

  it("parses sort and collects unsupported qualifiers", function()
    local q = search().parse("sort:created-asc review:approved involves:me fix")
    assert.same({ field = "createdAt", desc = false }, q.sort)
    assert.same({ "review:approved", "involves:me" }, q.unsupported)
    assert.is_true(q.pred(item({ title = "fix: something" })))
  end)

  it("composes config filters with the query", function()
    local q = search().filter({ state = "open", label = "bug" }, "lock")
    assert.is_true(q.pred(item({ title = "fix lock", labels = { { name = "bug" } } })))
    assert.is_false(q.pred(item({ title = "fix lock", labels = { { name = "bug" } }, state = "merged" })))
    assert.is_false(q.pred(item({ title = "fix lock" })))
    assert.is_nil(search().filter({}, "").pred) -- no filters, no predicate
  end)
end)
