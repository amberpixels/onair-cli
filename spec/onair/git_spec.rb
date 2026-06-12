# frozen_string_literal: true

require "tmpdir"
require "open3"

RSpec.describe Onair::Git do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  before do
    @origin = File.join(@root, "origin.git")
    @work = File.join(@root, "work")
    run_git(@root, "init", "--bare", "--initial-branch=main", @origin)
    run_git(@root, "init", "--initial-branch=main", @work)
    run_git(@work, "remote", "add", "origin", @origin)
    run_git(@work, "config", "user.name", "Alice")
    run_git(@work, "config", "user.email", "alice@example.com")
  end

  def run_git(dir, *args)
    out, err, status = Open3.capture3("git", "-c", "commit.gpgsign=false", *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def commit(message, author: "Alice <alice@example.com>")
    File.write(File.join(@work, "file.txt"), "#{message}\n")
    run_git(@work, "add", ".")
    run_git(@work, "commit", "-m", message, "--author", author)
    run_git(@work, "rev-parse", "HEAD").strip
  end

  def push
    run_git(@work, "push", "--quiet", "origin", "main")
  end

  let(:git) { described_class.new(dir: @work) }

  describe "#remote_head" do
    it "reads the tip of origin/<branch> from the remote" do
      sha = commit("one")
      push
      expect(git.remote_head("main")).to eq(sha)
    end

    it "falls back to the local origin/<branch> ref when the remote is unreachable" do
      sha = commit("one")
      push
      run_git(@work, "fetch", "--quiet", "origin")
      run_git(@work, "remote", "set-url", "origin", File.join(@root, "gone"))
      expect(git.remote_head("main")).to eq(sha)
    end

    it "is nil when there is no remote at all" do
      run_git(@work, "remote", "remove", "origin")
      expect(git.remote_head("main")).to be_nil
    end
  end

  describe "#has_commit?" do
    it "distinguishes present from absent commits" do
      sha = commit("one")
      expect(git.has_commit?(sha)).to be(true)
      expect(git.has_commit?("0" * 40)).to be(false)
    end
  end

  describe "#commit_info" do
    it "returns subject, author, and commit time in one call" do
      sha = commit("Add the widget", author: "Bob <bob@example.com>")
      info = git.commit_info(sha)
      expect(info.subject).to eq("Add the widget")
      expect(info.author_name).to eq("Bob")
      expect(info.author_email).to eq("bob@example.com")
      expect(info.committed_at).to be_within(60).of(Time.now)
    end

    it "is nil for an unknown sha" do
      commit("one")
      expect(git.commit_info("0" * 40)).to be_nil
    end
  end

  describe "ancestry" do
    it "answers ancestor? and count_between" do
      first = commit("one")
      commit("two")
      third = commit("three")
      expect(git.ancestor?(first, third)).to be(true)
      expect(git.ancestor?(third, first)).to be(false)
      expect(git.count_between(first, third)).to eq(2)
    end
  end

  describe "#first_parent_below" do
    it "returns the commits just below the head, newest first, head excluded" do
      first = commit("one", author: "Bob <bob@example.com>")
      second = commit("two")
      third = commit("three")
      expect(git.first_parent_below(third, 2)).to eq(
        [[second, "Alice", "alice@example.com"], [first, "Bob", "bob@example.com"]]
      )
    end
  end

  describe "#fetch_once!" do
    it "fetches missing commits, but only when allowed" do
      commit("one")
      push
      clone = File.join(@root, "clone")
      run_git(@root, "clone", "--quiet", @origin, clone)
      second = commit("two")
      push

      no_fetch = described_class.new(dir: clone, fetch_allowed: false)
      no_fetch.fetch_once!
      expect(no_fetch.has_commit?(second)).to be(false)

      fetching = described_class.new(dir: clone)
      fetching.fetch_once!
      expect(fetching.has_commit?(second)).to be(true)
    end
  end

  describe "#identity" do
    it "reads the local git identity" do
      expect(git.identity).to eq(described_class::Identity.new(name: "Alice", email: "alice@example.com"))
    end
  end

  describe "#origin_repo" do
    it "parses ssh and https GitHub remotes" do
      {
        "git@github.com:acme/widgets.git" => "acme/widgets",
        "https://github.com/amberpixels/onair" => "amberpixels/onair",
        "https://github.com/amberpixels/onair.git" => "amberpixels/onair"
      }.each do |url, expected|
        run_git(@work, "remote", "set-url", "origin", url)
        expect(git.origin_repo).to eq(expected)
      end
    end

    it "is nil for a non-GitHub remote" do
      expect(git.origin_repo).to be_nil
    end
  end
end
