# frozen_string_literal: true

module Onair
  # What renderers consume. Pure domain logic — all IO goes through the
  # injected git wrapper; render output must be derivable from this alone.
  #
  # delta:   :current, Integer (commits behind), or nil (diverged/unknown —
  #          silence over speculation).
  # pinned:  a newer build succeeded but is not what's running.
  # mine:    the local user's commit just below someone else's deployed head.
  # commits: sha => CommitInfo (or nil when absent locally) for every sha a
  #          renderer may need to describe.
  Report = Data.define(:snapshot, :remote_head, :delta, :pinned, :mine, :commits) do
    def self.build(snapshot:, remote_head:, git:)
      # Pinned is judged before the stale pending is dropped: during the
      # stale window the newest *succeeded* build is still the previous
      # deploy, which must not read as a rollback.
      pinned = pinned?(snapshot)
      snapshot = drop_stale_pending(snapshot)
      deployed_sha = snapshot.deployed&.sha
      mine = compute_mine(snapshot, git)
      commits = [deployed_sha, snapshot.pending&.sha, mine&.sha].compact.uniq
                                                                .to_h { |sha| [sha, git.commit_info(sha)] }
      new(
        snapshot: snapshot,
        remote_head: remote_head,
        delta: compute_delta(deployed_sha, remote_head, git),
        pinned: pinned,
        mine: mine,
        commits: commits
      )
    end

    # Right after a deploy finishes, the platform's builds list can still
    # report the just-released build as pending while the releases endpoint
    # already shows it running — the same commit would render as both
    # Pending and Deployed. A build that is already on air isn't pending.
    def self.drop_stale_pending(snapshot)
      return snapshot unless snapshot.pending && snapshot.pending.sha == snapshot.deployed&.sha

      snapshot.with(pending: nil)
    end

    def self.compute_delta(sha, head, git)
      return nil if sha.nil? || head.nil?
      return :current if sha == head
      return nil unless git.has_commit?(sha) && git.has_commit?(head)
      return nil unless git.ancestor?(sha, head)

      count = git.count_between(sha, head)
      count&.positive? ? count : nil
    end

    def self.pinned?(snapshot)
      sha = snapshot.deployed&.sha
      latest = snapshot.latest_built_sha
      !sha.nil? && !latest.nil? && latest != sha && snapshot.pending.nil?
    end

    # "Did my merge just ship?" — deliberately a 2-commit first-parent window
    # below the deployed head, not a history search.
    def self.compute_mine(snapshot, git)
      sha = snapshot.deployed&.sha
      return nil if sha.nil? || !git.has_commit?(sha)

      identity = git.identity
      info = git.commit_info(sha)
      return nil if info.nil? || identity_match?(identity, info.author_name, info.author_email)

      mine_sha, = git.first_parent_below(sha, 2).find { |_, name, email| identity_match?(identity, name, email) }
      return nil if mine_sha.nil?

      Mine.new(sha: mine_sha, had_own_build: snapshot.succeeded_shas.include?(mine_sha))
    end

    # Squash merges keep the author's name but may swap the email — match either.
    def self.identity_match?(identity, name, email)
      (!identity.email.to_s.empty? && email == identity.email) ||
        (!identity.name.to_s.empty? && name == identity.name)
    end

    private_class_method :drop_stale_pending, :compute_delta, :pinned?, :compute_mine, :identity_match?
  end
end
