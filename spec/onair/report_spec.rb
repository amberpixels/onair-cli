# frozen_string_literal: true

RSpec.describe Onair::Report do
  let(:deployed_sha) { sha_of("a") }
  let(:head_sha) { sha_of("f") }

  def build(snapshot:, remote_head:, git:)
    described_class.build(snapshot: snapshot, remote_head: remote_head, git: git)
  end

  describe "delta" do
    it "is :current when the deployed sha matches the remote head, even with no local commits" do
      git = FakeGit.new
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: deployed_sha, git: git)
      expect(report.delta).to eq(:current)
    end

    it "counts commits behind when deployed is an ancestor of the remote head" do
      git = FakeGit.new(
        commits: { deployed_sha => commit_info, head_sha => commit_info },
        ancestry: { [deployed_sha, head_sha] => 3 }
      )
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: head_sha, git: git)
      expect(report.delta).to eq(3)
    end

    it "is nil when histories diverged (deployed is not an ancestor)" do
      git = FakeGit.new(commits: { deployed_sha => commit_info, head_sha => commit_info })
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: head_sha, git: git)
      expect(report.delta).to be_nil
    end

    it "is nil when the commits are not available locally" do
      git = FakeGit.new(ancestry: { [deployed_sha, head_sha] => 3 })
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: head_sha, git: git)
      expect(report.delta).to be_nil
    end

    it "is nil when the remote head is unknown" do
      git = FakeGit.new(commits: { deployed_sha => commit_info })
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: nil, git: git)
      expect(report.delta).to be_nil
    end

    it "is nil when the deployed commit is unresolvable" do
      report = build(snapshot: snapshot(deployed: deployed(sha: nil), latest: nil),
                     remote_head: head_sha, git: FakeGit.new)
      expect(report.delta).to be_nil
    end
  end

  describe "pinned" do
    let(:newer_sha) { sha_of("c") }

    it "is true when a newer build succeeded but is not running and nothing is pending" do
      snap = snapshot(deployed: deployed(sha: deployed_sha), latest: newer_sha, succeeded: [newer_sha, deployed_sha])
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.pinned).to be(true)
    end

    it "is false when the latest build is the running one" do
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
                     remote_head: nil, git: FakeGit.new)
      expect(report.pinned).to be(false)
    end

    it "is false while a deploy is in flight" do
      pending = Onair::Pending.new(sha: newer_sha, started_at: nil)
      snap = snapshot(deployed: deployed(sha: deployed_sha), pending: pending,
                      latest: newer_sha, succeeded: [newer_sha])
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.pinned).to be(false)
    end

    it "is false when the deployed commit is unresolvable" do
      snap = snapshot(deployed: deployed(sha: nil), latest: newer_sha, succeeded: [newer_sha])
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.pinned).to be(false)
    end
  end

  describe "mine" do
    let(:mine_sha) { sha_of("d") }
    let(:theirs) { commit_info(name: "Alice", email: "alice@example.com") }
    let(:me) { identity }

    def git_with_mine_below(extra_commits: {})
      FakeGit.new(
        commits: { deployed_sha => theirs, mine_sha => commit_info(name: me.name, email: me.email) }
                 .merge(extra_commits),
        identity: me,
        first_parents: { deployed_sha => [[mine_sha, me.name, me.email], [sha_of("e"), "Carol", "c@example.com"]] }
      )
    end

    it "finds my commit just below a deploy authored by someone else" do
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
                     remote_head: nil, git: git_with_mine_below)
      expect(report.mine).to eq(Onair::Mine.new(sha: mine_sha, had_own_build: false))
    end

    it "marks had_own_build when my sha appears among the succeeded builds" do
      snap = snapshot(deployed: deployed(sha: deployed_sha), succeeded: [deployed_sha, mine_sha])
      report = build(snapshot: snap, remote_head: nil, git: git_with_mine_below)
      expect(report.mine).to eq(Onair::Mine.new(sha: mine_sha, had_own_build: true))
    end

    it "is nil when the deployed commit is mine" do
      git = FakeGit.new(
        commits: { deployed_sha => commit_info(name: me.name, email: me.email) },
        identity: me,
        first_parents: { deployed_sha => [[mine_sha, me.name, me.email]] }
      )
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: nil, git: git)
      expect(report.mine).to be_nil
    end

    it "is nil when none of the two commits below are mine" do
      git = FakeGit.new(
        commits: { deployed_sha => theirs },
        identity: me,
        first_parents: { deployed_sha => [[sha_of("e"), "Carol", "c@example.com"],
                                          [sha_of("b"), "Dan", "d@example.com"]] }
      )
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: nil, git: git)
      expect(report.mine).to be_nil
    end

    it "only looks at the two commits immediately below the head" do
      git = FakeGit.new(
        commits: { deployed_sha => theirs },
        identity: me,
        first_parents: { deployed_sha => [[sha_of("e"), "Carol", "c@example.com"],
                                          [sha_of("b"), "Dan", "d@example.com"],
                                          [mine_sha, me.name, me.email]] }
      )
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: nil, git: git)
      expect(report.mine).to be_nil
    end

    it "matches on author name alone (squash merges may swap the email)" do
      git = FakeGit.new(
        commits: { deployed_sha => theirs },
        identity: me,
        first_parents: { deployed_sha => [[mine_sha, me.name, "noreply@github.com"]] }
      )
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: nil, git: git)
      expect(report.mine&.sha).to eq(mine_sha)
    end

    it "is nil when the local identity is unset" do
      git = FakeGit.new(
        commits: { deployed_sha => theirs },
        identity: Onair::Git::Identity.new(name: nil, email: nil),
        first_parents: { deployed_sha => [[mine_sha, "Eugene", "eugene@example.com"]] }
      )
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: nil, git: git)
      expect(report.mine).to be_nil
    end

    it "is nil when the deployed commit is absent locally" do
      git = FakeGit.new(identity: me,
                        first_parents: { deployed_sha => [[mine_sha, me.name, me.email]] })
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)), remote_head: nil, git: git)
      expect(report.mine).to be_nil
    end
  end

  describe "commits map" do
    it "gathers commit info for every sha a renderer may need" do
      pending_sha = sha_of("b")
      mine_sha = sha_of("d")
      me = identity
      git = FakeGit.new(
        commits: { deployed_sha => commit_info(name: "Alice"), pending_sha => commit_info(name: "Bob"),
                   mine_sha => commit_info(name: me.name, email: me.email) },
        identity: me,
        first_parents: { deployed_sha => [[mine_sha, me.name, me.email]] }
      )
      snap = snapshot(deployed: deployed(sha: deployed_sha),
                      pending: Onair::Pending.new(sha: pending_sha, started_at: nil))
      report = build(snapshot: snap, remote_head: nil, git: git)
      expect(report.commits.keys).to contain_exactly(deployed_sha, pending_sha, mine_sha)
    end

    it "maps absent commits to nil instead of crashing" do
      report = build(snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
                     remote_head: nil, git: FakeGit.new)
      expect(report.commits).to eq(deployed_sha => nil)
    end
  end
end
