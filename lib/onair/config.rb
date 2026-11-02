# frozen_string_literal: true

require "yaml"

module Onair
  # Resolution order: CLI flags → env vars → .onair.yml (searched upward
  # from cwd to the git root) → error with a hint to run `onair init`.
  class Config
    FILENAME = ".onair.yml"

    attr_reader :platform, :app, :repo, :branch, :fetch, :task, :host

    # `host` is the SSH destination for SSH-driven platforms (Dokku); nil
    # elsewhere, and only the adapter that needs it checks it.
    def initialize(platform:, app:, repo:, branch:, fetch:, task: nil, host: nil)
      @platform = platform
      @host = host
      @app = app
      @repo = repo
      @branch = branch
      @fetch = fetch
      @task = task
    end

    def self.resolve(flags = {}, env: ENV, dir: Dir.pwd)
      file = find_file(dir) || {}
      app = flags[:app] || env["HEROKU_APP"] || file["app"]
      raise Error, "no app configured - pass --app NAME, set HEROKU_APP, or run `onair init`" if app.nil?

      new(
        platform: file["platform"] || "heroku",
        app: app,
        repo: env["GITHUB_REPO"] || file["repo"],
        branch: file["branch"] || "main",
        fetch: !flags[:no_fetch],
        task: TaskLink.from_config(file["task"]),
        host: file["host"]
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
