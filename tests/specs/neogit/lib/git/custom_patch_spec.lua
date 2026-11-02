local eq = assert.are.same
local neogit = require("neogit")
local util = require("tests.util.util")
local git = require("neogit.lib.git")
local custom_patch = require("neogit.lib.custom_patch")

neogit.setup {}

---@param cmd string[]
---@return string
local function run(cmd)
  return vim.trim(util.system(cmd))
end

---@param rev string
---@return string
local function oid(rev)
  return run { "git", "rev-parse", rev }
end

---@param rev string
---@param path string
---@return string
local function show(rev, path)
  return util.system { "git", "show", rev .. ":" .. path }
end

---@return string[] subjects of all commits on HEAD, oldest first
local function subjects()
  return vim.split(run { "git", "log", "--reverse", "--format=%s" }, "\n", { trimempty = true })
end

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.writefile(lines, path)
end

---@param message string
local function commit(message)
  run { "git", "add", "--all" }
  run { "git", "commit", "--quiet", "--message", message }
end

local function refresh_repo()
  local done = false
  git.repo:dispatch_refresh {
    source = "test",
    callback = function()
      done = true
    end,
  }
  vim.wait(5000, function()
    return done
  end)
end

local alphabet = vim.split("abcdefghijklmnopqrst", "")

---Creates a repository with three commits:
--- - "base" adds `f.txt` with the lines "a" to "t"
--- - "change" replaces "b" with "B" and "p" with "P" in `f.txt`, and is authored by someone else
--- - "later" adds `h.txt`
local function prepare_repository()
  local working_dir = util.create_temp_dir("custom-patch")
  vim.api.nvim_set_current_dir(working_dir)
  run { "git", "init", "--quiet", "--initial-branch=master" }
  run { "git", "config", "user.email", "test@neogit-test.test" }
  run { "git", "config", "user.name", "Neogit Test" }

  write("f.txt", alphabet)
  commit("base")

  local changed = vim.deepcopy(alphabet)
  changed[2] = "B"
  changed[16] = "P"
  write("f.txt", changed)
  run { "git", "add", "f.txt" }
  run {
    "git",
    "commit",
    "--quiet",
    "--author",
    "Someone Else <someone@example.com>",
    "--date",
    "2001-02-03T04:05:06+01:00",
    "--message",
    "change\n\nWith a body.",
  }

  write("h.txt", { "h" })
  commit("later")

  require("neogit.lib.git.repository").instance(working_dir)
  refresh_repo()
end

---@param rev string
---@return Diff[]
local function diffs(rev)
  return git.log.parse(git.cli.show.format("fuller").args(rev).call({ trim = false }).stdout)[1].diffs
end

---Builds a patch from the changed lines of `rev` that are listed in `lines`, such as { "-p", "+P" }
---@param rev string
---@param lines string[]
---@return CustomPatch
local function patch_of(rev, lines)
  local patch = custom_patch.new(oid(rev))

  for _, diff in ipairs(diffs(rev)) do
    for _, hunk in ipairs(diff.hunks) do
      for index, line in ipairs(hunk.lines) do
        if vim.tbl_contains(lines, line) then
          patch:add_lines(diff, hunk, index, index)
        end
      end
    end
  end

  assert.False(patch:is_empty())
  return patch
end

---@param rev string
---@return CustomPatch
local function whole_patch_of(rev)
  local patch = custom_patch.new(oid(rev))
  for _, diff in ipairs(diffs(rev)) do
    patch:add_file(diff)
  end

  return patch
end

---@param patch CustomPatch
---@return CustomPatchText
local function text(patch)
  return git.custom_patch.patch_text(patch)
end

---@return string
local function status()
  -- Not trimmed: the leading space of " M" is significant
  return (util.system({ "git", "status", "--porcelain" }):gsub("\n$", ""))
end

---@param from string
---@param to string
---@return string
local function diff_between(from, to)
  return run { "git", "diff", "--no-color", "--unified=0", from, to }
end

---@param expected string[] lines of f.txt
---@return string
local function f(expected)
  return table.concat(expected, "\n") .. "\n"
end

local with_p = vim.deepcopy(alphabet)
with_p[2] = "B" -- "change" without its "p" -> "P" part
local with_bp = vim.deepcopy(alphabet)
with_bp[2] = "B"
with_bp[16] = "P"
local with_P_only = vim.deepcopy(alphabet)
with_P_only[16] = "P"

describe("git custom patch", function()
  before_each(function()
    prepare_repository()
  end)

  describe("remove_from_commit", function()
    it("removes the patch from the commit, the index and the working tree", function()
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq(nil, err)
      eq(oid("HEAD"), result.head)
      eq({ "base", "change", "later" }, subjects())
      eq(f(with_p), show("HEAD~1", "f.txt"))
      eq(f(with_p), show("HEAD", "f.txt"))
      eq(f(with_p), table.concat(vim.fn.readfile("f.txt"), "\n") .. "\n")
      eq("", status())
    end)

    it("keeps author, date and message of rewritten commits", function()
      local before = run { "git", "log", "-1", "--format=%an <%ae> %ad%n%B", "--date=raw", "HEAD~1" }
      local patch = patch_of("HEAD~1", { "+P" })

      git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq(before, run { "git", "log", "-1", "--format=%an <%ae> %ad%n%B", "--date=raw", "HEAD~1" })
    end)

    it("reports the rewritten commits", function()
      local change, later = oid("HEAD~1"), oid("HEAD")
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq({ [change] = oid("HEAD~1"), [later] = oid("HEAD") }, result.commits)
    end)

    it("adds an entry to the reflog", function()
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      git.custom_patch.remove_from_commit(patch.commit, text(patch))

      assert.truthy(run({ "git", "reflog", "-1", "--format=%gs" }):match("^neogit: remove custom patch from"))
    end)

    it("drops the commit when it becomes empty", function()
      local patch = whole_patch_of("HEAD~1")

      local change = patch.commit
      local result = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq({ "base", "later" }, subjects())
      eq(false, result.commits[change])
      eq(f(alphabet), show("HEAD", "f.txt"))
    end)

    it("refuses when uncommitted changes conflict with the patch, without changing anything", function()
      local head = oid("HEAD")
      local local_changes = vim.deepcopy(with_bp)
      local_changes[16] = "P!"
      write("f.txt", local_changes)
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq(nil, result)
      eq("Uncommitted changes conflict with the patch", err)
      eq(head, oid("HEAD"))
      eq(f(local_changes), table.concat(vim.fn.readfile("f.txt"), "\n") .. "\n")
    end)

    it("keeps unrelated uncommitted changes", function()
      write("h.txt", { "h", "local" })
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq({ "h", "local" }, vim.fn.readfile("h.txt"))
      eq(" M h.txt", status())
    end)

    it("refuses when a later commit changed the same lines, without changing anything", function()
      local changed = vim.deepcopy(with_bp)
      changed[16] = "P2"
      write("f.txt", changed)
      commit("conflicting")
      local head = oid("HEAD")
      local patch = patch_of("HEAD~2", { "-p", "+P" })

      local result, err = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq(nil, result)
      assert.truthy(err:match("^The patch does not apply to"))
      eq(head, oid("HEAD"))
      eq("", status())
    end)

    it("refuses to rewrite merge commits", function()
      run { "git", "checkout", "--quiet", "-b", "side", "HEAD~1" }
      write("side.txt", { "side" })
      commit("side")
      run { "git", "checkout", "--quiet", "master" }
      run { "git", "merge", "--quiet", "--no-ff", "--no-edit", "side" }
      refresh_repo()
      local head = oid("HEAD")
      local patch = patch_of("master~2", { "-p", "+P" })

      local result, err = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq(nil, result)
      assert.truthy(err:match("merge commits"))
      eq(head, oid("HEAD"))
    end)

    it("refuses commits that are not part of the current branch", function()
      local patch = patch_of("HEAD~1", { "-p", "+P" })
      run { "git", "checkout", "--quiet", "-b", "other", "HEAD~2" }
      refresh_repo()

      local result, err = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      eq(nil, result)
      assert.truthy(err:match("is not part of the current branch"))
    end)

    it("works with a detached HEAD", function()
      run { "git", "checkout", "--quiet", "--detach" }
      refresh_repo()
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result = git.custom_patch.remove_from_commit(patch.commit, text(patch))

      assert.truthy(result)
      eq(f(with_p), show("HEAD", "f.txt"))
      eq(f(with_bp), show("master", "f.txt"))
    end)
  end)

  describe("move_to_index", function()
    it("removes the patch from the commit and leaves it staged", function()
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.move_to_index(patch.commit, text(patch))

      eq(nil, err)
      assert.truthy(result)
      eq(f(with_p), show("HEAD~1", "f.txt"))
      eq(f(with_p), show("HEAD", "f.txt"))
      eq("M  f.txt", status())
      eq(f(with_bp), show(":0", "f.txt"))
    end)
  end)

  describe("move_to_new_commit", function()
    it("splits the patch into a new commit after the original one", function()
      local tree = oid("HEAD^{tree}")
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.move_to_new_commit(patch.commit, text(patch), "split\n")

      eq(nil, err)
      assert.truthy(result)
      eq({ "base", "change", "split", "later" }, subjects())
      eq(tree, oid("HEAD^{tree}"))
      eq(f(with_p), show("HEAD~2", "f.txt"))
      eq(f(with_bp), show("HEAD~1", "f.txt"))
      eq("", status())
    end)

    it("uses the original author for the new commit", function()
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      git.custom_patch.move_to_new_commit(patch.commit, text(patch), "split\n")

      eq("Someone Else <someone@example.com>", run { "git", "log", "-1", "--format=%an <%ae>", "HEAD~1" })
    end)

    it("splits a whole new file out of a commit", function()
      write("new.txt", { "one", "two" })
      write("h.txt", { "h", "changed" })
      commit("both")
      local patch = custom_patch.new(oid("HEAD"))
      for _, diff in ipairs(diffs("HEAD")) do
        if diff.file == "new.txt" then
          patch:add_lines(diff, diff.hunks[1], 1, 1)
        end
      end

      git.custom_patch.move_to_new_commit(patch.commit, text(patch), "new file\n")

      eq({ "base", "change", "later", "both", "new file" }, subjects())
      eq("h.txt", run { "git", "show", "--format=", "--name-only", "HEAD~1" })
      eq("new.txt", run { "git", "show", "--format=", "--name-only", "HEAD" })
    end)

    it("splits a renamed file out of a commit as a whole", function()
      run { "git", "mv", "f.txt", "g.txt" }
      write("h.txt", { "h", "changed" })
      commit("rename")
      local patch = custom_patch.new(oid("HEAD"))
      for _, diff in ipairs(diffs("HEAD")) do
        if diff.kind == "renamed" then
          patch:add_file(diff)
        end
      end
      assert.False(patch:is_empty())

      local result, err = git.custom_patch.move_to_new_commit(patch.commit, text(patch), "rename f\n")

      eq(nil, err)
      assert.truthy(result)
      eq({ "base", "change", "later", "rename", "rename f" }, subjects())
      eq("h.txt", run { "git", "show", "--format=", "--name-only", "HEAD~1" })
      eq("R100\tf.txt\tg.txt", run { "git", "show", "--format=", "--name-status", "-M", "HEAD" })
    end)

    it("splits a root commit", function()
      local root = oid("HEAD~2")
      local patch = custom_patch.new(root)
      for _, diff in ipairs(diffs(root)) do
        patch:add_lines(diff, diff.hunks[1], 1, 1) -- "+a" of the new file f.txt, which means the whole file
      end

      local result, err = git.custom_patch.move_to_new_commit(patch.commit, text(patch), "f\n")

      eq(nil, err)
      assert.truthy(result)
      -- The root commit became empty and was dropped
      eq({ "f", "change", "later" }, subjects())
    end)
  end)

  describe("move_to_commit", function()
    it("moves the patch into an older commit", function()
      local tree = oid("HEAD^{tree}")
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.move_to_commit(patch.commit, text(patch), oid("HEAD~2"))

      eq(nil, err)
      assert.truthy(result)
      eq({ "base", "change", "later" }, subjects())
      eq(tree, oid("HEAD^{tree}"))
      eq(f(with_P_only), show("HEAD~2", "f.txt"))
      eq(f(with_bp), show("HEAD~1", "f.txt"))
      eq("", status())
    end)

    it("moves the patch into a newer commit", function()
      local tree = oid("HEAD^{tree}")
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.move_to_commit(patch.commit, text(patch), oid("HEAD"))

      eq(nil, err)
      assert.truthy(result)
      eq(tree, oid("HEAD^{tree}"))
      eq(f(with_p), show("HEAD~1", "f.txt"))
      assert.truthy(diff_between("HEAD~1", "HEAD"):find("-p\n+P", 1, true))
    end)

    it("drops the source commit when it becomes empty", function()
      local patch = whole_patch_of("HEAD~1")

      git.custom_patch.move_to_commit(patch.commit, text(patch), oid("HEAD"))

      eq({ "base", "later" }, subjects())
      eq(f(with_bp), show("HEAD", "f.txt"))
    end)

    it("refuses to move the patch into the commit it came from", function()
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.move_to_commit(patch.commit, text(patch), patch.commit)

      eq(nil, result)
      eq("The patch is already part of that commit", err)
    end)

    it("refuses targets that are not part of the current branch", function()
      run { "git", "branch", "other", "HEAD~2" }
      run { "git", "checkout", "--quiet", "other" }
      write("o.txt", { "o" })
      commit("other")
      local target = oid("HEAD")
      run { "git", "checkout", "--quiet", "master" }
      refresh_repo()
      local patch = patch_of("HEAD~1", { "-p", "+P" })

      local result, err = git.custom_patch.move_to_commit(patch.commit, text(patch), target)

      eq(nil, result)
      assert.truthy(err:match("is not part of the current branch"))
    end)
  end)
end)
