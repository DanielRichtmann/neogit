local git = require("neogit.lib.git")
local input = require("neogit.lib.input")
local notification = require("neogit.lib.notification")
local custom_patch = require("neogit.lib.custom_patch")

local CommitSelectViewBuffer = require("neogit.buffers.commit_select_view")

local M = {}

---@param popup PopupData
---@return CustomPatch
local function get_patch(popup)
  return popup.state.env.patch
end

---Discards the patch and updates the commit view after history has been rewritten.
---@param result CustomPatchResult|nil
---@param err string|nil
---@param message string Notification on success
local function finish(result, err, message)
  if not result then
    notification.error(err or "Failed to rewrite history")
    return
  end

  custom_patch.reset()
  notification.info(message)

  local CommitViewBuffer = require("neogit.buffers.commit_view")
  local view = CommitViewBuffer.instance
  if view and CommitViewBuffer.is_open() then
    local rewritten = result.commits[view.commit_info.oid]
    if rewritten then
      view:update(rewritten)
    elseif rewritten == false then
      view:close()
    else
      view:render_patch()
    end
  end
end

---@param popup PopupData
function M.remove_from_commit(popup)
  local patch = get_patch(popup)
  local result, err = git.custom_patch.remove_from_commit(patch.commit, git.custom_patch.patch_text(patch))
  finish(result, err, "Removed patch from commit")
end

---@param popup PopupData
function M.move_to_new_commit(popup)
  local patch = get_patch(popup)

  local subject = git.log.message(patch.commit)
  local message = input.get_user_input("Message for new commit", { default = subject })
  if not message or vim.trim(message) == "" then
    return
  end

  local result, err =
    git.custom_patch.move_to_new_commit(patch.commit, git.custom_patch.patch_text(patch), message)
  finish(result, err, "Moved patch into new commit")
end

---@param popup PopupData
function M.move_to_index(popup)
  local patch = get_patch(popup)
  local result, err = git.custom_patch.move_to_index(patch.commit, git.custom_patch.patch_text(patch))
  finish(result, err, "Moved patch into index")
end

---@param popup PopupData
function M.move_to_commit(popup)
  local patch = get_patch(popup)

  local target = CommitSelectViewBuffer.new(
    git.log.list { "HEAD" },
    git.remote.list(),
    "Select a commit to move the patch into with <cr>, or <esc> to abort"
  )
    :open_async()[1]

  if not target then
    return
  end

  local result, err = git.custom_patch.move_to_commit(
    patch.commit,
    git.custom_patch.patch_text(patch),
    git.rev_parse.oid(target)
  )
  finish(result, err, ("Moved patch into %s"):format(git.rev_parse.abbreviate_commit(target)))
end

---@param _popup PopupData
function M.discard(_popup)
  custom_patch.reset()

  local CommitViewBuffer = require("neogit.buffers.commit_view")
  if CommitViewBuffer.instance and CommitViewBuffer.is_open() then
    CommitViewBuffer.instance:render_patch()
  end

  notification.info("Discarded custom patch")
end

return M
