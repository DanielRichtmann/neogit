# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Commit Buffer", :git, :nvim do
  before do
    nvim.keys("ll<enter>")
  end

  it "can close the view with <esc>" do
    nvim.keys("<esc>")
    expect(nvim.filetype).to eq("NeogitLogView")
  end

  it "can close the view with q" do
    nvim.keys("q")
    expect(nvim.filetype).to eq("NeogitLogView")
  end

  it "can open Yank popup" do
    nvim.keys("Y")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  if ENV["CI"].nil? # Fails in GHA :'(
    it "can yank oid" do
      nvim.keys("YY")
      yank = nvim.cmd("echo @*").first
      expect(yank).to match(/[0-9a-f]{40}/)
    end

    it "can yank author" do
      nvim.keys("Ya")
      yank = nvim.cmd("echo @*").first
      expect(yank).to eq("tester <test@example.com>")
    end

    it "can yank subject" do
      nvim.keys("Ys")
      yank = nvim.cmd("echo @*").first
      expect(yank).to eq("Initial commit")
    end

    it "can yank message" do
      nvim.keys("Ym")
      yank = nvim.cmd("echo @*")
      expect(yank).to contain_exactly("Initial commit\n", "commit message")
    end

    it "can yank body" do
      nvim.keys("Yb")
      yank = nvim.cmd("echo @*").first
      expect(yank).to eq("commit message")
    end

    it "can yank diff" do
      nvim.keys("Yd")
      yank = nvim.cmd("echo @*")
      expect(yank).to contain_exactly("@@ -0,0 +1 @@\n", "+hello, world")
    end

    it "can yank tag" do
      git.tag_create("test-tag", "HEAD")
      nvim.keys("Yt")
      yank = nvim.cmd("echo @*").first
      expect(yank).to eq("test-tag")
    end

    it "can yank tags" do
      git.tag_create("test-tag-a", "HEAD")
      git.tag_create("test-tag-b", "HEAD")
      nvim.keys("Yt")
      yank = nvim.cmd("echo @*").first
      expect(yank).to eq("test-tag-a, test-tag-b")
    end
  end

  it "can open the bisect popup" do
    nvim.keys("B")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the branch popup" do
    nvim.keys("b")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the cherry pick popup" do
    nvim.keys("A")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the commit popup" do
    nvim.keys("c")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the diff popup" do
    nvim.keys("d")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the pull popup" do
    nvim.keys("p")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the fetch popup" do
    nvim.keys("f")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the ignore popup" do
    nvim.keys("i")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the log popup" do
    nvim.keys("l")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the remote popup" do
    nvim.keys("M")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the merge popup" do
    nvim.keys("m")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the push popup" do
    nvim.keys("P")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the rebase popup" do
    nvim.keys("r")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the tag popup" do
    nvim.keys("t")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the revert popup" do
    nvim.keys("v")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the worktree popup" do
    nvim.keys("w")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the reset popup" do
    nvim.keys("X")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  it "can open the stash popup" do
    nvim.keys("Z")
    expect(nvim.filetype).to eq("NeogitPopup")
  end

  describe "reversing" do
    it "reverses a hunk into the working tree" do
      nvim.move_to_line("+hello, world")
      nvim.confirm(true)
      nvim.keys("-")
      await { expect(File.read("testfile")).to eq("") }
    end

    it "reverses all changes in a file into the working tree" do
      nvim.move_to_line("new file testfile")
      nvim.confirm(true)
      nvim.keys("-")
      await { expect(File.read("testfile")).to eq("") }
    end

    it "reverses all diffs in the commit when cursor is on metadata" do
      # Cursor starts at the top of the commit view (on metadata, outside any diff)
      nvim.confirm(true)
      nvim.keys("-")
      await { expect(File.read("testfile")).to eq("") }
    end

    describe "a visual selection" do
      before do
        File.write("testfile", "one\ntwo\nthree\n")
        File.write("other", "a\nb\n")
        git.add(%w[testfile other])
        git.commit("second commit")

        nvim.keys("<esc>")
        nvim.lua("require('neogit.buffers.commit_view').new('HEAD'):open()")
        nvim.confirm(true)
      end

      # The diff is taller than the screen, so search the buffer rather than the screen
      def move_to(line)
        nvim.fn("search", ["\\V\\^#{line}\\$", "cw"])
      end

      it "reverses only the selected addition" do
        move_to("+two")
        nvim.keys("V-")
        await do
          expect(File.read("testfile")).to eq("one\nthree\n")
          expect(File.read("other")).to eq("a\nb\n")
        end
      end

      it "reverses a selected deletion and addition" do
        move_to("-hello, world")
        nvim.keys("Vj-")
        await { expect(File.read("testfile")).to eq("hello, world\ntwo\nthree\n") }
      end

      it "reverses selected lines across files" do
        move_to("+b")
        nvim.keys("V4j-") # +b, "modified testfile", hunk header, -hello, world, +one
        await do
          expect(File.read("other")).to eq("a\n")
          expect(File.read("testfile")).to eq("hello, world\ntwo\nthree\n")
        end
      end

      it "does nothing when no changed lines are selected" do
        move_to("@@ -1 +1,3 @@")
        nvim.keys("V-")
        expect(nvim.errors).to be_empty
        expect(File.read("testfile")).to eq("one\ntwo\nthree\n")
      end
    end
  end

  describe "custom patch" do
    before do
      File.write("testfile", "one\ntwo\nthree\n")
      File.write("other", "a\nb\n")
      git.add(%w[testfile other])
      git.commit("second commit")

      nvim.keys("<esc>")
      nvim.lua("require('neogit.buffers.commit_view').new('HEAD'):open()")
      nvim.confirm(true)
    end

    # The diff is taller than the screen, so search the buffer rather than the screen
    def move_to(line)
      nvim.fn("search", ["\\V\\^#{line}\\$", "cw"])
    end

    def summary
      nvim.lua("local p = require('neogit.lib.custom_patch').get() return p and p:summary() or ''")
    end

    def names_in(rev)
      `git show --format= --name-only #{rev}`.split("\n")
    end

    it "adds the hunk under the cursor" do
      move_to("+b")
      nvim.keys("s")
      expect(summary).to eq("1 file, +2 -0")
    end

    it "adds a whole file from its header" do
      move_to("modified testfile")
      nvim.keys("s")
      expect(summary).to eq("1 file, +3 -1")
    end

    it "adds every file from the commit metadata" do
      nvim.keys("gg")
      nvim.keys("s")
      expect(summary).to eq("2 files, +5 -1")
    end

    it "adds the selected lines" do
      move_to("+two")
      nvim.keys("Vjs")
      expect(summary).to eq("1 file, +2 -0")
    end

    it "removes the hunk under the cursor" do
      nvim.keys("gg")
      nvim.keys("s")
      move_to("+b")
      nvim.keys("u")
      expect(summary).to eq("1 file, +3 -1")
    end

    it "removes the selected lines" do
      move_to("modified testfile")
      nvim.keys("s")
      move_to("+two")
      nvim.keys("Vu")
      expect(summary).to eq("1 file, +2 -1")
    end

    it "adds a file from the list of changed files" do
      nvim.keys("gg")
      nvim.fn("search", ["other", "cw"])
      nvim.keys("s")
      expect(summary).to eq("1 file, +2 -0")
    end

    it "highlights the lines that are part of the patch" do
      move_to("+b")
      nvim.keys("s")
      marks = nvim.lua(<<~LUA)
        local ns = vim.api.nvim_get_namespaces()["neogit-buffer-" .. vim.api.nvim_get_current_buf() .. "-CustomPatch"]
        return #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
      LUA
      expect(marks).to eq(2)
    end

    it "does not open the popup without a patch" do
      nvim.keys("C")
      expect(nvim.filetype).to eq("NeogitCommitView")
    end

    describe "popup" do
      before do
        move_to("+b")
        nvim.keys("s")
        nvim.keys("C")
      end

      it "opens" do
        expect(nvim.filetype).to eq("NeogitPopup")
        expect(nvim.errors).to be_empty
      end

      it "renders the patch summary and actions" do
        screen = nvim.screen.join("\n")
        expect(screen).to match(/Patch from \h+ \(1 file, \+2 -0\)/)
        expect(screen).to include("d remove from commit", "n move into new commit", "i move into index",
                                  "c move into other commit", "x discard patch")
      end

      it "removes the patch from the commit" do
        nvim.keys("d")
        await do
          expect(names_in("HEAD")).to eq(["testfile"])
          expect(File.exist?("other")).to be(false)
        end
      end

      it "moves the patch into a new commit" do
        nvim.input("split")
        nvim.keys("n")
        await do
          expect(git.log(1).first.message).to eq("split")
          expect(names_in("HEAD")).to eq(["other"])
          expect(names_in("HEAD~1")).to eq(["testfile"])
        end
      end

      it "moves the patch into the index" do
        nvim.keys("i")
        await do
          expect(names_in("HEAD")).to eq(["testfile"])
          expect(git.status.added.keys).to include("other")
        end
      end

      it "moves the patch into another commit" do
        nvim.keys("c")
        nvim.keys("j<cr>") # The second commit in the list is "Initial commit"
        await do
          expect(names_in("HEAD~1")).to contain_exactly("other", "testfile")
          expect(names_in("HEAD")).to eq(["testfile"])
        end
      end

      it "discards the patch" do
        nvim.keys("x")
        expect(summary).to eq("")
      end
    end
  end
end
