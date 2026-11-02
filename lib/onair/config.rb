# frozen_string_literal: true

require "yaml"

module Onair
  # Resolution order: CLI flags → env vars → .onair.yml (searched upward
  # from cwd to the git root) → error with a hint to run `onair init`.
  class Config
    FILENAME = ".onair.yml"

    DEFAULT_ENVIRONMENT = "production"

    attr_reader :platform, :app, :repo, :branch, :fetch, :task, :host, :environment

    # `app`, `host` and `environment` are each read by the adapters that need
    # them; those adapters check them, so any may be nil elsewhere.
    def initialize(platform:, app:, repo:, branch:, fetch:, task: nil, host: nil, environment: nil)
      @platform = platform
      @host = host
      @environment = environment
      @app = app
      @repo = repo
      @branch = branch
      @fetch = fetch
      @task = task
    end

    def self.resolve(flags = {}, env: ENV, dir: Dir.pwd)
      file = find_file(dir) || {}
      platform = file["platform"] || "heroku"
      # HEROKU_APP names a Heroku app, so it must not redirect another platform.
      app = flags[:app] || ((platform == "heroku") ? env["HEROKU_APP"] : nil) || file["app"]

      new(
        platform: platform,
        app: app,
        repo: env["GITHUB_REPO"] || file["repo"],
        branch: file["branch"] || "main",
        fetch: !flags[:no_fetch],
        task: TaskLink.from_config(file["task"]),
        host: file["host"],
        environment: file["environment"] || DEFAULT_ENVIRONMENT
      )
    end

    def self.find_file(start)
      dir = File.expand_path(start)
      loop do
        path = File.join(dir, FILENAME)
        return YAML.safe_load_file(path) || {} if File.file?(path)
        return nil if File.exist?(File.join(dir, ".git"))

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end
  end
end
