local popup = require("neogit.lib.popup")
local git = require("neogit.lib.git")
local notification = require("neogit.lib.notification")
local actions = require("neogit.popups.custom_patch.actions")

local M = {}

---@param env { patch: CustomPatch|nil }
function M.create(env)
  local patch = env.patch
  if not patch or patch:is_empty() then
    notification.info("No custom patch. Add changes to one from the commit view first")
    return
  end

  local p = popup
    .builder()
    :name("NeogitCustomPatchPopup")
    :group_heading(
      ("Patch from %s (%s)"):format(git.rev_parse.abbreviate_commit(patch.commit), patch:summary())
    )
    :action("d", "remove from commit", actions.remove_from_commit)
    :action("n", "move into new commit", actions.move_to_new_commit)
    :action("i", "move into index", actions.move_to_index)
    :action("c", "move into other commit", actions.move_to_commit)
    :new_action_group()
    :action("x", "discard patch", actions.discard)
    :env(env)
    :build()

  p:show()

  return p
end

return M
