# frozen_string_literal: true

# Shared shorthand for building domain objects in specs.
module Builders
  def sha_of(letter)
    letter * 40
  end

  def commit_info(subject: "Fix the thing (#123)", name: "Alice", email: "alice@example.com",
                  at: Time.utc(2026, 6, 12, 10, 0, 0))
    Onair::CommitInfo.new(subject: subject, author_name: name, author_email: email, committed_at: at)
  end

  def deployed(sha:, version: 1234, description: "Deploy aaaaaaa", at: Time.utc(2026, 6, 12, 10, 0, 0))
    Onair::Deployed.new(sha: sha, version: version, description: description, deployed_at: at)
  end

  def snapshot(deployed:, pending: nil, release: nil, latest: :deployed, succeeded: nil, rollout: nil)
    latest = deployed&.sha if latest == :deployed
    Onair::Snapshot.new(deployed: deployed, pending: pending, release: release,
                        latest_built_sha: latest, succeeded_shas: succeeded || [latest].compact, rollout: rollout)
  end

  def process_rollout(type: "web", total: 3, ready: total, waiting: {}, previous: 0)
    Onair::ProcessRollout.new(type: type, total: total, up: ready, waiting: waiting, previous: previous)
  end

  def dyno_rollout(processes: [process_rollout], version: 1234, overlap_until: nil)
    Onair::Rollout.new(version: version, processes: processes, overlap_until: overlap_until)
  end

  def in_flight_release(sha:, status: :pending, version: 1235, description: "Deploy bbbbbbb",
                        at: Time.utc(2026, 6, 12, 11, 58, 0))
    Onair::Release.new(sha: sha, version: version, description: description, status: status, started_at: at)
  end

  def identity(name: "Eugene", email: "eugene@example.com")
    Onair::Git::Identity.new(name: name, email: email)
  end
end

RSpec.configure { |config| config.include Builders }
