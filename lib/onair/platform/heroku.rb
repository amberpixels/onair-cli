# frozen_string_literal: true

require "net/http"
require "json"
require "time"

module Onair
  module Platform
    class Heroku < Base
      HOST = "api.heroku.com"

      def snapshot
        token = resolve_token
        release_thread = quiet_thread { deployed(token) }
        builds_thread = quiet_thread { builds(token) }
        deployed = release_thread.value
        pending, succeeded_shas = builds_thread.value
        Snapshot.new(deployed: deployed, pending: pending,
                     latest_built_sha: succeeded_shas.first, succeeded_shas: succeeded_shas)
      end

      private

      def app
        @config.app
      end

      def quiet_thread(&block)
        Thread.new do
          Thread.current.report_on_exception = false
          block.call
        end
      end

      def resolve_token
        token = Auth::Netrc.token(HOST)
        token = Auth::HerokuCli.token if token.nil? || token.empty?
        raise Error, "no Heroku credentials found — run `heroku login`" if token.nil? || token.empty?

        token
      end

      # The slug records the commit the running release was built from — the
      # only reliable source after a rollback, when the builds list still
      # shows the newer (no-longer-running) build on top.
      def deployed(token)
        with_http do |http|
          release = get(http, token, "/apps/#{app}/releases", range: "version ..; order=desc, max=1").first
          raise Error, "no releases found for app #{app}" if release.nil?

          Deployed.new(
            sha: slug_commit(http, token, release.dig("slug", "id")),
            version: release["version"],
            description: release["description"],
            deployed_at: parse_time(release["created_at"])
          )
        end
      end

      def slug_commit(http, token, slug_id)
        return nil if slug_id.nil?

        get(http, token, "/apps/#{app}/slugs/#{slug_id}")["commit"]
      rescue Error
        nil
      end

      # A failed builds call degrades to "no pending, nothing built" rather
      # than killing the whole report; a failed releases call is fatal.
      def builds(token)
        builds = with_http do |http|
          get(http, token, "/apps/#{app}/builds", range: "created_at ..; order=desc, max=10")
        end
        pending_build = builds.find { |build| build["status"] == "pending" }
        pending_sha = pending_build&.dig("source_blob", "version")
        pending = pending_sha && Pending.new(sha: pending_sha, started_at: parse_time(pending_build["created_at"]))
        succeeded = builds.select { |build| build["status"] == "succeeded" }
                          .filter_map { |build| build.dig("source_blob", "version") }
        [pending, succeeded]
      rescue Error
        [nil, []]
      end

      # One connection per thread — the dependent releases → slug pair must
      # not pay a second TLS handshake.
      def with_http(&)
        Net::HTTP.start(HOST, 443, use_ssl: true, open_timeout: 5, read_timeout: 15, &)
      rescue Net::OpenTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "Heroku API request failed: #{e.message}"
      end

      def get(http, token, path, range: nil)
        request = Net::HTTP::Get.new(path)
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/vnd.heroku+json; version=3"
        if range
          request["Range"] = range
          # Net::HTTP won't auto-decompress a response to a ranged request,
          # but its default Accept-Encoding still invites gzip — ask for an
          # uncompressed body instead. (Heroku's Range is pagination, not bytes.)
          request["Accept-Encoding"] = "identity"
        end
        response = http.request(request)
        raise Error, error_message(response, path) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError
        raise Error, "Heroku API returned invalid JSON for #{path}"
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "Heroku API request failed: #{e.message}"
      end

      def error_message(response, path)
        case response.code.to_i
        when 401 then "Heroku rejected the token (401) — run `heroku login`"
        when 404 then "Heroku app not found: #{app}"
        else "Heroku API returned #{response.code} for #{path}"
        end
      end

      def parse_time(value)
        value && Time.iso8601(value)
      rescue ArgumentError
        nil
      end

      Platform.register("heroku", self)
    end
  end
end
