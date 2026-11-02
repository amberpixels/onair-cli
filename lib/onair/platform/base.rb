# frozen_string_literal: true

module Onair
  module Platform
    @registry = {}

    class << self
      def register(name, klass)
        @registry[name] = klass
      end

      def build(config, repo: nil)
        klass = @registry[config.platform]
        if klass.nil?
          raise Error,
            "unknown platform #{config.platform.inspect} (available: #{@registry.keys.join(", ")})"
        end

        klass.new(config, repo: repo)
      end
    end

    # Adapter contract: implement #snapshot returning a Snapshot.
    #
    #   deployed:         the release CURRENTLY RUNNING (nil sha only if
    #                     truly unresolvable)
    #   pending:          newest in-flight build, or nil
    #   release:          newest release above the running one that is not
    #                     running (release phase pending or failed), or nil
    #   latest_built_sha: newest successfully built sha, or nil
    #   succeeded_shas:   recent succeeded build shas, newest first
    #   rollout:          per process type, how many dynos run the running
    #                     release, plus an optional estimate of when the
    #                     previous release stops serving; nil when unknown
    #
    # Versions may be nil on every value, and pending/release shas may be nil
    # when the platform's builds carry no commit; renderers drop what is absent.
    #
    # Adapters own their internal concurrency and auth. Everything above
    # (delta, pinned, mine, rendering) is platform-agnostic and must not
    # reference any specific platform.
    class Base
      NO_APP = "no app configured - pass --app NAME, set HEROKU_APP, or run `onair init`"

      # `repo` is the GitHub repo (config or origin remote), or nil.
      def initialize(config, repo: nil)
        @config = config
        @repo = repo
      end

      def snapshot
        raise NotImplementedError
      end

      def display_name
        self.class.name.split("::").last
      end

      # What the report's header names next to the platform.
      def target_label
        @config.app
      end

      # The deploy environment the adapter reads, for platforms that have one.
      def environment
        nil
      end

      private

      # Exceptions surface via #value; without this the dying thread also
      # prints its own backtrace to stderr.
      def quiet_thread(&block)
        Thread.new do
          Thread.current.report_on_exception = false
          block.call
        end
      end
    end
  end
end
