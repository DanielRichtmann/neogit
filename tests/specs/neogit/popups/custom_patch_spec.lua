local eq = assert.are.same
local neogit = require("neogit")
local util = require("tests.util.util")
local git = require("neogit.lib.git")
local notification = require("neogit.lib.notification")
local custom_patch = require("neogit.lib.custom_patch")
local input = require("tests.mocks.input")
local commit_select = require("tests.mocks.commit_select_buffer")
local actions = require("neogit.popups.custom_patch.actions")

neogit.setup {}

---@param cmd string[]
---@return string
local function run(cmd)
  return vim.trim(util.system(cmd))
end

---@return string[]
local function subjects()
  return vim.split(run { "git", "log", "--reverse", "--format=%s" }, "\n", { trimempty = true })
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

---Creates a repository where "two" changes both a.txt and b.txt
local function prepare_repository()
  local working_dir = util.create_temp_dir("custom-patch-popup")
  vim.api.nvim_set_current_dir(working_dir)
  run { "git", "init", "--quiet", "--initial-branch=master" }
  run { "git", "config", "user.email", "test@neogit-test.test" }
  run { "git", "config", "user.name", "Neogit Test" }

  vim.fn.writefile({ "a" }, "a.txt")
  vim.fn.writefile({ "b" }, "b.txt")
  run { "git", "add", "." }
  run { "git", "commit", "--quiet", "--message", "one" }

  vim.fn.writefile({ "A" }, "a.txt")
  vim.fn.writefile({ "B" }, "b.txt")
  run { "git", "commit", "--quiet", "--all", "--message", "two" }

  require("neogit.lib.git.repository").instance(working_dir)
  refresh_repo()
end

---Starts the current patch with the changes of `b.txt` in HEAD
---@return CustomPatch
local function patch_b()
  local diffs =
    git.log.parse(git.cli.show.format("fuller").args("HEAD").call({ trim = false }).stdout)[1].diffs
  local patch = custom_patch.get_or_create(git.rev_parse.oid("HEAD"))

  for _, diff in ipairs(diffs) do
    if diff.file == "b.txt" then
      patch:add_file(diff)
    end
  end

  return patch
end

---@param patch CustomPatch
---@return table
local function popup(patch)
  return { state = { env = { patch = patch } } }
end

describe("custom patch popup actions", function()
  local original_error, original_info
  local errors, infos

  before_each(function()
    prepare_repository()

    errors, infos = {}, {}
    original_error, original_info = notification.error, notification.info
    notification.error = function(message)
      table.insert(errors, message)
    end
    notification.info = function(message)
      table.insert(infos, message)
    end
  end)

  after_each(function()
    notification.error, notification.info = original_error, original_info
    input.values = {}
    commit_select.clear()
    custom_patch.reset()
  end)

  it("removes the patch from the commit and discards it", function()
    actions.remove_from_commit(popup(patch_b()))

    eq({}, errors)
    eq("a.txt", run { "git", "show", "--format=", "--name-only", "HEAD" })
    eq({ "b" }, vim.fn.readfile("b.txt"))
    assert.Nil(custom_patch.get())
  end)

  it("moves the patch into a new commit with the message from the prompt", function()
    input.values = { "split b" }

    actions.move_to_new_commit(popup(patch_b()))

    eq({}, errors)
    eq({ "one", "two", "split b" }, subjects())
    eq("b.txt", run { "git", "show", "--format=", "--name-only", "HEAD" })
  end)

  it("does nothing when the commit message prompt is aborted", function()
    local head = git.rev_parse.oid("HEAD")
    local patch = patch_b()
    input.values = {}

    actions.move_to_new_commit(popup(patch))

    eq(head, git.rev_parse.oid("HEAD"))
    eq(patch, custom_patch.get())
  end)

  it("moves the patch into the index", function()
    actions.move_to_index(popup(patch_b()))

    eq({}, errors)
    eq("M  b.txt", run { "git", "status", "--porcelain" })
  end)

  it("moves the patch into the selected commit", function()
    commit_select.add("HEAD~1")

    actions.move_to_commit(popup(patch_b()))

    eq({}, errors)
    eq({ "one", "two" }, subjects())
    eq("a.txt", run { "git", "show", "--format=", "--name-only", "HEAD" })
    eq("B", vim.trim(util.system { "git", "show", "HEAD~1:b.txt" }))
  end)

  it("does nothing when no commit is selected", function()
    local head = git.rev_parse.oid("HEAD")

    actions.move_to_commit(popup(patch_b()))

    eq(head, git.rev_parse.oid("HEAD"))
  end)

  it("reports errors and keeps the patch", function()
    local patch = patch_b()
    vim.fn.writefile({ "local" }, "b.txt")

    actions.remove_from_commit(popup(patch))

    eq({ "Uncommitted changes conflict with the patch" }, errors)
    eq(patch, custom_patch.get())
  end)

  it("discards the patch", function()
    actions.discard(popup(patch_b()))

    assert.Nil(custom_patch.get())
    eq({ "Discarded custom patch" }, infos)
  end)

  it("does not open without a patch", function()
    local p = require("neogit.popups.custom_patch").create { patch = nil }

    assert.Nil(p)
    eq(1, #infos)
  end)
end)
