# frozen_string_literal: true

require "json"

RSpec.describe Onair::Renderer::Json do
  let(:deployed_sha) { sha_of("a") }

  def render(report, task: nil)
    JSON.parse(described_class.new(report: report, app: "acme-prod", platform: "heroku",
      branch: "main", repo: "acme/widgets", task: task).render)
  end

  it "emits the full schema for a current deploy" do
    report = Onair::Report.new(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: Time.utc(2026, 6, 12, 10, 0, 0))),
      remote_head: deployed_sha, delta: :current, pinned: false, mine: nil, rollout: nil,
      commits: {deployed_sha => commit_info}
    )
    expect(render(report)).to eq(
      "app" => "acme-prod",
      "platform" => "heroku",
      "branch" => "main",
      "repo" => "acme/widgets",
      "remote_head" => deployed_sha,
      "deployed" => {
        "sha" => deployed_sha, "version" => 1234, "description" => "Deploy aaaaaaa",
        "deployed_at" => "2026-06-12T10:00:00Z", "subject" => "Fix the thing (#123)", "author" => "Alice",
        "task" => nil
      },
      "pending" => nil,
      "release" => nil,
      "rollout" => nil,
      "delta" => {"status" => "current", "behind_by" => 0},
      "pinned" => nil,
      "yours" => nil
    )
  end

  it "emits behind, pinned, pending, and yours facts" do
    pending_sha = sha_of("b")
    newer = sha_of("c")
    mine_sha = sha_of("d")
    snap = snapshot(deployed: deployed(sha: deployed_sha),
      pending: Onair::Pending.new(sha: pending_sha, started_at: Time.utc(2026, 6, 12, 11, 0, 0)),
      latest: newer, succeeded: [newer, mine_sha])
    report = Onair::Report.new(
      snapshot: snap, remote_head: sha_of("f"), delta: 2, pinned: true,
      mine: Onair::Mine.new(sha: mine_sha, had_own_build: true), rollout: nil,
      commits: {deployed_sha => commit_info, pending_sha => nil, mine_sha => commit_info(name: "Eugene")}
    )
    out = render(report)
    expect(out["delta"]).to eq("status" => "behind", "behind_by" => 2)
    expect(out["pinned"]).to eq("version" => 1234, "description" => "Deploy aaaaaaa", "latest_built_sha" => newer)
    expect(out["pending"]).to eq("sha" => pending_sha, "started_at" => "2026-06-12T11:00:00Z",
      "subject" => nil, "author" => nil, "task" => nil)
    expect(out["yours"]).to eq("sha" => mine_sha, "had_own_build" => true,
      "subject" => "Fix the thing (#123)", "author" => "Eugene", "task" => nil)
  end

  it "emits an in-flight release" do
    release_sha = sha_of("b")
    report = Onair::Report.new(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha),
        release: in_flight_release(sha: release_sha, status: :failed)),
      remote_head: nil, delta: nil, pinned: false, mine: nil, rollout: nil,
      commits: {deployed_sha => commit_info, release_sha => commit_info(subject: "Migrate", name: "Bob")}
    )
    expect(render(report)["release"]).to eq(
      "sha" => release_sha, "version" => 1235, "description" => "Deploy bbbbbbb", "status" => "failed",
      "started_at" => "2026-06-12T11:58:00Z", "subject" => "Migrate", "author" => "Bob", "task" => nil
    )
  end

  it "includes parsed task id and url when a task matcher is configured" do
    task = Onair::TaskLink.from_config("pattern" => 'ABC-\d+', "url" => "https://tracker.example/{task}")
    report = Onair::Report.new(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
      remote_head: nil, delta: nil, pinned: false, mine: nil, rollout: nil,
      commits: {deployed_sha => commit_info(subject: "ABC-1922: Fix the thing (#123)")}
    )
    expect(render(report, task: task)["deployed"]["task"])
      .to eq("id" => "ABC-1922", "url" => "https://tracker.example/ABC-1922")
  end

  it "reports unknown delta as status unknown" do
    report = Onair::Report.new(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
      remote_head: nil, delta: nil, pinned: false, mine: nil, rollout: nil, commits: {deployed_sha => nil}
    )
    expect(render(report)["delta"]).to eq("status" => "unknown", "behind_by" => nil)
  end

  it "emits the rollout" do
    rollout = dyno_rollout(
      processes: [process_rollout(total: 3),
        process_rollout(type: "worker", total: 2, ready: 1, waiting: {"starting" => 1})],
      overlap_until: Time.utc(2026, 6, 12, 12, 2, 0)
    )
    report = Onair::Report.new(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
      remote_head: nil, delta: nil, pinned: false, mine: nil, rollout: rollout, commits: {deployed_sha => nil}
    )
    expect(render(report)["rollout"]).to eq(
      "version" => 1234, "complete" => false,
      "processes" => [
        {"type" => "web", "up" => 3, "total" => 3, "waiting" => {}, "previous" => 0},
        {"type" => "worker", "up" => 1, "total" => 2, "waiting" => {"starting" => 1}, "previous" => 0}
      ],
      "overlap_until" => "2026-06-12T12:02:00Z"
    )
  end
end
