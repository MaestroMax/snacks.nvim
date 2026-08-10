---@module 'luassert'

-- Items a finder re-emits across runs carry matcher state (`match_tick`).
-- The tick only advances when the *pattern* changes, so in live mode — where the
-- pattern stays empty and every keystroke re-runs the finder — a source backed by
-- a cache or a persistent index hands back the same tables and the matcher would
-- skip them all, clearing the list instead of filling it.
describe("picker.finder", function()
  local ITEMS = {
    { text = "alpha race picker", n = 1 },
    { text = "beta docs picker", n = 2 },
    { text = "gamma race sync", n = 3 },
  }

  ---@param picker snacks.Picker
  local function shown(picker)
    local ret = {} ---@type number[]
    for _, item in ipairs(picker:items()) do
      ret[#ret + 1] = item.n
    end
    return ret
  end

  ---@param picker snacks.Picker
  local function settle(picker)
    vim.wait(50) -- let the find task start
    vim.wait(2000, function()
      return not picker:is_active()
    end)
    vim.wait(50) -- and its scheduled list update land
  end

  ---@param picker snacks.Picker
  ---@param text string
  local function search(picker, text)
    picker.input.filter.search = text
    picker:find()
    settle(picker)
  end

  it("re-matches stable item objects on every finder run", function()
    local picker = Snacks.picker.pick({
      source = "finder_spec",
      supports_live = true,
      live = true,
      focus = false,
      finder = function(_, ctx)
        local q = ctx.filter.search
        ---@async
        return function(cb)
          for _, item in ipairs(ITEMS) do -- the same tables every run, deliberately
            if q == "" or item.text:find(q, 1, true) then
              cb(item)
            end
          end
        end
      end,
    })

    settle(picker)
    assert.same({ 1, 2, 3 }, shown(picker))

    -- each of these re-emits items the previous run already matched
    search(picker, "race")
    assert.same({ 1, 3 }, shown(picker))
    search(picker, "picker")
    assert.same({ 1, 2 }, shown(picker))
    search(picker, "nope")
    assert.same({}, shown(picker))
    search(picker, "race")
    assert.same({ 1, 3 }, shown(picker))

    picker:close()
  end)
end)
