# frozen_string_literal: true

RSpec.describe Onair::Renderer::Tty do
  let(:now) { Time.utc(2026, 6, 12, 12, 0, 0) }
  let(:deployed_sha) { sha_of("a") }

  def render(report, color: false, hyperlinks: false, repo: "acme/widgets", branch: "main", task: nil)
    described_class.new(report: report, app: "acme-prod", platform_label: "Heroku",
                        branch: branch, repo: repo, color: color, hyperlinks: hyperlinks, now: now,
                        task: task).render
  end

  def report(snapshot:, remote_head: nil, delta: nil, pinned: false, mine: nil, commits: {})
    Onair::Report.new(snapshot: snapshot, remote_head: remote_head, delta: delta,
                      pinned: pinned, mine: mine, commits: commits)
  end

  it "renders the full current-deploy report without color" do
    rep = report(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: now - 7200)),
      delta: :current,
      commits: { deployed_sha => commit_info }
    )
    expect(render(rep)).to eq(
      "\n  " \
      "Heroku acme-prod\n" \
      "\n  " \
      "Deployed:  aaaaaaaaa  (2h ago) by Alice  ★ current\n  " \
      "→ Fix the thing • ↗ #123\n" \
      "\n"
    )
  end

  it "renders ANSI colors and OSC 8 hyperlinks when enabled" do
    rep = report(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: now - 7200)),
      delta: :current,
      commits: { deployed_sha => commit_info }
    )
    out = render(rep, color: true, hyperlinks: true)
    expect(out).to include("\e[38;5;176mHeroku \e[1macme-prod\e[0m")
    expect(out).to include("\e[0;32m★ current\e[0m")
    expect(out).to include("\e]8;;https://github.com/acme/widgets/pull/123\a↗ #123\e]8;;\a")
  end

  it "renders the behind marker with correct pluralization" do
    rep = report(snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
                 delta: 3, commits: { deployed_sha => commit_info })
    expect(render(rep)).to include("↓ 3 commits behind origin/main")

    rep_one = report(snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
                     delta: 1, commits: { deployed_sha => commit_info })
    expect(render(rep_one)).to include("↓ 1 commit behind origin/main")
  end

  it "renders no delta marker when the relationship is unknown" do
    rep = report(snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: now - 60)),
                 commits: { deployed_sha => commit_info })
    expect(render(rep)).to include("Deployed:  aaaaaaaaa  (1m ago) by Alice\n")
  end

  it "renders a pending row above the deployed row" do
    pending_sha = sha_of("b")
    snap = snapshot(deployed: deployed(sha: deployed_sha, at: now - 7200),
                    pending: Onair::Pending.new(sha: pending_sha, started_at: now - 42))
    rep = report(snapshot: snap, delta: nil,
                 commits: { deployed_sha => commit_info,
                            pending_sha => commit_info(subject: "WIP thing", name: "Bob") })
    out = render(rep)
    expect(out).to include("  Pending:   bbbbbbbbb  (42s ago) by Bob\n  → WIP thing • ↗ bbbbbbbbb\n\n  Deployed:")
  end

  it "renders the pinned warning under the deployed row" do
    newer = sha_of("c")
    snap = snapshot(deployed: deployed(sha: deployed_sha, version: 1234, description: "Rollback to v1230"),
                    latest: newer, succeeded: [newer, deployed_sha])
    rep = report(snapshot: snap, pinned: true, commits: { deployed_sha => commit_info })
    expect(render(rep))
      .to include("  ⏸ v1234 (Rollback to v1230) — newer build ccccccccc succeeded but is not running")
  end

  it "renders the yours row with the released-then-absorbed note" do
    mine_sha = sha_of("d")
    rep = report(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: now - 7200)),
      mine: Onair::Mine.new(sha: mine_sha, had_own_build: true),
      commits: { deployed_sha => commit_info,
                 mine_sha => commit_info(subject: "My feature (#99)", name: "Eugene", at: now - 86_400) }
    )
    out = render(rep)
    expect(out).to include("\n\n  Yours:     ddddddddd  (1d ago) by Eugene  ✓ released, then absorbed by current\n")
    expect(out).to include("  → My feature • ↗ #99")
  end

  it "renders the absorbed-by-current note when mine had no build of its own" do
    mine_sha = sha_of("d")
    rep = report(
      snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
      mine: Onair::Mine.new(sha: mine_sha, had_own_build: false),
      commits: { deployed_sha => commit_info, mine_sha => commit_info(name: "Eugene") }
    )
    expect(render(rep)).to include("✓ absorbed by current deploy")
  end

  it "degrades to a not-found row without linking when the commit is absent locally" do
    rep = report(snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: nil)),
                 commits: { deployed_sha => nil })
    out = render(rep)
    expect(out).to include("Deployed:  aaaaaaaaa  by ?\n")
    expect(out).to include("  → (commit not found in local git)\n")
    expect(out).not_to include("↗")
  end

  it "skips links entirely when no repo is known" do
    rep = report(snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
                 commits: { deployed_sha => commit_info(subject: "Plain subject") })
    expect(render(rep, repo: nil)).to include("  → Plain subject\n")
  end

  it "renders the unresolvable-deploy fallback line" do
    rep = report(snapshot: snapshot(deployed: deployed(sha: nil, version: 55, description: "Rollback to v54"),
                                    latest: nil))
    expect(render(rep)).to eq(
      "\n  " \
      "Heroku acme-prod\n" \
      "\n  " \
      "Could not resolve the running commit for v55 (Rollback to v54).\n" \
      "\n"
    )
  end

  describe "task links" do
    let(:task) { Onair::TaskLink.from_config("pattern" => 'ABC-\d+', "url" => "https://tracker.example/{task}") }
    let(:rep) do
      report(snapshot: snapshot(deployed: deployed(sha: deployed_sha)),
             commits: { deployed_sha => commit_info(subject: "ABC-1922: Fix the thing (#123)") })
    end

    it "wraps configured task ids in hyperlinks, keeping the text identical" do
      out = render(rep, hyperlinks: true, task: task)
      expect(out).to include("  → \e]8;;https://tracker.example/ABC-1922\aABC-1922\e]8;;\a: Fix the thing • ")
    end

    it "leaves subjects untouched when hyperlinks are off or no task is configured" do
      expect(render(rep, hyperlinks: false, task: task)).to include("  → ABC-1922: Fix the thing • ↗ #123\n")
      expect(render(rep, hyperlinks: true, task: nil)).to include("ABC-1922: Fix the thing • ")
    end
  end

  it "humanizes ages across all units" do
    {
      30 => "30s ago",
      300 => "5m ago",
      10_800 => "3h ago",
      172_800 => "2d ago"
    }.each do |seconds, expected|
      rep = report(snapshot: snapshot(deployed: deployed(sha: deployed_sha, at: now - seconds)),
                   commits: { deployed_sha => commit_info })
      expect(render(rep)).to include("(#{expected})")
    end
  end
end
