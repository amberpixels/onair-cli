# frozen_string_literal: true

require "open3"

module Onair
  module Auth
    # Ambient GitHub token for the fast remote-head lookup: env vars first
    # (free), then the gh CLI (~50ms Go binary boot). Never prompts.
    module GithubToken
      def self.token(env: ENV)
        env_token = env["GH_TOKEN"] || env["GITHUB_TOKEN"]
        return env_token unless env_token.to_s.empty?

        cli_token
      end

      def self.cli_token
        stdout, _stderr, status = Open3.capture3("gh", "auth", "token")
        return nil unless status.success?

        token = stdout.strip
        token.empty? ? nil : token
      rescue SystemCallError
        nil
      end
      private_class_method :cli_token
    end
  end
end
