# frozen_string_literal: true

require "open3"

module Onair
  module Auth
    # Fallback when ~/.netrc yields nothing: boot the Heroku CLI. Slow
    # (1-2s of Node startup) — that's why netrc is tried first.
    module HerokuCli
      def self.token
        stdout, _stderr, status = Open3.capture3("heroku", "auth:token")
        return nil unless status.success?

        token = stdout.strip
        token.empty? ? nil : token
      rescue SystemCallError
        nil
      end
    end
  end
end
