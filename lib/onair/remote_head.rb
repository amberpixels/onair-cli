# frozen_string_literal: true

require "net/http"
require "json"

module Onair
  # Resolves the tip of origin/<branch>. `git ls-remote` over SSH costs ~2s
  # in handshakes; the GitHub API answers the same question in ~0.4s when a
  # token is ambient. Both report the live remote ref — this is a faster
  # transport, never a cache. The ls-remote thread always starts so a failed
  # API attempt costs nothing extra.
  module RemoteHead
    API_HOST = "api.github.com"

    def self.resolve(git:, branch:, repo:)
      ls_remote = Thread.new do
        Thread.current.report_on_exception = false
        git.remote_head(branch)
      end
      api_head(repo, branch) || ls_remote.value
    end

    # Any failure (no repo, no token, 404, timeout, rate limit, offline)
    # falls back to ls-remote — this path must never break the report.
    def self.api_head(repo, branch)
      return nil if repo.nil?

      token = Auth::GithubToken.token
      return nil if token.nil?

      response = Net::HTTP.start(API_HOST, 443, use_ssl: true, open_timeout: 2, read_timeout: 3) do |http|
        request = Net::HTTP::Get.new("/repos/#{repo}/git/ref/heads/#{branch}")
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/vnd.github+json"
        http.request(request)
      end
      return nil unless response.is_a?(Net::HTTPSuccess)

      sha = JSON.parse(response.body).dig("object", "sha")
      sha&.match?(/\A\h{40}\z/) ? sha : nil
    rescue StandardError
      nil
    end
    private_class_method :api_head
  end
end
