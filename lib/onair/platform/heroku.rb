# frozen_string_literal: true

require "net/http"
require "json"
require "time"

module Onair
  module Platform
    class Heroku < Base
      HOST = "api.heroku.com"
      RELEASE_WINDOW = 10
      IN_FLIGHT_STATUSES = %w[pending failed].freeze
      ONE_OFF_TYPES = %w[run scheduler release].freeze
      # An eco dyno asleep on the running release boots that release on wake.
      SERVING_STATES = %w[up idle].freeze
      # With preboot, Heroku keeps routing to the previous web dynos for about
      # three minutes after the new ones come up.
      PREBOOT_HANDOFF = 180

      def snapshot
        token = resolve_token
        releases_thread = quiet_thread { releases(token) }
        builds_thread = quiet_thread { builds(token) }
        dynos_thread = quiet_thread { dynos(token) }
        deployed, release = releases_thread.value
        pending, succeeded_shas = builds_thread.value
        dyno_rows, preboot = dynos_thread.value
        Snapshot.new(deployed: deployed, pending: pending, release: release,
          latest_built_sha: succeeded_shas.first, succeeded_shas: succeeded_shas,
          rollout: rollout(dyno_rows, preboot, deployed.version))
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
        raise Error, "no Heroku credentials found - run `heroku login`" if token.nil? || token.empty?

        token
      end

      # The running release is the one Heroku routes to (`current`), not the
      # newest: while a release phase runs, or after it fails, the previous
      # release keeps serving. The slug records the commit a release was built
      # from - the only reliable source after a rollback, when the builds list
      # still shows the newer (no-longer-running) build on top.
      def releases(token)
        with_http do |http|
          rows = get(http, token, "/apps/#{app}/releases", range: "version ..; order=desc, max=#{RELEASE_WINDOW}")
          raise Error, "no releases found for app #{app}" if rows.empty?

          running = rows.find { |row| row["current"] } || rows.find { |row| row["status"] == "succeeded" }
          raise Error, "no succeeded release among the last #{RELEASE_WINDOW} for app #{app}" if running.nil?

          deployed_sha = slug_commit(http, token, running.dig("slug", "id"))
          [deployed(running, deployed_sha), in_flight(http, token, rows.first, running, deployed_sha)]
        end
      end

      def deployed(row, sha)
        Deployed.new(sha: sha, version: row["version"], description: row["description"],
          deployed_at: parse_time(row["created_at"]))
      end

      # Only the newest release counts: an older failed one was superseded by
      # whatever came after it. Without a commit there is no row to render.
      def in_flight(http, token, newest, running, running_sha)
        return nil if newest.equal?(running) || !IN_FLIGHT_STATUSES.include?(newest["status"])

        slug_id = newest.dig("slug", "id")
        sha = (slug_id == running.dig("slug", "id")) ? running_sha : slug_commit(http, token, slug_id)
        return nil if sha.nil?

        Release.new(sha: sha, version: newest["version"], description: newest["description"],
          status: newest["status"].to_sym, started_at: parse_time(newest["created_at"]))
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

      # A failed dynos call drops the rollout and nothing else; a failed
      # preboot lookup only drops the handoff estimate.
      def dynos(token)
        with_http do |http|
          rows = get(http, token, "/apps/#{app}/dynos")
          [rows, preboot?(http, token)]
        end
      rescue Error
        [nil, false]
      end

      def preboot?(http, token)
        get(http, token, "/apps/#{app}/features/preboot")["enabled"] == true
      rescue Error
        false
      end

      def rollout(rows, preboot, version)
        return nil if rows.nil? || version.nil?

        formation = rows.reject { |dyno| ONE_OFF_TYPES.include?(dyno["type"]) }
        return nil if formation.empty?

        processes = formation.group_by { |dyno| dyno["type"] }
          .sort_by { |type, _| [(type == "web") ? 0 : 1, type] }
          .map { |type, dynos| process_rollout(type, dynos, version) }
        Rollout.new(version: version, processes: processes,
          overlap_until: preboot ? preboot_handoff(formation, version) : nil)
      end

      def process_rollout(type, dynos, version)
        current, previous = dynos.partition { |dyno| dyno.dig("release", "version") == version }
        waiting = current.map { |dyno| dyno["state"] }.reject { |state| SERVING_STATES.include?(state) }.tally
        ProcessRollout.new(type: type, total: dynos.size, up: current.size - waiting.values.sum,
          waiting: waiting, previous: previous.size)
      end

      # Old web dynos still listed are already counted as previous; the
      # estimate covers only the handoff the dynos list does not show.
      def preboot_handoff(formation, version)
        web = formation.select { |dyno| dyno["type"] == "web" }
        return nil if web.empty?
        return nil unless web.all? do |dyno|
          dyno.dig("release", "version") == version && SERVING_STATES.include?(dyno["state"])
        end

        last_up = web.filter_map { |dyno| parse_time(dyno["updated_at"]) }.max
        last_up && (last_up + PREBOOT_HANDOFF)
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
        when 401 then "Heroku rejected the token (401) - run `heroku login`"
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
