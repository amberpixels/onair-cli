# frozen_string_literal: true

require "json"
require "time"

module Onair
  module Renderer
    # Machine-readable status. The schema is a public API documented in the
    # README — additive changes only.
    class Json
      def initialize(report:, app:, platform:, branch:, repo:)
        @report = report
        @app = app
        @platform = platform
        @branch = branch
        @repo = repo
      end

      def render
        ::JSON.generate(payload)
      end

      def payload
        {
          app: @app,
          platform: @platform,
          branch: @branch,
          repo: @repo,
          remote_head: @report.remote_head,
          deployed: deployed_payload,
          pending: pending_payload,
          delta: delta_payload,
          pinned: pinned_payload,
          yours: yours_payload
        }
      end

      private

      def snapshot
        @report.snapshot
      end

      def deployed_payload
        deployed = snapshot.deployed
        return nil if deployed.nil?

        {
          sha: deployed.sha,
          version: deployed.version,
          description: deployed.description,
          deployed_at: iso(deployed.deployed_at)
        }.merge(commit_fields(deployed.sha))
      end

      def pending_payload
        pending = snapshot.pending
        return nil if pending.nil?

        { sha: pending.sha, started_at: iso(pending.started_at) }.merge(commit_fields(pending.sha))
      end

      def delta_payload
        case @report.delta
        when :current then { status: "current", behind_by: 0 }
        when Integer then { status: "behind", behind_by: @report.delta }
        else { status: "unknown", behind_by: nil }
        end
      end

      def pinned_payload
        return nil unless @report.pinned

        deployed = snapshot.deployed
        {
          version: deployed.version,
          description: deployed.description,
          latest_built_sha: snapshot.latest_built_sha
        }
      end

      def yours_payload
        mine = @report.mine
        return nil if mine.nil?

        { sha: mine.sha, had_own_build: mine.had_own_build }.merge(commit_fields(mine.sha))
      end

      def commit_fields(sha)
        info = sha && @report.commits[sha]
        { subject: info&.subject, author: info&.author_name }
      end

      def iso(time)
        time&.utc&.iso8601
      end
    end
  end
end
