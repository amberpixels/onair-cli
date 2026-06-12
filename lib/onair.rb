# frozen_string_literal: true

require_relative "onair/version"

module Onair
  class Error < StandardError
  end

  CommitInfo = Data.define(:subject, :author_name, :author_email, :committed_at)

  # The release currently running in production. `sha` may be nil when the
  # platform can't resolve the running commit; version/description still render.
  Deployed = Data.define(:sha, :version, :description, :deployed_at)

  Pending = Data.define(:sha, :started_at)

  # What a platform adapter returns. `latest_built_sha` is the newest
  # successfully built sha (rollback detection); `succeeded_shas` lists all
  # recent succeeded build shas, newest first ("yours had its own deploy").
  Snapshot = Data.define(:deployed, :pending, :latest_built_sha, :succeeded_shas)

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
require_relative "onair/renderer/tty"
require_relative "onair/renderer/json"
require_relative "onair/cli"
