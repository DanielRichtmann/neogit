local git = require("neogit.lib.git")
local notification = require("neogit.lib.notification")
local util = require("neogit.lib.util")
local client = require("neogit.client")
local event = require("neogit.lib.event")

---@class NeogitGitCherryPick
local M = {}

---@param commits string[]
---@param args string[]
---@return boolean
function M.pick(commits, args)
  local cmd = git.cli["cherry-pick"].arg_list(util.merge(args, commits))

  local result
  if vim.tbl_contains(args, "--edit") then
    result = cmd.env(client.get_envs_git_editor()).call { pty = true }
  else
    result = cmd.call { await = true }
  end

  if result:failure() then
    notification.error("Cherry Pick failed. Resolve conflicts before continuing")
    return false
  else
    event.send("CherryPick", { commits = commits })
    return true
  end
end

function M.apply(commits, args)
  args = util.filter_map(args, function(arg)
    if arg ~= "--ff" then
      return arg
    end
  end)

  local result = git.cli["cherry-pick"].no_commit.arg_list(util.merge(args, commits)).call { await = true }
  if result:failure() then
    notification.error("Cherry Pick failed. Resolve conflicts before continuing")
  else
    event.send("CherryPick", { commits = commits })
  end
end

---Builds a GIT_SEQUENCE_EDITOR command that marks each of `commits` as "drop" in the todo list of an interactive
---rebase. Commits are matched by their abbreviated oid, since that is what git writes to the todo list.
---@param commits string[]
---@return string
local function drop_commits_editor(commits)
  local abbreviated = util.map(commits, git.rev_parse.abbreviate_commit)
  local substitute = ([[%%s/\v^(pick|p) (%s)/drop \2/e]]):format(table.concat(abbreviated, "|"))

  return table.concat({
    vim.fn.shellescape(vim.v.progpath),
    "--headless",
    "--clean",
    "-n",
    "-c",
    vim.fn.shellescape(substitute),
    "-c",
    "wq",
  }, " ")
end

---Moves `commits` from `src` onto `dst`, mirroring `magit--cherry-move`.
---
---If `dst` does not exist it is created at `start`. The commits are then picked onto `dst` and removed from `src`,
---either by resetting `src` (when the commits are at its tip) or by dropping them in an interactive rebase.
---@param commits string[] Ordered oldest first
---@param src? string Branch to remove the commits from. When nil, the commits are only picked onto `dst`
---@param dst string Branch to move the commits onto
---@param args string[] Arguments for `git cherry-pick`
---@param start? string Starting point for `dst` if it has to be created
---@param checkout_dst? boolean Whether `dst` should be checked out once done, instead of `src`
function M.move(commits, src, dst, args, start, checkout_dst)
  local current = git.branch.current()

  if not git.branch.exists(dst) and not git.branch.create(dst, start) then
    return notification.error(("Failed to create branch %q"):format(dst))
  end

  if dst ~= current and git.branch.checkout(dst):failure() then
    return notification.error(("Failed to checkout branch %q"):format(dst))
  end

  if not src then
    return M.pick(commits, args)
  end

  local tip = commits[#commits]
  local keep = commits[1] .. "^"

  if not M.pick(commits, args) then
    return
  end

  if git.rev_parse.oid(tip) == git.rev_parse.oid(src) then
    git.cli["update-ref"]
      .message(("reset: moving to %s"):format(keep))
      .args(git.rev_parse.full_name(src), keep, tip)
      .call()

    if not checkout_dst then
      git.branch.checkout(src)
    end
  else
    if git.branch.checkout(src):failure() then
      return notification.error(("Failed to checkout branch %q"):format(src))
    end

    local result = git.cli.rebase.interactive
      .args(keep)
      .in_pty(true)
      .env({ GIT_SEQUENCE_EDITOR = drop_commits_editor(commits) })
      .call()

    if result:failure() then
      return notification.error("Removing commits failed - Fix things manually before continuing.")
    end

    if checkout_dst then
      git.branch.checkout(dst)
    end
  end
end

function M.continue()
  git.cli["cherry-pick"].continue.call { await = true }
end

function M.skip()
  git.cli["cherry-pick"].skip.call { await = true }
end

function M.abort()
  git.cli["cherry-pick"].abort.call { await = true }
end

return M
