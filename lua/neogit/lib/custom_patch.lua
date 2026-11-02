---A custom patch is a selection of changes from a single commit: whole files, whole hunks, or individual lines. It
---can be turned into patch text that `git apply` understands, in two flavours:
---
--- - `before`: applies (forwards) to trees that do *not* yet contain the commit's changes, such as the commit's parent.
---   Unselected removals become context and unselected additions are left out.
--- - `after`: applies in *reverse* to trees that already contain the commit's changes, such as the commit itself.
---   Unselected additions become context and unselected removals are left out.
---
---Both are needed, because the unselected changes of the commit are part of the context of one side but not the other.
---@class CustomPatch
---@field commit string Full oid of the commit the patch is taken from
---@field files table<string, CustomPatchFile> Files in the patch, by path
local CustomPatch = {}
CustomPatch.__index = CustomPatch

---@class CustomPatchFile
---@field path string Path of the file, as found in `Diff.file`
---@field whole boolean Whether the whole file is part of the patch. Always the case for files that are not plainly
---modified, such as new, deleted or renamed files
---@field hunks table<string, CustomPatchHunk> Selected hunks, by `Hunk.hash`. Empty when `whole` is set
---@field additions integer Number of added lines in the patch
---@field deletions integer Number of removed lines in the patch

---@class CustomPatchHunk
---@field hunk Hunk
---@field lines table<integer, true> Selected lines, as indices into `hunk.lines`. Only additions and removals.

---@param commit string Full oid of the commit
---@return CustomPatch
function CustomPatch.new(commit)
  assert(commit, "custom patch needs a commit")
  return setmetatable({ commit = commit, files = {} }, CustomPatch)
end

---Whether individual hunks and lines of `diff` can be part of a patch. Otherwise only the whole file can be.
---@param diff Diff
---@return boolean
function CustomPatch.supports_lines(diff)
  return diff.kind == "modified" and #diff.hunks > 0
end

---@param hunk Hunk
---@param index integer
---@return boolean
local function is_change(hunk, index)
  local line = hunk.lines[index]
  return line ~= nil and (line:sub(1, 1) == "+" or line:sub(1, 1) == "-")
end

---@param file CustomPatchFile
---@param diff Diff
local function update_stats(file, diff)
  file.additions = 0
  file.deletions = 0

  if file.whole then
    for _, hunk in ipairs(diff.hunks) do
      for _, line in ipairs(hunk.lines) do
        if line:sub(1, 1) == "+" then
          file.additions = file.additions + 1
        elseif line:sub(1, 1) == "-" then
          file.deletions = file.deletions + 1
        end
      end
    end

    return
  end

  for _, entry in pairs(file.hunks) do
    for index in pairs(entry.lines) do
      if entry.hunk.lines[index]:sub(1, 1) == "+" then
        file.additions = file.additions + 1
      else
        file.deletions = file.deletions + 1
      end
    end
  end
end

---@param diff Diff
---@return CustomPatchFile
function CustomPatch:_file(diff)
  if not self.files[diff.file] then
    self.files[diff.file] = { path = diff.file, whole = false, hunks = {}, additions = 0, deletions = 0 }
  end

  return self.files[diff.file]
end

---@param diff Diff
function CustomPatch:_cleanup(diff)
  local file = self.files[diff.file]
  if not file then
    return
  end

  for hash, entry in pairs(file.hunks) do
    if vim.tbl_isempty(entry.lines) then
      file.hunks[hash] = nil
    end
  end

  if not file.whole and vim.tbl_isempty(file.hunks) then
    self.files[diff.file] = nil
  else
    update_stats(file, diff)
  end
end

---Adds every change of the file to the patch.
---@param diff Diff
function CustomPatch:add_file(diff)
  if not CustomPatch.supports_lines(diff) then
    local file = self:_file(diff)
    file.whole = true
    file.hunks = {}
    update_stats(file, diff)
    return
  end

  for _, hunk in ipairs(diff.hunks) do
    self:add_lines(diff, hunk)
  end
end

---Removes every change of the file from the patch.
---@param diff Diff
function CustomPatch:remove_file(diff)
  self.files[diff.file] = nil
end

---Adds the changed lines between `from` and `to` of the hunk to the patch. Without a range the whole hunk is added. For
---files that only support being added whole (see |CustomPatch.supports_lines|), the whole file is added instead.
---@param diff Diff The diff that contains the hunk
---@param hunk Hunk
---@param from? integer First line, as index into `hunk.lines`
---@param to? integer Last line, as index into `hunk.lines`
---@return boolean whole_file Whether the whole file was added instead of just the given lines
function CustomPatch:add_lines(diff, hunk, from, to)
  if not CustomPatch.supports_lines(diff) then
    self:add_file(diff)
    return true
  end

  local file = self:_file(diff)
  local entry = file.hunks[hunk.hash] or { hunk = hunk, lines = {} }
  file.hunks[hunk.hash] = entry

  for index = from or 1, to or #hunk.lines do
    if is_change(hunk, index) then
      entry.lines[index] = true
    end
  end

  self:_cleanup(diff)
  return false
end

---Removes the changed lines between `from` and `to` of the hunk from the patch. Without a range the whole hunk is
---removed. For files that are only part of the patch as a whole, the whole file is removed instead.
---@param diff Diff The diff that contains the hunk
---@param hunk Hunk
---@param from? integer First line, as index into `hunk.lines`
---@param to? integer Last line, as index into `hunk.lines`
---@return boolean whole_file Whether the whole file was removed instead of just the given lines
function CustomPatch:remove_lines(diff, hunk, from, to)
  local file = self.files[diff.file]
  if not file then
    return false
  end

  if file.whole then
    self:remove_file(diff)
    return true
  end

  local entry = file.hunks[hunk.hash]
  if entry then
    for index = from or 1, to or #hunk.lines do
      entry.lines[index] = nil
    end
  end

  self:_cleanup(diff)
  return false
end

---@param path string
---@return boolean
function CustomPatch:contains_file(path)
  return self.files[path] ~= nil and self.files[path].whole
end

---Whether a line of a hunk is part of the patch, either on its own or because its whole file is.
---@param hunk Hunk
---@param index integer Index into `hunk.lines`
---@return boolean
function CustomPatch:contains_line(hunk, index)
  local file = self.files[hunk.file]
  if not file or not is_change(hunk, index) then
    return false
  end

  if file.whole then
    return true
  end

  local entry = file.hunks[hunk.hash]
  return entry ~= nil and entry.lines[index] == true
end

---@return boolean
function CustomPatch:is_empty()
  return next(self.files) == nil
end

---@return string[] paths of the files in the patch, sorted
function CustomPatch:paths()
  local paths = vim.tbl_keys(self.files)
  table.sort(paths)
  return paths
end

---@return { files: integer, additions: integer, deletions: integer }
function CustomPatch:stats()
  local stats = { files = 0, additions = 0, deletions = 0 }

  for _, file in pairs(self.files) do
    stats.files = stats.files + 1
    stats.additions = stats.additions + file.additions
    stats.deletions = stats.deletions + file.deletions
  end

  return stats
end

---@return string A short description, such as "2 files, +3 -1"
function CustomPatch:summary()
  local stats = self:stats()
  return ("%d file%s, +%d -%d"):format(
    stats.files,
    stats.files == 1 and "" or "s",
    stats.additions,
    stats.deletions
  )
end

---Formats one side of a hunk header. A side without lines refers to the line *before* the hunk.
---@param start integer First line of the side, if it had any lines
---@param len integer
---@return string
local function range(start, len)
  return ("%d,%d"):format(len == 0 and start - 1 or start, len)
end

---Builds the lines of one hunk of the patch, or nothing if none of its lines are selected.
---@param entry CustomPatchHunk
---@param reverse boolean Build the `after` flavour, see |CustomPatch|
---@param offset integer Lines added (minus lines removed) by the previous hunks of this file in the patch
---@return string[]|nil lines, integer offset
local function build_hunk(entry, reverse, offset)
  local hunk = entry.hunk
  local lines = {}
  local old_len, new_len = 0, 0
  local kept = true

  for index, line in ipairs(hunk.lines) do
    local operand, content = line:sub(1, 1), line:sub(2)
    local selected = entry.lines[index] == true

    if operand == "\\" then
      -- "\ No newline at end of file" belongs to the line before it
      if kept then
        table.insert(lines, line)
      end
    elseif operand == "-" and (selected or not reverse) then
      table.insert(lines, selected and line or " " .. content)
      old_len = old_len + 1
      new_len = new_len + (selected and 0 or 1)
      kept = true
    elseif operand == "+" and (selected or reverse) then
      table.insert(lines, selected and line or " " .. content)
      old_len = old_len + (selected and 0 or 1)
      new_len = new_len + 1
      kept = true
    elseif operand == "-" or operand == "+" then
      kept = false
    else
      table.insert(lines, line)
      old_len = old_len + 1
      new_len = new_len + 1
      kept = true
    end
  end

  if vim.tbl_isempty(entry.lines) then
    return nil, offset
  end

  -- One side of the hunk is the same as in the commit's diff, so its position is known exactly. The other side is
  -- shifted by the lines that the previous hunks of the patch add or remove.
  local old_start, new_start
  if reverse then
    new_start = hunk.disk_len == 0 and hunk.disk_from + 1 or hunk.disk_from
    old_start = new_start - offset
  else
    old_start = hunk.index_len == 0 and hunk.index_from + 1 or hunk.index_from
    new_start = old_start + offset
  end

  table.insert(lines, 1, ("@@ -%s +%s @@"):format(range(old_start, old_len), range(new_start, new_len)))
  return lines, offset + new_len - old_len
end

---Returns the patch as text that can be passed to `git apply`.
---@param opts { reverse: boolean, whole_file: fun(path: string): string[] }
--- - `reverse` builds the `after` flavour instead of the `before` one, see |CustomPatch|.
--- - `whole_file` returns the complete diff of a file in the commit, including its header. It is used for files that
---   are part of the patch as a whole.
---@return string
function CustomPatch:to_string(opts)
  local lines = {}

  for _, path in ipairs(self:paths()) do
    local file = self.files[path]

    if file.whole then
      vim.list_extend(lines, opts.whole_file(path))
    else
      local entries = vim.tbl_values(file.hunks)
      table.sort(entries, function(a, b)
        return a.hunk.index_from < b.hunk.index_from
      end)

      local hunks = {}
      local offset = 0
      for _, entry in ipairs(entries) do
        local hunk_lines
        hunk_lines, offset = build_hunk(entry, opts.reverse, offset)
        if hunk_lines then
          vim.list_extend(hunks, hunk_lines)
        end
      end

      if #hunks > 0 then
        vim.list_extend(lines, { ("--- a/%s"):format(path), ("+++ b/%s"):format(path) })
        vim.list_extend(lines, hunks)
      end
    end
  end

  if #lines == 0 then
    return ""
  end

  return table.concat(lines, "\n") .. "\n"
end

---@type CustomPatch|nil
local current = nil

local M = {
  new = CustomPatch.new,
  supports_lines = CustomPatch.supports_lines,
}

---Returns the custom patch that is being built, if any. There is at most one at a time, as in lazygit.
---@return CustomPatch|nil
function M.get()
  if current and current:is_empty() then
    current = nil
  end

  return current
end

---Returns the patch that is being built for `commit`, starting a new one if there is none.
---@param commit string Full oid
---@return CustomPatch
function M.get_or_create(commit)
  current = M.get()
  if not current or current.commit ~= commit then
    current = CustomPatch.new(commit)
  end

  return current
end

---Discards the patch that is being built.
function M.reset()
  current = nil
end

---@param value any
---@return boolean
function M.is_patch(value)
  return getmetatable(value) == CustomPatch
end

M.CustomPatch = CustomPatch

return M
