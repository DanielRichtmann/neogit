local git = require("neogit.lib.git")
local logger = require("neogit.logger")

---Rewrites history to move a custom patch (see |CustomPatch|) out of the commit it was taken from.
---
---Instead of running an interactive rebase, the new history is computed up front with plumbing commands: every
---affected commit gets a new tree by applying the patch in a temporary index, and is then recreated with
---`git commit-tree`, keeping its author, author date and message. Commits whose tree and parent are unchanged are kept
---as they are. Finally `HEAD` is moved with a single `git update-ref`, which adds an entry to the reflog.
---
---Nothing is written to the index, the working tree or any ref until the whole new history could be built, so a failure
---leaves the repository untouched. The flip side is that the patch must apply cleanly to every affected commit: if a
---later commit changed the same lines, the action is refused rather than stopping with a conflict.
---@class NeogitGitCustomPatch
local M = {}

---@class CustomPatchText
---@field before string Patch that applies forwards to trees that do not contain the commit's changes yet
---@field after string Patch that applies in reverse to trees that already contain the commit's changes

---@class CustomPatchCommitSpec
---@field oid string The original commit, whose author and message are reused
---@field tree string Tree of the rewritten commit
---@field message? string Message to use instead of the original one
---@field new? boolean Whether this is an additional commit rather than a rewrite of `oid`
---@field drop_if_empty? boolean Leave the commit out if it ends up without changes

---@class CustomPatchResult
---@field head string The new HEAD
---@field commits table<string, string|false> Rewritten commits: the original oid mapped to the new oid, or `false` if
---the commit was dropped because it became empty

---@param cmd GitCommandBuilder
---@return ProcessResult
local function call(cmd)
  return cmd.call { hidden = true, ignore_error = true }
end

---@param result ProcessResult
---@return string
local function stderr(result)
  return vim.trim(table.concat(result.stderr, "\n"))
end

---@param oid string
---@return string
local function abbrev(oid)
  return git.rev_parse.abbreviate_commit(oid)
end

---@param rev string
---@return string
local function tree_of(rev)
  return assert(call(git.cli["rev-parse"].verify.args(rev .. "^{tree}")).stdout[1], "no tree for " .. rev)
end

---@return string
local function empty_tree()
  local index = vim.fn.tempname()
  local env = { GIT_INDEX_FILE = index }

  call(git.cli["read-tree"].env(env).args("--empty"))
  local tree = call(git.cli["write-tree"].env(env)).stdout[1]
  os.remove(index)

  return tree
end

---Applies a patch to a tree, without touching the index or the working tree.
---@param tree string
---@param patch string
---@param reverse boolean Whether to apply the patch in reverse
---@return string|nil tree The resulting tree, or nil if the patch does not apply
---@return string|nil error
function M.apply_to_tree(tree, patch, reverse)
  local index = vim.fn.tempname()
  local env = { GIT_INDEX_FILE = index }

  local result = call(git.cli["read-tree"].env(env).args(tree))
  if result:success() then
    local cmd = git.cli.apply.cached.recount.with_patch(patch)
    if reverse then
      cmd = cmd.reverse
    end

    result = call(cmd.env(env))
    if result:success() then
      result = call(git.cli["write-tree"].env(env))
    end
  end

  os.remove(index)

  if result:failure() then
    return nil, stderr(result)
  end

  return result.stdout[1]
end

---Returns the diff of whole files in a commit, against the commit's first parent, so it can be applied with
---`git apply`. Binary files are included.
---@param commit string
---@param paths string[]
---@return string[]
function M.whole_file_diff(commit, paths)
  return call(
    git.cli.show
      .args(
        "--format=",
        "--patch",
        "--binary",
        "--full-index",
        "--find-renames",
        "--no-color",
        "--no-ext-diff",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        commit
      )
      .files(unpack(paths))
  ).stdout
end

---Turns a custom patch into text for both directions, see |CustomPatch|.
---@param patch CustomPatch
---@return CustomPatchText
function M.patch_text(patch)
  local function whole_file(path)
    -- Renamed files are identified by "old -> new", the diff needs both paths
    return M.whole_file_diff(patch.commit, vim.split(path, " -> ", { plain = true }))
  end

  return {
    before = patch:to_string { reverse = false, whole_file = whole_file },
    after = patch:to_string { reverse = true, whole_file = whole_file },
  }
end

---@class CustomPatchCommitInfo
---@field parents string[]
---@field author_name string
---@field author_email string
---@field author_date string In git's internal format, i.e. "<unix timestamp> <timezone offset>"
---@field message string

---@param oid string
---@return CustomPatchCommitInfo
local function commit_info(oid)
  local lines = git.cli["cat-file"].args("commit", oid).call({ hidden = true, trim = false }).stdout
  local info = { parents = {}, message = "" }

  -- The output ends with a newline, which shows up as an empty last line
  if lines[#lines] == "" then
    table.remove(lines)
  end

  for i, line in ipairs(lines) do
    if line == "" then
      info.message = table.concat(vim.list_slice(lines, i + 1), "\n") .. "\n"
      break
    end

    local parent = line:match("^parent (%x+)$")
    if parent then
      table.insert(info.parents, parent)
    end

    local name, email, date = line:match("^author (.-) <(.-)> (%d+ [+-]%d+)$")
    if name then
      info.author_name, info.author_email, info.author_date = name, email, date
    end
  end

  return info
end

---@param spec CustomPatchCommitSpec
---@param parent string|nil
---@return string|nil oid
---@return string|nil error
local function create_commit(spec, parent)
  local info = commit_info(spec.oid)

  -- The message is passed as a file: the CLI builder appends "-" to commands that read stdin, which commit-tree would
  -- take as a second tree. A file also keeps the message exactly as it is.
  local message_file = vim.fn.tempname()
  local message = spec.message and (spec.message:gsub("\n*$", "\n")) or info.message
  local file = assert(io.open(message_file, "wb"))
  file:write(message)
  file:close()

  local cmd = git.cli["commit-tree"]
  if parent then
    cmd = cmd.parent(parent)
  end

  local result = call(cmd.file(message_file).tree(spec.tree).env {
    GIT_AUTHOR_NAME = info.author_name,
    GIT_AUTHOR_EMAIL = info.author_email,
    GIT_AUTHOR_DATE = info.author_date,
  })
  os.remove(message_file)

  if result:failure() then
    return nil, stderr(result)
  end

  return result.stdout[1]
end

---Creates the commits described by `specs` on top of `base`.
---@param base string|nil Parent of the first commit, nil if it is a root commit
---@param specs CustomPatchCommitSpec[] Ordered oldest first
---@return string|nil head
---@return table<string, string|false> commits
---@return string|nil error
local function build_history(base, specs)
  local parent = base
  local commits = {}

  for _, spec in ipairs(specs) do
    local unchanged = not spec.new
      and not spec.message
      and spec.tree == tree_of(spec.oid)
      and commit_info(spec.oid).parents[1] == parent

    if spec.drop_if_empty and spec.tree == (parent and tree_of(parent) or empty_tree()) then
      logger.debug(("[ CustomPatch ]: Dropping %s, which became empty"):format(spec.oid))
      commits[spec.oid] = false
    else
      ---@type string|nil, string|nil
      local oid, err = spec.oid, nil
      if not unchanged then
        oid, err = create_commit(spec, parent)
        if not oid then
          return nil, commits, err
        end
      end

      if not spec.new then
        commits[spec.oid] = oid
      end

      parent = oid
    end
  end

  return parent, commits
end

---Moves HEAD (and the branch it points to) from `old` to `new`.
---@param old string
---@param new string
---@param reason string For the reflog
---@return string|nil error
local function update_head(old, new, reason)
  local result = call(git.cli["update-ref"].args("-m", "neogit: " .. reason, "HEAD", new, old))
  if result:failure() then
    return stderr(result)
  end
end

---Returns the commit and all its descendants up to HEAD, oldest first, together with the commit's parent.
---@param commit string
---@return string[]|nil chain
---@return string|nil parent Nil for a root commit
---@return string|nil error
local function chain_from(commit)
  -- Everything reachable from HEAD but not from the commit's parents, i.e. the commit and its descendants for linear
  -- history. Merge commits are rejected below, which also covers branches merged in after the commit.
  local result = call(git.cli["rev-list"].parents.args("--reverse", "HEAD", "--not", commit .. "^@"))
  if result:failure() then
    return nil, nil, stderr(result)
  end

  local chain = {}
  local parent

  for _, line in ipairs(result.stdout) do
    local oids = vim.split(line, " ")
    if #oids > 2 then
      return nil,
        nil,
        ("Cannot rewrite history that contains merge commits, such as %s"):format(abbrev(oids[1]))
    end

    if oids[1] == commit then
      parent = oids[2]
    end

    table.insert(chain, oids[1])
  end

  if chain[1] ~= commit then
    return nil, nil, ("Commit %s is not part of the current branch"):format(abbrev(commit))
  end

  return chain, parent
end

---Checks that the history from `commit` to HEAD can be rewritten.
---@param commit string Full oid
---@return string|nil error
function M.validate(commit)
  if git.rebase.in_progress() then
    return "Cannot rewrite history while a rebase is in progress"
  end

  if git.merge.in_progress() then
    return "Cannot rewrite history while a merge is in progress"
  end

  if git.sequencer.pick_or_revert_in_progress() then
    return "Cannot rewrite history while a cherry-pick or revert is in progress"
  end

  if not git.log.is_ancestor(commit, "HEAD") then
    return ("Commit %s is not part of the current branch"):format(abbrev(commit))
  end
end

---Returns the trees of `chain`, with `patch` applied to them in the given direction.
---@param chain string[]
---@param patch string
---@param reverse boolean
---@return string[]|nil trees
---@return string|nil error
local function patched_trees(chain, patch, reverse)
  local trees = {}

  for _, oid in ipairs(chain) do
    local tree, err = M.apply_to_tree(tree_of(oid), patch, reverse)
    if not tree then
      logger.debug(("[ CustomPatch ]: Patch does not apply to %s: %s"):format(oid, err))
      return nil, ("The patch does not apply to %s"):format(abbrev(oid))
    end

    table.insert(trees, tree)
  end

  return trees
end

---Builds history from `commit` with the patch taken out of it and every commit after it, without moving HEAD yet.
---@param commit string Full oid
---@param patch CustomPatchText
---@return CustomPatchResult|nil result
---@return string|nil error
local function take_out(commit, patch)
  local err = M.validate(commit)
  if err then
    return nil, err
  end

  local chain, parent
  chain, parent, err = chain_from(commit)
  if not chain then
    return nil, err
  end

  local trees
  trees, err = patched_trees(chain, patch.after, true)
  if not trees then
    return nil, err
  end

  local specs = {}
  for i, oid in ipairs(chain) do
    table.insert(specs, { oid = oid, tree = trees[i], drop_if_empty = oid == commit })
  end

  local head, commits
  head, commits, err = build_history(parent, specs)
  if not head then
    return nil, err
  end

  return { head = head, commits = commits }
end

---Removes the patch from the commit, the index and the working tree.
---@param commit string Full oid of the commit the patch was taken from
---@param patch CustomPatchText
---@return CustomPatchResult|nil result
---@return string|nil error
function M.remove_from_commit(commit, patch)
  local old_head = git.rev_parse.oid("HEAD")
  local result, err = take_out(commit, patch)
  if not result then
    return nil, err
  end

  -- The patch is about to be removed from the index and working tree too. Make sure that will work before HEAD is
  -- moved, since uncommitted changes might be in the way.
  local check = call(git.cli.apply.check.cached.reverse.recount.with_patch(patch.after))
  if check:success() then
    check = call(git.cli.apply.check.reverse.recount.with_patch(patch.after))
  end

  if check:failure() then
    logger.debug(("[ CustomPatch ]: Cannot remove patch from worktree: %s"):format(stderr(check)))
    return nil, "Uncommitted changes conflict with the patch"
  end

  err = update_head(old_head, result.head, ("remove custom patch from %s"):format(abbrev(commit)))
  if err then
    return nil, err
  end

  for _, cmd in ipairs { git.cli.apply.cached, git.cli.apply } do
    local applied = call(cmd.reverse.recount.with_patch(patch.after))
    if applied:failure() then
      return nil,
        ("History was rewritten, but the patch could not be removed from the working tree: %s"):format(
          stderr(applied)
        )
    end
  end

  return result
end

---Removes the patch from the commit and leaves it staged in the index, ready to be committed elsewhere.
---@param commit string Full oid of the commit the patch was taken from
---@param patch CustomPatchText
---@return CustomPatchResult|nil result
---@return string|nil error
function M.move_to_index(commit, patch)
  local old_head = git.rev_parse.oid("HEAD")
  local result, err = take_out(commit, patch)
  if not result then
    return nil, err
  end

  err = update_head(old_head, result.head, ("move custom patch from %s to index"):format(abbrev(commit)))
  if err then
    return nil, err
  end

  return result
end

---Splits the patch out of the commit into a new commit directly after it. Neither the index nor the working tree are
---touched, since the tree of HEAD stays the same.
---@param commit string Full oid of the commit the patch was taken from
---@param patch CustomPatchText
---@param message string Message for the new commit
---@return CustomPatchResult|nil result
---@return string|nil error
function M.move_to_new_commit(commit, patch, message)
  local err = M.validate(commit)
  if err then
    return nil, err
  end

  local chain, parent
  chain, parent, err = chain_from(commit)
  if not chain then
    return nil, err
  end

  local tree
  tree, err = M.apply_to_tree(tree_of(commit), patch.after, true)
  if not tree then
    return nil, ("The patch does not apply to %s: %s"):format(abbrev(commit), err)
  end

  local specs = {
    { oid = commit, tree = tree, drop_if_empty = true },
    { oid = commit, tree = tree_of(commit), message = message, new = true },
  }

  for i = 2, #chain do
    table.insert(specs, { oid = chain[i], tree = tree_of(chain[i]) })
  end

  local old_head = git.rev_parse.oid("HEAD")
  local head, commits
  head, commits, err = build_history(parent, specs)
  if not head then
    return nil, err
  end

  err = update_head(old_head, head, ("move custom patch from %s to new commit"):format(abbrev(commit)))
  if err then
    return nil, err
  end

  return { head = head, commits = commits }
end

---Moves the patch from one commit into another one on the current branch, which may be older or newer. Neither the
---index nor the working tree are touched, since the tree of HEAD stays the same.
---@param commit string Full oid of the commit the patch was taken from
---@param patch CustomPatchText
---@param target string Full oid of the commit to move the patch into
---@return CustomPatchResult|nil result
---@return string|nil error
function M.move_to_commit(commit, patch, target)
  if target == commit then
    return nil, "The patch is already part of that commit"
  end

  local err = M.validate(commit) or M.validate(target)
  if err then
    return nil, err
  end

  -- Moving the patch into an older commit adds it to every commit from the target up to (excluding) the commit it was
  -- taken from. Moving it into a newer commit removes it from every commit from the source up to (excluding) the target.
  -- Either way, the commits from then on keep their trees.
  local older = git.log.is_ancestor(target, commit)
  local first, last = commit, target
  if older then
    first, last = target, commit
  end

  local chain, parent
  chain, parent, err = chain_from(first)
  if not chain then
    return nil, err
  end

  local changed = {}
  for _, oid in ipairs(chain) do
    if oid == last then
      break
    end

    table.insert(changed, oid)
  end

  local trees
  if older then
    trees, err = patched_trees(changed, patch.before, false)
  else
    trees, err = patched_trees(changed, patch.after, true)
  end

  if not trees then
    return nil, err
  end

  local specs = {}
  for i, oid in ipairs(chain) do
    table.insert(specs, { oid = oid, tree = trees[i] or tree_of(oid), drop_if_empty = oid == commit })
  end

  local old_head = git.rev_parse.oid("HEAD")
  local head, commits
  head, commits, err = build_history(parent, specs)
  if not head then
    return nil, err
  end

  err =
    update_head(old_head, head, ("move custom patch from %s into %s"):format(abbrev(commit), abbrev(target)))
  if err then
    return nil, err
  end

  return { head = head, commits = commits }
end

return M
