# frozen_string_literal: true

require "yaml"

module Onair
  # Resolution order: CLI flags → env vars → .onair.yml (searched upward
  # from cwd to the git root) → error with a hint to run `onair init`.
  class Config
    FILENAME = ".onair.yml"

    attr_reader :platform, :app, :repo, :branch, :fetch

    def initialize(platform:, app:, repo:, branch:, fetch:)
      @platform = platform
      @app = app
      @repo = repo
      @branch = branch
      @fetch = fetch
    end

    def self.resolve(flags = {}, env: ENV, dir: Dir.pwd)
      file = find_file(dir) || {}
      app = flags[:app] || env["HEROKU_APP"] || file["app"]
      raise Error, "no app configured — pass --app NAME, set HEROKU_APP, or run `onair init`" if app.nil?

      new(
        platform: file["platform"] || "heroku",
        app: app,
        repo: env["GITHUB_REPO"] || file["repo"],
        branch: file["branch"] || "main",
        fetch: !flags[:no_fetch]
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
