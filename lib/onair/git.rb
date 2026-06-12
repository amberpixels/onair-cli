# frozen_string_literal: true

require "open3"

module Onair
  # The only place that shells out to git. Everything else takes an instance
  # as a dependency — this is the seam unit tests fake. All methods degrade
  # to nil/false/[] on failure; they never raise.
  class Git
    Identity = Data.define(:name, :email)

    def initialize(fetch_allowed: true, dir: nil)
      @fetch_allowed = fetch_allowed
      @dir = dir
      @fetched = false
    end

    # Tip of origin/<branch> straight from the remote — accurate without a
    # pull. Falls back to the local origin/<branch> ref when offline.
    def remote_head(branch)
      out = capture("ls-remote", "origin", "refs/heads/#{branch}")
      sha = out.to_s[/\A\h+/]
      return sha unless sha.nil? || sha.empty?

      capture("rev-parse", "origin/#{branch}")&.strip
    end

    def has_commit?(sha)
      success?("cat-file", "-e", "#{sha}^{commit}")
    end

    # Best-effort, at most once per process, skipped under --no-fetch. The
    # commit may still be absent afterward (force-pushed away); callers
    # degrade via the "(commit not found)" fallback.
    def fetch_once!
      return if @fetched || !@fetch_allowed

      @fetched = true
      success?("fetch", "--quiet", "origin")
    end

    def commit_info(sha)
      out = capture("log", "-1", "--format=%s%x09%an%x09%ae%x09%ct", sha)
      return nil if out.nil?

      subject, name, email, epoch = out.chomp.split("\t", 4)
      CommitInfo.new(subject:, author_name: name, author_email: email, committed_at: Time.at(epoch.to_i))
    end

    def ancestor?(ancestor_sha, descendant_sha)
      success?("merge-base", "--is-ancestor", ancestor_sha, descendant_sha)
    end

    def count_between(from_sha, to_sha)
      capture("rev-list", "--count", "#{from_sha}..#{to_sha}")&.strip&.to_i
    end

    # The <count> first-parent commits just below the given head (head itself
    # excluded), as [sha, author_name, author_email] tuples.
    def first_parent_below(sha, count)
      out = capture("log", "--first-parent", "--skip=1", "-#{count}", "--format=%H%x09%an%x09%ae", sha)
      return [] if out.nil?

      out.lines.map { |line| line.chomp.split("\t", 3) }
    end

    def identity
      Identity.new(name: capture("config", "user.name")&.strip, email: capture("config", "user.email")&.strip)
    end

    # "owner/name" parsed from the origin remote, or nil.
    def origin_repo
      url = capture("remote", "get-url", "origin")&.strip
      url&.match(%r{github\.com[:/](?<repo>[^/]+/[^/\s]+?)(?:\.git)?/?\z})&.[](:repo)
    end

    private

    def capture(*)
      stdout, _stderr, status = Open3.capture3("git", *, **opts)
      status.success? ? stdout : nil
    rescue SystemCallError
      nil
    end

    def success?(*)
      _stdout, _stderr, status = Open3.capture3("git", *, **opts)
      status.success?
    rescue SystemCallError
      false
    end

    def opts
      @dir ? { chdir: @dir } : {}
    end
  end
end
