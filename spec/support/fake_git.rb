# frozen_string_literal: true

# Configurable stand-in for Onair::Git — the seam unit tests fake.
class FakeGit
  attr_reader :fetch_count, :identity

  def initialize(commits: {}, identity: Onair::Git::Identity.new(name: nil, email: nil),
                 remote_head: nil, ancestry: {}, first_parents: {})
    @commits = commits                # sha => CommitInfo
    @identity = identity
    @remote_head_sha = remote_head
    @ancestry = ancestry              # [ancestor, descendant] => commits between
    @first_parents = first_parents    # sha => [[sha, author_name, author_email], ...]
    @fetch_count = 0
  end

  def remote_head(_branch)
    @remote_head_sha
  end

  def has_commit?(sha)
    @commits.key?(sha)
  end

  def commit_info(sha)
    @commits[sha]
  end

  def ancestor?(ancestor_sha, descendant_sha)
    @ancestry.key?([ancestor_sha, descendant_sha])
  end

  def count_between(from_sha, to_sha)
    @ancestry[[from_sha, to_sha]]
  end

  def first_parent_below(sha, count)
    (@first_parents[sha] || []).first(count)
  end

  def fetch_once!
    @fetch_count += 1
  end
end
