# frozen_string_literal: true

require "json"

RSpec.describe Onair::Renderer::Json do
  let(:deployed_sha) { sha_of("a") }

  def render(report)
    JSON.parse(described_class.new(report: report, app: "acme-prod", platform: "heroku",
                                   branch: "main", repo: "acme/widgets").render)
  end

  it "emits the full schema for a current deploy" do
    report = Onair::Report.new(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: Time.utc(2026, 6, 12, 10, 0, 0))),
      remote_head: deployed_sha, delta: :current, pinned: false, mine: nil,
      commits: { deployed_sha => commit_info }
    )
    expect(render(report)).to eq(
      "app" => "acme-prod",
      "platform" => "heroku",
      "branch" => "main",
      "repo" => "acme/widgets",
      "remote_head" => deployed_sha,
      "deployed" => {
        "sha" => deployed_sha, "version" => 1234, "description" => "Deploy aaaaaaa",
        "deployed_at" => "2026-06-12T10:00:00Z", "subject" => "Fix the thing (#123)", "author" => "Alice"
      },
      "pending" => nil,
      "delta" => { "status" => "current", "behind_by" => 0 },
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
      mine: Onair::Mine.new(sha: mine_sha, had_own_build: true),
      commits: { deployed_sha => commit_info, pending_sha => nil, mine_sha => commit_info(name: "Eugene") }
    )
    out = render(report)
    expect(out["delta"]).to eq("status" => "behind", "behind_by" => 2)
    expect(out["pinned"]).to eq("version" => 1234, "description" => "Deploy aaaaaaa", "latest_built_sha" => newer)
    expect(out["pending"]).to eq("sha" => pending_sha, "started_at" => "2026-06-12T11:00:00Z",
                                 "subject" => nil, "author" => nil)
    expect(out["yours"]).to eq("sha" => mine_sha, "had_own_build" => true,
                               "subject" => "Fix the thing (#123)", "author" => "Eugene")
  end

  it "reports unknown delta as status unknown" do
    report = Onair::Report.new(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
      remote_head: nil, delta: nil, pinned: false, mine: nil, commits: { deployed_sha => nil }
    )
    expect(render(report)["delta"]).to eq("status" => "unknown", "behind_by" => nil)
  end
end
