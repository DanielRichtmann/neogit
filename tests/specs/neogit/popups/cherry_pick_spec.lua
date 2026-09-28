local eq = assert.are.same
local neogit = require("neogit")
local util = require("tests.util.util")
local git = require("neogit.lib.git")
local notification = require("neogit.lib.notification")
local input = require("tests.mocks.input")
local fuzzy_finder = require("tests.mocks.fuzzy_finder")
local actions = require("neogit.popups.cherry_pick.actions")

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

---Returns the subjects of the commits on `rev` that are not on `origin/master`, oldest first
---@param rev string
---@return string[]
local function subjects(rev)
  return vim.split(
    run { "git", "log", "--reverse", "--format=%s", "origin/master.." .. rev },
    "\n",
    { trimempty = true }
  )
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

---Creates a repository where `master` is three commits (A, B, C) ahead of `origin/master` (base)
local function prepare_repository()
  local origin = util.create_temp_dir("cherry-origin")
  run { "git", "init", "--quiet", "--bare", "--initial-branch=master", origin }

  local working_dir = util.create_temp_dir("cherry-working-dir")
  vim.api.nvim_set_current_dir(working_dir)
  run { "git", "init", "--quiet", "--initial-branch=master" }
  run { "git", "config", "user.email", "test@neogit-test.test" }
  run { "git", "config", "user.name", "Neogit Test" }
  run { "git", "remote", "add", "origin", origin }

  for _, name in ipairs { "base", "A", "B", "C" } do
    vim.fn.writefile({ name }, name .. ".txt")
    run { "git", "add", "." }
    run { "git", "commit", "--quiet", "--message", name }

    if name == "base" then
      run { "git", "push", "--quiet", "--set-upstream", "origin", "master" }
    end
  end

  -- Point neogit at the new repository
  require("neogit.lib.git.repository").instance(working_dir)
  refresh_repo()
end

---@param commits string[]
---@return table
local function popup(commits)
  return {
    state = { env = { commits = commits } },
    get_arguments = function()
      return { "--ff" }
    end,
  }
end

describe("cherry pick popup actions", function()
  local original_error
  local errors

  before_each(function()
    prepare_repository()

    errors = {}
    original_error = notification.error
    notification.error = function(message)
      table.insert(errors, message)
    end
  end)

  after_each(function()
    notification.error = original_error
    input.values = {}
    fuzzy_finder.value = ""
  end)

  describe("donate", function()
    it("removes commits that are not at the tip using a rebase", function()
      run { "git", "branch", "other", "origin/master" }
      fuzzy_finder.value = { "other" }

      actions.donate(popup { oid("HEAD~2"), oid("HEAD~1") })

      eq({}, errors)
      eq({ "C" }, subjects("master"))
      eq({ "A", "B" }, subjects("other"))
      eq("master", run { "git", "branch", "--show-current" })
    end)

    it("does nothing when the commit prompt is aborted", function()
      fuzzy_finder.value = { nil }

      actions.donate(popup {})

      eq({}, errors)
      eq({ "A", "B", "C" }, subjects("master"))
    end)
  end)
end)
