# frozen_string_literal: true

require "net/http"
require "json"
require "time"
require "uri"

module Onair
  module Platform
    # Reads what CI recorded as GitHub Deployments for one environment, so
    # anyone who can read the repo sees production without host access. It
    # reports CI's record, not what the host runs.
    class GithubDeployments < Base
      HOST = "api.github.com"
      API_VERSION = "2022-11-28"
      WINDOW = 10
      # owner/name, with no all-dot segment, since the repo goes into a URL path.
      REPO_NAME = %r{\A(?!\.+/)[\w.-]+/(?!\.+\z)[\w.-]+\z}
      SUCCESS = "success"
      # GitHub marks an older successful deployment inactive once a newer one
      # in the environment succeeds, so both states count as deployed once.
      SUCCEEDED_STATES = %w[success inactive].freeze
      IN_FLIGHT_STATES = %w[queued pending in_progress].freeze
      FAILED_STATES = %w[failure error].freeze

      def initialize(config, repo: nil)
        super
        raise Error, "no GitHub repo - add `repo: owner/name` to #{Config::FILENAME}" if @repo.to_s.empty?
        raise Error, "invalid GitHub repo #{@repo.inspect} - expected owner/name" unless REPO_NAME.match?(@repo)
      end

      def snapshot
        token = resolve_token
        rows = with_statuses(token, deployments(token))
        if rows.empty?
          return Snapshot.new(deployed: nil, pending: nil, release: nil, latest_built_sha: nil,
            succeeded_shas: [], rollout: nil)
        end

        index = rows.index { |row| row[:state] == SUCCESS }
        if index.nil?
          raise Error, "no successful deployment among the last #{WINDOW} in #{environment} for #{@repo}"
        end

        newer = rows.first(index)
        succeeded = rows.select { |row| SUCCEEDED_STATES.include?(row[:state]) }.map { |row| row[:sha] }.uniq
        Snapshot.new(deployed: deployed(rows[index]), pending: pending(newer), release: failed(newer),
          latest_built_sha: succeeded.first, succeeded_shas: succeeded, rollout: nil)
      end

      def display_name
        "GitHub"
      end

      def target_label
        "#{@repo} (#{environment})"
      end

      def environment
        @config.environment || Config::DEFAULT_ENVIRONMENT
      end

      private

      def resolve_token
        token = Auth::GithubToken.token
        raise Error, "no GitHub token found - run `gh auth login`" if token.nil? || token.empty?

        token
      end

      def deployments(token)
        query = URI.encode_www_form(environment: environment, per_page: WINDOW)
        with_http { |http| get(http, token, "/repos/#{@repo}/deployments?#{query}") }
      end

      # Pairs each deployment with its newest status, newest deployment first.
      # A failed statuses call drops that deployment, not the report, and a
      # deployment with no status yet says nothing, so it is skipped too.
      def with_statuses(token, deployments)
        threads = deployments.map do |deployment|
          quiet_thread { optional { newest_status(token, deployment["id"]) } }
        end
        deployments.zip(threads.map(&:value)).filter_map do |deployment, status|
          next if status.nil?

          {id: deployment["id"], sha: deployment["sha"], created_at: parse_time(deployment["created_at"]),
           state: status["state"], status_at: parse_time(status["created_at"])}
        end.sort_by { |row| row[:created_at] || Time.at(0) }.reverse
      end

      def newest_status(token, id)
        with_http { |http| get(http, token, "/repos/#{@repo}/deployments/#{id}/statuses?per_page=1") }.first
      end

      def deployed(row)
        Deployed.new(sha: row[:sha], version: nil, description: "deployment #{row[:id]}",
          deployed_at: row[:status_at])
      end

      def pending(newer)
        row = newer.find { |candidate| IN_FLIGHT_STATES.include?(candidate[:state]) }
        row && Pending.new(sha: row[:sha], started_at: row[:created_at])
      end

      def failed(newer)
        row = newer.find { |candidate| FAILED_STATES.include?(candidate[:state]) }
        row && Release.new(sha: row[:sha], version: nil, description: "deployment #{row[:id]}",
          status: :failed, started_at: row[:status_at])
      end

      def optional
        yield
      rescue Error
        nil
      end

      def with_http(&)
        Net::HTTP.start(HOST, 443, use_ssl: true, open_timeout: 5, read_timeout: 15, &)
      rescue Net::OpenTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "GitHub API request failed: #{e.message}"
      end

      def get(http, token, path)
        request = Net::HTTP::Get.new(path)
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = API_VERSION
        response = http.request(request)
        raise Error, error_message(response, path) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError
        raise Error, "GitHub API returned invalid JSON for #{path}"
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "GitHub API request failed: #{e.message}"
      end

      def error_message(response, path)
        case response.code.to_i
        when 401 then "GitHub rejected the token (401) - run `gh auth login`"
        when 404 then "GitHub repo not found or not visible to this token: #{@repo}"
        when 403, 429
          if response["x-ratelimit-remaining"] == "0"
            "GitHub API rate limit reached - try again later"
          else
            "GitHub API returned #{response.code} for #{path}"
          end
        else "GitHub API returned #{response.code} for #{path}"
        end
      end

      def parse_time(value)
        value && Time.iso8601(value)
      rescue ArgumentError
        nil
      end

      Platform.register("github_deployments", self)
    end
  end
end
