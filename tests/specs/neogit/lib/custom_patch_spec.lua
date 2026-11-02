local eq = assert.are.same
local custom_patch = require("neogit.lib.custom_patch")

---@param file string
---@param header string Hunk header, e.g. "@@ -1,3 +1,3 @@"
---@param lines string[]
---@return Hunk
local function hunk(file, header, lines)
  local index_from, index_len, disk_from, disk_len = header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  return {
    file = file,
    hash = file .. header,
    line = header,
    index_from = tonumber(index_from),
    index_len = tonumber(index_len) or 1,
    disk_from = tonumber(disk_from),
    disk_len = tonumber(disk_len) or 1,
    lines = lines,
  }
end

---@param file string
---@param kind string
---@param hunks Hunk[]
---@return Diff
local function diff(file, kind, hunks)
  return { file = file, kind = kind, hunks = hunks, lines = {}, info = {}, stats = {}, pager_contents = {} }
end

---Two hunks in "file": the first replaces "b" with "B", the second replaces "p" with "P" and appends "u"
local function modified_file()
  local first = hunk("file", "@@ -1,4 +1,4 @@", { " a", "-b", "+B", " c", " d" })
  local second =
    hunk("file", "@@ -13,8 +13,9 @@", { " m", " n", " o", "-p", "+P", " q", " r", " s", " t", "+u" })
  return diff("file", "modified", { first, second }), first, second
end

---@param patch CustomPatch
---@param reverse boolean
---@return string
local function render(patch, reverse)
  return patch:to_string {
    reverse = reverse,
    whole_file = function(path)
      return { "WHOLE " .. path }
    end,
  }
end

describe("custom patch", function()
  after_each(function()
    custom_patch.reset()
  end)

  describe("selecting changes", function()
    it("starts out empty", function()
      local patch = custom_patch.new("abc")

      assert.True(patch:is_empty())
      eq("", render(patch, false))
    end)

    it("adds a whole hunk", function()
      local d, first = modified_file()
      local patch = custom_patch.new("abc")

      patch:add_lines(d, first)

      assert.False(patch:is_empty())
      assert.True(patch:contains_line(first, 2))
      assert.True(patch:contains_line(first, 3))
      assert.False(patch:contains_line(first, 1)) -- context
      eq("1 file, +1 -1", patch:summary())
    end)

    it("only adds changed lines of a range", function()
      local d, _, second = modified_file()
      local patch = custom_patch.new("abc")

      patch:add_lines(d, second, 1, 5) -- three context lines, "-p" and "+P"

      eq({ files = 1, additions = 1, deletions = 1 }, patch:stats())
      assert.False(patch:contains_line(second, 1))
      assert.True(patch:contains_line(second, 4))
      assert.False(patch:contains_line(second, 10))
    end)

    it("adds every hunk of a file", function()
      local d, first, second = modified_file()
      local patch = custom_patch.new("abc")

      patch:add_file(d)

      eq("1 file, +3 -2", patch:summary())
      assert.True(patch:contains_line(first, 3))
      assert.True(patch:contains_line(second, 10))
      assert.False(patch:contains_file("file")) -- modified files are tracked by line
    end)

    it("removes lines again", function()
      local d, first, second = modified_file()
      local patch = custom_patch.new("abc")

      patch:add_file(d)
      patch:remove_lines(d, second, 10, 10)

      eq("1 file, +2 -2", patch:summary())
      assert.False(patch:contains_line(second, 10))

      patch:remove_lines(d, first)
      patch:remove_lines(d, second)

      assert.True(patch:is_empty())
    end)

    it("removes a whole file", function()
      local d = modified_file()
      local patch = custom_patch.new("abc")

      patch:add_file(d)
      patch:remove_file(d)

      assert.True(patch:is_empty())
    end)

    for _, kind in ipairs { "new file", "deleted file", "renamed" } do
      it(("only adds a %s as a whole"):format(kind == "renamed" and "renamed file" or kind), function()
        local h = hunk("new", "@@ -0,0 +1,2 @@", { "+x", "+y" })
        local d = diff("new", kind, { h })
        local patch = custom_patch.new("abc")

        local whole = patch:add_lines(d, h, 1, 1)

        assert.True(whole)
        assert.True(patch:contains_file("new"))
        assert.True(patch:contains_line(h, 2))
        eq("1 file, +2 -0", patch:summary())

        assert.True(patch:remove_lines(d, h, 2, 2))
        assert.True(patch:is_empty())
      end)
    end

    it("adds binary files as a whole", function()
      local d = diff("image.png", "modified", {})
      local patch = custom_patch.new("abc")

      patch:add_file(d)

      assert.True(patch:contains_file("image.png"))
    end)
  end)

  describe("patch text", function()
    it("turns unselected removals into context, and leaves out unselected additions, for 'before'", function()
      local d, _, second = modified_file()
      local patch = custom_patch.new("abc")

      patch:add_lines(d, second, 5, 5) -- only "+P"

      eq(table.concat({
        "--- a/file",
        "+++ b/file",
        "@@ -13,8 +13,9 @@",
        " m",
        " n",
        " o",
        " p",
        "+P",
        " q",
        " r",
        " s",
        " t",
      }, "\n") .. "\n", render(patch, false))
    end)

    it("turns unselected additions into context, and leaves out unselected removals, for 'after'", function()
      local d, _, second = modified_file()
      local patch = custom_patch.new("abc")

      patch:add_lines(d, second, 4, 4) -- only "-p"

      eq(table.concat({
        "--- a/file",
        "+++ b/file",
        "@@ -13,10 +13,9 @@",
        " m",
        " n",
        " o",
        "-p",
        " P",
        " q",
        " r",
        " s",
        " t",
        " u",
      }, "\n") .. "\n", render(patch, true))
    end)

    it("shifts later hunks by the lines that earlier hunks add", function()
      local first = hunk("file", "@@ -1,2 +1,4 @@", { " a", "+x", "+y", " b" })
      local second = hunk("file", "@@ -10,2 +12,2 @@", { "-j", "+J", " k" })
      local d = diff("file", "modified", { first, second })
      local patch = custom_patch.new("abc")

      patch:add_lines(d, first, 2, 2) -- "+x"
      patch:add_lines(d, second)

      local before = render(patch, false)
      assert.truthy(before:find("@@ -1,2 +1,3 @@", 1, true))
      assert.truthy(before:find("@@ -10,2 +11,2 @@", 1, true))

      local after = render(patch, true)
      assert.truthy(after:find("@@ -1,3 +1,4 @@", 1, true))
      assert.truthy(after:find("@@ -11,2 +12,2 @@", 1, true))
    end)

    it("keeps a 'no newline' marker with the line it belongs to", function()
      local h = hunk("file", "@@ -1,2 +1,2 @@", { " a", "-b", "\\ No newline at end of file", "+B" })
      local d = diff("file", "modified", { h })
      local patch = custom_patch.new("abc")

      patch:add_lines(d, h, 2, 2) -- only "-b"

      eq(table.concat({
        "--- a/file",
        "+++ b/file",
        "@@ -1,2 +1,1 @@",
        " a",
        "-b",
        "\\ No newline at end of file",
      }, "\n") .. "\n", render(patch, false))
    end)

    it("uses the complete diff for whole files", function()
      local h = hunk("new", "@@ -0,0 +1 @@", { "+x" })
      local patch = custom_patch.new("abc")

      patch:add_file(diff("new", "new file", { h }))

      eq("WHOLE new\n", render(patch, false))
      eq("WHOLE new\n", render(patch, true))
    end)
  end)

  describe("current patch", function()
    it("is created on demand for a commit", function()
      assert.Nil(custom_patch.get())

      local patch = custom_patch.get_or_create("abc")
      local d = modified_file()
      patch:add_file(d)

      eq(patch, custom_patch.get())
      eq(patch, custom_patch.get_or_create("abc"))
    end)

    it("is replaced when building a patch for another commit", function()
      custom_patch.get_or_create("abc"):add_file((modified_file()))

      local other = custom_patch.get_or_create("def")

      eq("def", other.commit)
      eq(other, custom_patch.get_or_create("def"))
    end)

    it("is forgotten when it becomes empty", function()
      local patch = custom_patch.get_or_create("abc")
      local d = modified_file()

      patch:add_file(d)
      patch:remove_file(d)

      assert.Nil(custom_patch.get())
    end)

    it("can be discarded", function()
      custom_patch.get_or_create("abc"):add_file((modified_file()))
      custom_patch.reset()

      assert.Nil(custom_patch.get())
    end)
  end)
end)
