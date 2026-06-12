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

  def snapshot(deployed:, pending: nil, latest: :deployed, succeeded: nil)
    latest = deployed&.sha if latest == :deployed
    Onair::Snapshot.new(deployed: deployed, pending: pending,
                        latest_built_sha: latest, succeeded_shas: succeeded || [latest].compact)
  end

  def identity(name: "Eugene", email: "eugene@example.com")
    Onair::Git::Identity.new(name: name, email: email)
  end
end

RSpec.configure { |config| config.include Builders }
