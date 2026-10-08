# frozen_string_literal: true

RSpec.describe Onair::Report do
  let(:deployed_sha) { sha_of("a") }
  let(:head_sha) { sha_of("f") }

  let(:now) { Time.utc(2026, 6, 12, 12, 0, 0) }

  def build(snapshot:, remote_head:, git:)
    described_class.build(snapshot: snapshot, remote_head: remote_head, git: git, now: now)
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

  describe "stale pending" do
    it "drops a pending build that is already the deployed commit" do
      pending = Onair::Pending.new(sha: deployed_sha, started_at: nil)
      snap = snapshot(deployed: deployed(sha: deployed_sha), pending: pending)
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.snapshot.pending).to be_nil
    end

    it "keeps a pending build for a different commit" do
      pending = Onair::Pending.new(sha: sha_of("b"), started_at: nil)
      snap = snapshot(deployed: deployed(sha: deployed_sha), pending: pending)
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.snapshot.pending).to eq(pending)
    end

    it "does not report pinned during the stale-pending window" do
      pending = Onair::Pending.new(sha: deployed_sha, started_at: nil)
      snap = snapshot(deployed: deployed(sha: deployed_sha), pending: pending,
                      latest: sha_of("b"), succeeded: [sha_of("b")])
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.snapshot.pending).to be_nil
      expect(report.pinned).to be(false)
    end

    it "does not misread an unresolvable deploy as the pending build" do
      pending = Onair::Pending.new(sha: sha_of("b"), started_at: nil)
      snap = snapshot(deployed: deployed(sha: nil), pending: pending, latest: nil)
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.snapshot.pending).to eq(pending)
    end
  end

  describe "release in flight" do
    let(:release_sha) { sha_of("b") }

    it "suppresses current when a release of another commit is in flight" do
      snap = snapshot(deployed: deployed(sha: deployed_sha), release: in_flight_release(sha: release_sha))
      report = build(snapshot: snap, remote_head: deployed_sha, git: FakeGit.new)
      expect(report.delta).to be_nil
    end

    it "suppresses current after a release of another commit failed" do
      snap = snapshot(deployed: deployed(sha: deployed_sha),
                      release: in_flight_release(sha: release_sha, status: :failed))
      report = build(snapshot: snap, remote_head: deployed_sha, git: FakeGit.new)
      expect(report.delta).to be_nil
    end

    it "keeps current when the in-flight release carries the running commit" do
      snap = snapshot(deployed: deployed(sha: deployed_sha), release: in_flight_release(sha: deployed_sha))
      report = build(snapshot: snap, remote_head: deployed_sha, git: FakeGit.new)
      expect(report.delta).to eq(:current)
    end

    it "keeps the behind count, which is true of the running code" do
      git = FakeGit.new(
        commits: { deployed_sha => commit_info, head_sha => commit_info },
        ancestry: { [deployed_sha, head_sha] => 2 }
      )
      snap = snapshot(deployed: deployed(sha: deployed_sha), release: in_flight_release(sha: head_sha))
      expect(build(snapshot: snap, remote_head: head_sha, git: git).delta).to eq(2)
    end

    it "is not pinned while the newer build is in its release phase" do
      snap = snapshot(deployed: deployed(sha: deployed_sha), release: in_flight_release(sha: release_sha),
                      latest: release_sha, succeeded: [release_sha, deployed_sha])
      expect(build(snapshot: snap, remote_head: nil, git: FakeGit.new).pinned).to be(false)
    end

    it "stays pinned while a same-commit release (config change) runs its release phase" do
      snap = snapshot(deployed: deployed(sha: deployed_sha), release: in_flight_release(sha: deployed_sha),
                      latest: release_sha, succeeded: [release_sha, deployed_sha])
      expect(build(snapshot: snap, remote_head: nil, git: FakeGit.new).pinned).to be(true)
    end

    it "drops a pending build that the release row already shows" do
      snap = snapshot(deployed: deployed(sha: deployed_sha),
                      pending: Onair::Pending.new(sha: release_sha, started_at: nil),
                      release: in_flight_release(sha: release_sha))
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.snapshot.pending).to be_nil
      expect(report.snapshot.release.sha).to eq(release_sha)
    end

    it "includes the release commit in the commits map" do
      snap = snapshot(deployed: deployed(sha: deployed_sha), release: in_flight_release(sha: release_sha))
      report = build(snapshot: snap, remote_head: nil, git: FakeGit.new)
      expect(report.commits.keys).to contain_exactly(deployed_sha, release_sha)
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

  describe "rollout" do
    def rollout_report(rollout)
      build(snapshot: snapshot(deployed: deployed(sha: deployed_sha), rollout: rollout), remote_head: nil,
            git: FakeGit.new)
    end

    it "is nil when the platform reported none" do
      expect(rollout_report(nil).rollout).to be_nil
    end

    it "keeps a handoff estimate that is still ahead" do
      report = rollout_report(dyno_rollout(overlap_until: now + 90))
      expect(report.rollout.overlap_until).to eq(now + 90)
      expect(report.rollout).not_to be_complete
    end

    it "drops a handoff estimate that has passed, completing the rollout" do
      report = rollout_report(dyno_rollout(overlap_until: now - 1))
      expect(report.rollout.overlap_until).to be_nil
      expect(report.rollout).to be_complete
    end

    it "is incomplete while any process has dynos off the running release" do
      rollout = dyno_rollout(processes: [process_rollout, process_rollout(type: "worker", total: 2, ready: 1,
                                                                          previous: 1)])
      expect(rollout_report(rollout).rollout).not_to be_complete
    end
  end
end
