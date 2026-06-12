# frozen_string_literal: true

module Onair
  module Platform
    @registry = {}

    class << self
      def register(name, klass)
        @registry[name] = klass
      end

      def build(config)
        klass = @registry[config.platform]
        if klass.nil?
          raise Error,
                "unknown platform #{config.platform.inspect} (available: #{@registry.keys.join(', ')})"
        end

        klass.new(config)
      end
    end

    # Adapter contract: implement #snapshot returning a Snapshot.
    #
    #   deployed:         the release CURRENTLY RUNNING (nil sha only if
    #                     truly unresolvable)
    #   pending:          newest in-flight build, or nil
    #   latest_built_sha: newest successfully built sha, or nil
    #   succeeded_shas:   recent succeeded build shas, newest first
    #
    # Adapters own their internal concurrency and auth. Everything above
    # (delta, pinned, mine, rendering) is platform-agnostic and must not
    # reference any specific platform.
    class Base
      def initialize(config)
        @config = config
      end

      def snapshot
        raise NotImplementedError
      end

      def display_name
        self.class.name.split("::").last
      end
    end
  end
end
