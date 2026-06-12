# frozen_string_literal: true

module Onair
  # Runs the platform adapter and git concurrently, lazily fetches missing
  # commits at most once, and assembles the Report.
  class Orchestrator
    def initialize(config:, adapter:, git:, repo: nil)
      @config = config
      @adapter = adapter
      @git = git
      @repo = repo
    end

    def run
      snapshot_thread = quiet_thread { @adapter.snapshot }
      head_thread = quiet_thread { RemoteHead.resolve(git: @git, branch: @config.branch, repo: @repo) }
      snapshot = snapshot_thread.value
      remote_head = head_thread.value

      needed = [snapshot.deployed&.sha, snapshot.pending&.sha, remote_head].compact
      @git.fetch_once! if needed.any? { |sha| !@git.has_commit?(sha) }

      Report.build(snapshot: snapshot, remote_head: remote_head, git: @git)
    end

    private

    # Exceptions surface via #value; without this the dying thread also
    # prints its own backtrace to stderr.
    def quiet_thread(&block)
      Thread.new do
        Thread.current.report_on_exception = false
        block.call
      end
    end
  end
end
