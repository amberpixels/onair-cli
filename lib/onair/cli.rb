# frozen_string_literal: true

require "optparse"

module Onair
  # Errors are rescued here and printed as a single friendly line — no
  # backtraces (--debug re-raises). Returns the process exit code.
  class CLI
    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      flags, command = parse(argv)
      case command
      when nil then status(flags)
      when "init" then init(flags)
      else raise Error, "unknown command: #{command} (try `onair --help`)"
      end
      0
    rescue OptionParser::ParseError => e
      warn_error(e.message)
      1
    rescue Error => e
      raise if flags&.[](:debug)

      warn_error(e.message)
      1
    end

    private

    def parse(argv)
      flags = {}
      parser = OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Usage: onair [command] [options]

          Commands:
              (none)           status report for the configured app
              init             write .onair.yml for this repo

          Options:
        BANNER
        opts.on("--app NAME", "override the app for this invocation") { |value| flags[:app] = value }
        opts.on("--json", "machine-readable status") { flags[:json] = true }
        opts.on("--no-fetch", "never fetch git objects from the remote") { flags[:no_fetch] = true }
        opts.on("--justfile", "with init: append a `prod` recipe to the justfile") { flags[:justfile] = true }
        opts.on("--debug", "re-raise errors with backtraces") { flags[:debug] = true }
        opts.on("--version", "print version") do
          puts VERSION
          exit 0
        end
        opts.on("-h", "--help", "print this help") do
          puts opts
          exit 0
        end
      end
      [flags, parser.parse(argv).first]
    end

    def status(flags)
      config = Config.resolve(flags)
      git = Git.new(fetch_allowed: config.fetch)
      adapter = Platform.build(config)
      repo = config.repo || git.origin_repo
      report = Orchestrator.new(config: config, adapter: adapter, git: git, repo: repo).run

      if flags[:json]
        puts Renderer::Json.new(report: report, app: config.app, platform: config.platform,
                                branch: config.branch, repo: repo, task: config.task).render
      else
        tty = $stdout.tty?
        print Renderer::Tty.new(report: report, app: config.app, platform_label: adapter.display_name,
                                branch: config.branch, repo: repo, task: config.task,
                                color: tty && !no_color?, hyperlinks: tty, now: Time.now).render
      end
    end

    def init(flags)
      path = File.join(Dir.pwd, Config::FILENAME)
      raise Error, "#{Config::FILENAME} already exists" if File.exist?(path)

      app = flags[:app] || ENV.fetch("HEROKU_APP", nil)
      raise Error, "pass --app NAME to seed the config" if app.nil?

      git = Git.new
      lines = ["platform: heroku", "app: #{app}"]
      repo = git.origin_repo
      lines << "repo: #{repo}" if repo
      lines << "branch: main"
      File.write(path, "#{lines.join("\n")}\n")
      puts "wrote #{Config::FILENAME}"
      append_justfile if flags[:justfile]
    end

    def append_justfile
      path = %w[justfile Justfile .justfile].find { |name| File.exist?(name) } || "justfile"
      existing = File.exist?(path) ? File.read(path) : ""
      raise Error, "#{path} already has a `prod` recipe" if existing.match?(/^prod:/)

      recipe = "prod:\n    @onair\n"
      content = existing.empty? ? recipe : "#{existing.chomp}\n\n#{recipe}"
      File.write(path, content)
      puts "added `prod` recipe to #{path}"
    end

    def warn_error(message)
      if $stderr.tty? && !no_color?
        warn "\n  \e[1;33merror: #{message}\e[0m"
      else
        warn "\n  error: #{message}"
      end
    end

    def no_color?
      !ENV["NO_COLOR"].to_s.empty?
    end
  end
end
