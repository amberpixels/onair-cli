# frozen_string_literal: true

require_relative "onair/version"

module Onair
  class Error < StandardError
  end

  CommitInfo = Data.define(:subject, :author_name, :author_email, :committed_at)

  # The release currently running in production. `sha` may be nil when the
  # platform can't resolve the running commit; `version` is nil on platforms
  # that number nothing.
  Deployed = Data.define(:sha, :version, :description, :deployed_at)

  # An in-flight build. `sha` is nil when the platform's builds carry no
  # commit; `build_id` then names the row.
  Pending = Data.define(:sha, :build_id, :started_at) do
    def initialize(sha:, started_at:, build_id: nil) = super
  end

  # A release newer than the running one that is not serving traffic: its
  # release phase is still running (status :pending) or it failed (:failed).
  # A nil `sha` is a failed build whose commit the platform does not record.
  Release = Data.define(:sha, :version, :description, :status, :started_at)

  # Dynos of one process type against the running release. `up` counts dynos
  # on the running version that serve (or idle until woken); `waiting` counts
  # the rest of them by state; `previous` counts dynos on an older release.
  ProcessRollout = Data.define(:type, :total, :up, :waiting, :previous) do
    def complete?
      up == total
    end
  end

  # How far the running release has reached its dynos. `overlap_until` is an
  # estimate of when the previous release stops serving traffic, or nil;
  # `overlap_note` is the platform's phrase for that window.
  Rollout = Data.define(:version, :processes, :overlap_until, :overlap_note) do
    def initialize(version:, processes:, overlap_until:, overlap_note: nil) = super

    def complete?
      processes.all?(&:complete?) && overlap_until.nil?
    end
  end

  # What a platform adapter returns. `latest_built_sha` is the newest
  # successfully built sha (rollback detection); `succeeded_shas` lists all
  # recent succeeded build shas, newest first ("yours had its own deploy").
  Snapshot = Data.define(:deployed, :pending, :release, :latest_built_sha, :succeeded_shas, :rollout)

  Mine = Data.define(:sha, :had_own_build)
end

require_relative "onair/task_link"
require_relative "onair/config"
require_relative "onair/git"
require_relative "onair/report"
require_relative "onair/orchestrator"
require_relative "onair/auth/netrc"
require_relative "onair/auth/heroku_cli"
require_relative "onair/auth/github_token"
require_relative "onair/remote_head"
require_relative "onair/platform/base"
require_relative "onair/platform/heroku"
require_relative "onair/platform/dokku"
require_relative "onair/platform/github_deployments"
require_relative "onair/renderer/tty"
require_relative "onair/renderer/json"
require_relative "onair/cli"
