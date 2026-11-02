# frozen_string_literal: true

require "open3"
require "json"
require "time"

module Onair
  module Platform
    # Dokku has no HTTP API, so every read is `ssh <host> <subcommand> <app>
    # --format json`, run in parallel. Keys, users and addresses come from the
    # user's SSH setup; the adapter only knows the destination.
    class Dokku < Base
      GIT_PUSH = "git-push"
      FULL_SHA = /\A\h{40}\z/
      # Dokku app names: lowercase letters, digits and dashes.
      APP_NAME = /\A[a-z0-9][a-z0-9-]*\z/
      # ps:report's JSON lists one `status-<process>.<n>` entry per container
      # (named after its CONTAINER.<process>.<n> file), valued like
      # "running (CID: 0123456789a)". The text output's dash form also matches.
      CONTAINER_STATUS = /\Astatus-(?<type>.+)[.-]\d+\z/
      SERVING_STATE = "running"
      # After a deploy, Dokku keeps the previous containers serving for the
      # app's wait-to-retire, 60 seconds unless configured.
      DEFAULT_WAIT_TO_RETIRE = 60
      RETIRE_NOTE = "retiring: previous containers may still serve"
      # Wall-clock limit per command, matching the Heroku adapter's read timeout.
      COMMAND_TIMEOUT = 15
      SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"].freeze

      def snapshot
        validate!
        apps_thread = quiet_thread { dokku("apps:report") }
        git_thread = quiet_thread { optional { dokku("git:report") } }
        builds_thread = quiet_thread { optional { dokku("builds:list") } }
        ps_thread = quiet_thread { optional { dokku("ps:report") } }
        checks_thread = quiet_thread { optional { dokku("checks:report") } }

        deployed = deployed(apps_thread.value, git_thread.value)
        builds = Array(builds_thread.value).grep(Hash)
        Snapshot.new(deployed: deployed, pending: pending(builds), release: failed(builds),
          latest_built_sha: nil, succeeded_shas: [],
          rollout: rollout(ps_thread.value, newest(builds, "succeeded"), checks_thread.value))
      end

      private

      def host
        @config.host
      end

      def app
        @config.app
      end

      # The host and app go on the ssh command line, so a value starting with
      # a dash would be read as an ssh option.
      def validate!
        raise Error, "no host configured - add `host:` to #{Config::FILENAME}" if host.to_s.empty?
        raise Error, "invalid Dokku host #{host.inspect}" if host.start_with?("-")
        raise Error, "invalid Dokku app name #{app.inspect}" unless APP_NAME.match?(app)
      end

      # Dokku strips the plugin prefix from report JSON keys, so git:report's
      # `--git-last-updated-at` arrives as `last-updated-at`.
      # Only a git push records the pushed commit. git:report's sha is not
      # used: it can read the repo's HEAD rather than what was deployed.
      def deployed(apps, git)
        source = apps["deploy-source"].to_s
        raise Error, "nothing deployed yet for app #{app}" if source.empty?

        metadata = apps["deploy-source-metadata"].to_s
        sha = (source == GIT_PUSH && FULL_SHA.match?(metadata)) ? metadata : nil
        Deployed.new(sha: sha, version: nil, description: "deploy source: #{source}",
          deployed_at: unix_time(git&.dig("last-updated-at")))
      end

      # Builds carry no commit, so the sha stays unknown until the build is
      # correlated with the CI run that pushed it.
      def pending(builds)
        running = builds.find { |build| status(build) == "running" }
        running && Pending.new(sha: nil, build_id: running["id"], started_at: parse_time(running["started_at"]))
      end

      # Only a failure newer than the last success matters; older failed
      # records were superseded and are stale.
      def failed(builds)
        failure = newest(builds, "failed")
        success = newest(builds, "succeeded")
        return nil if failure.nil? || (success && started(success) >= started(failure))

        Release.new(sha: nil, version: nil, description: "build #{failure["id"]}", status: :failed,
          started_at: parse_time(failure["finished_at"]) || started(failure))
      end

      def newest(builds, wanted)
        builds.select { |build| status(build) == wanted && started(build) }.max_by { |build| started(build) }
      end

      # display_status turns a running record whose process died into
      # "abandoned"; older Dokku versions only report status.
      def status(build)
        build["display_status"] || build["status"]
      end

      def started(build)
        parse_time(build["started_at"])
      end

      def rollout(ps, success, checks)
        return nil unless ps.is_a?(Hash)

        containers = ps.filter_map do |key, value|
          match = CONTAINER_STATUS.match(key)
          match && [match[:type], value.to_s.split(" ", 2).first.to_s]
        end
        return nil if containers.empty?

        processes = containers.group_by(&:first)
          .sort_by { |type, _| [(type == "web") ? 0 : 1, type] }
          .map { |type, rows| process_rollout(type, rows.map(&:last)) }
        Rollout.new(version: nil, processes: processes, overlap_note: RETIRE_NOTE,
          overlap_until: retire_deadline(processes, success, checks))
      end

      # ps:report lists only the current deploy's containers, so nothing is
      # ever counted as previous.
      def process_rollout(type, states)
        waiting = states.reject { |state| state == SERVING_STATE }.tally
        ProcessRollout.new(type: type, total: states.size, up: states.size - waiting.values.sum,
          waiting: waiting, previous: 0)
      end

      def retire_deadline(processes, success, checks)
        finished = success && parse_time(success["finished_at"])
        return nil if finished.nil? || !processes.all?(&:complete?)

        finished + wait_to_retire(checks)
      end

      def wait_to_retire(checks)
        Integer(checks&.dig("computed-wait-to-retire"), 10)
      rescue ArgumentError, TypeError
        DEFAULT_WAIT_TO_RETIRE
      end

      def optional
        yield
      rescue Error
        nil
      end

      # Dokku prints warnings on stderr (e.g. "Skipping unreadable build
      # record"), so only stdout is parsed.
      def dokku(subcommand)
        stdout, stderr, status = run(["ssh", *SSH_OPTIONS, host, subcommand, app, "--format", "json"])
        raise Error, "dokku #{subcommand} timed out on #{host}" if status.nil?
        raise Error, ssh_error(subcommand, stderr, status) unless status.success?

        JSON.parse(stdout)
      rescue Errno::ENOENT
        raise Error, "ssh not found - the Dokku platform needs an ssh client on PATH"
      rescue JSON::ParserError
        raise Error, "Dokku returned invalid JSON for #{subcommand}"
      end

      # Returns [stdout, stderr, status], with a nil status when the command
      # outlived the timeout and was killed.
      def run(argv, timeout: COMMAND_TIMEOUT)
        Open3.popen3(*argv) do |stdin, stdout, stderr, wait|
          stdin.close
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }
          unless wait.join(timeout)
            begin
              Process.kill("KILL", wait.pid)
            rescue Errno::ESRCH
              nil
            end
            return [out.value, err.value, nil]
          end
          [out.value, err.value, wait.value]
        end
      end

      # ssh itself exits 255; anything else is Dokku's own exit code.
      def ssh_error(subcommand, stderr, status)
        line = stderr.lines.map { |text| text.sub(/\A\s*!\s*/, "").strip }.reject(&:empty?).last
        if status.exitstatus == 255 && stderr.include?("Permission denied")
          "SSH to #{host} was refused - load the key with `ssh-add`"
        elsif status.exitstatus == 255
          "could not reach #{host} over SSH#{line && ": #{line}"}"
        else
          "dokku #{subcommand} failed on #{host}#{line && ": #{line}"}"
        end
      end

      def unix_time(value)
        Time.at(Integer(value, 10)).utc
      rescue ArgumentError, TypeError
        nil
      end

      def parse_time(value)
        value && Time.iso8601(value)
      rescue ArgumentError
        nil
      end

      Platform.register("dokku", self)
    end
  end
end
