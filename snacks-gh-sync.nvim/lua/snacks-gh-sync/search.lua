--- Local evaluation of a subset of GitHub's search syntax against synced index
--- items, so live-mode queries in `gh_pr_sync` behave like `gh_pr` without API
--- calls. Only qualifiers answerable from the indexed (delta-safe) fields are
--- supported; others are reported, not silently ignored or misanswered.
---@class snacks.gh.search
local M = {}

local me ---@type string|false|nil authenticated login (memoized)

--- Resolve `@me` to the authenticated login
---@async
---@return string?
local function user()
  if me == nil then
    local u = require("snacks.gh.api").user()
    me = u and u.login or false
  end
  return me or nil
end

---@alias snacks.gh.search.Pred fun(item: snacks.picker.gh.Item): boolean

---@class snacks.gh.search.Query
---@field pred? snacks.gh.search.Pred
---@field sort? {field: "updatedAt"|"createdAt", desc: boolean}
---@field unsupported string[]

---@param preds snacks.gh.search.Pred[]
---@param neg string
---@param val snacks.gh.search.Pred
local function add(preds, neg, val)
  preds[#preds + 1] = neg == "-" and function(item)
    return not val(item)
  end or val
end

--- Parse a query into a predicate over indexed items.
--- Supported: `is:`/`state:` (open/closed/merged/draft), `author:` (incl. `@me`),
--- `label:` (quoted values ok), `base:`, `draft:`, `sort:updated/created[-asc|-desc]`,
--- `-` negation, and free text matched against the title (and body when indexed).
---@async
---@param q string
---@param opts? {body?: boolean}
---@return snacks.gh.search.Query
function M.parse(q, opts)
  local preds = {} ---@type snacks.gh.search.Pred[]
  local words = {} ---@type string[]
  local unsupported = {} ---@type string[]
  local sort ---@type {field: "updatedAt"|"createdAt", desc: boolean}?

  -- protect spaces in quoted values, e.g. label:"help wanted"
  q = q:gsub('(%-?%w+:)"([^"]*)"', function(k, v)
    return k .. v:gsub("%s", "\1")
  end)
  -- and in bare quoted phrases, e.g. "race condition"
  q = q:gsub('"([^"]*)"', function(v)
    return (v:gsub("%s", "\1"))
  end)

  for tok in q:gmatch("%S+") do
    tok = tok:gsub("\1", " ")
    local neg, key, val = tok:match("^(%-?)([%w-]+):(.*)$")
    if not key then
      words[#words + 1] = tok:lower()
    else
      key = key:lower()
      if key == "is" or key == "state" then
        local v = val:lower()
        if v == "open" or v == "closed" or v == "merged" then
          add(preds, neg, function(item)
            return item.state == v
          end)
        elseif v == "draft" and key == "is" then
          add(preds, neg, function(item)
            return item.draft == true
          end)
        elseif v ~= "pr" then
          unsupported[#unsupported + 1] = tok
        end
      elseif key == "draft" then
        local want = val:lower() ~= "false"
        add(preds, neg, function(item)
          return (item.draft == true) == want
        end)
      elseif key == "author" then
        local login = (val == "@me" and user() or val):lower()
        add(preds, neg, function(item)
          return (item.author or ""):lower() == login
        end)
      elseif key == "label" then
        local want = val:lower()
        add(preds, neg, function(item)
          for _, label in ipairs(item.item.labels or {}) do
            if (label.name or ""):lower() == want then
              return true
            end
          end
          return false
        end)
      elseif key == "base" then
        add(preds, neg, function(item)
          return item.item.baseRefName == val
        end)
      elseif key == "sort" then
        local field, dir = val:lower():match("^(%a+)%-?(%a*)$")
        if field == "updated" or field == "created" then
          sort = { field = field == "updated" and "updatedAt" or "createdAt", desc = dir ~= "asc" }
        else
          unsupported[#unsupported + 1] = tok
        end
      else
        unsupported[#unsupported + 1] = tok
      end
    end
  end

  ---@type snacks.gh.search.Pred?
  local pred
  if #preds > 0 or #words > 0 then
    local body = opts and opts.body
    ---@param item snacks.picker.gh.Item
    pred = function(item)
      for _, p in ipairs(preds) do
        if not p(item) then
          return false
        end
      end
      if #words > 0 then
        local hay = (item.title or ""):lower()
        if body and item.body then
          hay = hay .. "\n" .. item.body:lower()
        end
        for _, word in ipairs(words) do
          if not hay:find(word, 1, true) then
            return false
          end
        end
      end
      return true
    end
  end

  return { pred = pred, sort = sort, unsupported = unsupported }
end

--- Build the item filter for a `gh_pr_sync` picker run: the source's config
--- filters (state/draft/author/label/base) plus the live-mode query.
--- Unsupported qualifiers produce a warning instead of wrong results.
---@async
---@param opts snacks.picker.gh.pr_sync.Config
---@param search? string
---@return snacks.gh.search.Query
function M.filter(opts, search)
  local q = {} ---@type string[]
  if opts.state and opts.state ~= "all" then
    q[#q + 1] = "is:" .. opts.state
  end
  if opts.draft ~= nil then
    q[#q + 1] = "draft:" .. tostring(opts.draft)
  end
  for _, key in ipairs({ "author", "label", "base" }) do
    if opts[key] then
      q[#q + 1] = ('%s:"%s"'):format(key, opts[key])
    end
  end
  q[#q + 1] = search or ""
  local query = M.parse(vim.trim(table.concat(q, " ")), { body = opts.body })
  if #query.unsupported > 0 then
    Snacks.notify.warn(
      ("Qualifiers not supported by the local index (ignored):\n- `%s`"):format(
        table.concat(query.unsupported, "`\n- `")
      ),
      { title = "Snacks GH", id = "snacks_gh_sync_qualifiers" }
    )
  end
  return query
end

return M
