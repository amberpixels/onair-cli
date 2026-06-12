# frozen_string_literal: true

# Prints a synthetic, fully-colored report for the README demo image.
# Regenerate the SVG with:
#
#   freeze --execute "ruby -Ilib scripts/demo.rb" -o assets/demo.svg
#
# All data below is fake — keep it that way.

require "onair"

now = Time.utc(2026, 6, 12, 12, 0, 0)
deployed_sha = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
pending_sha  = "f4a9c2b1e8d7c6b5a4938271605948372615abcd"
mine_sha     = "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a291807"

report = Onair::Report.new(
  snapshot: Onair::Snapshot.new(
    deployed: Onair::Deployed.new(sha: deployed_sha, version: 1042, description: "Deploy a1b2c3d4",
                                  deployed_at: now - 7200),
    pending: Onair::Pending.new(sha: pending_sha, started_at: now - 42),
    latest_built_sha: deployed_sha,
    succeeded_shas: [deployed_sha, mine_sha]
  ),
  remote_head: pending_sha,
  delta: 1,
  pinned: false,
  mine: Onair::Mine.new(sha: mine_sha, had_own_build: true),
  commits: {
    deployed_sha => Onair::CommitInfo.new(subject: "Fix the thing (#1234)", author_name: "Alice",
                                          author_email: "alice@example.com", committed_at: now - 7300),
    pending_sha => Onair::CommitInfo.new(subject: "Ship dark mode (#1235)", author_name: "Alice",
                                         author_email: "alice@example.com", committed_at: now - 120),
    mine_sha => Onair::CommitInfo.new(subject: "Add the widget API (#1230)", author_name: "Eugene",
                                      author_email: "eugene@example.com", committed_at: now - 10_800)
  }
)

print Onair::Renderer::Tty.new(report: report, app: "acme-prod", platform_label: "Heroku",
                               branch: "main", repo: "acme/widgets",
                               color: true, hyperlinks: false, now: now).render
