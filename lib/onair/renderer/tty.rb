# frozen_string_literal: true

module Onair
  module Renderer
    # Pure function of Report + flags: no IO, snapshot-testable.
    class Tty
      COLORS = {
        bold: "\e[1m",
        green: "\e[0;32m",
        yellow: "\e[1;33m",
        dim: "\e[2m",
        purple: "\e[38;5;176m",
        cyan: "\e[0;36m",
        reset: "\e[0m"
      }.freeze

      NOT_FOUND_SUBJECT = "(commit not found in local git)"

      def initialize(report:, app:, platform_label:, branch:, repo:, color:, hyperlinks:, now:, task: nil)
        @report = report
        @app = app
        @platform_label = platform_label
        @branch = branch
        @repo = repo
        @color = color
        @hyperlinks = hyperlinks
        @now = now
        @task = task
      end

      def render
        lines = ["", "  #{code(:purple)}#{@platform_label} #{code(:bold)}#{@app}#{code(:reset)}", ""]
        lines.concat(pending_lines)
        lines.concat(deployed_lines)
        lines << ""
        "#{lines.join("\n")}\n"
      end

      private

      def snapshot
        @report.snapshot
      end

      def pending_lines
        pending = snapshot.pending
        return [] if pending.nil?

        row_lines("Pending: ", :yellow, pending.sha, age(pending.started_at)) + [""]
      end

      def deployed_lines
        deployed = snapshot.deployed
        if deployed&.sha
          lines = row_lines("Deployed:", :green, deployed.sha, age(deployed.deployed_at), extra: delta_text)
          lines << pinned_line if @report.pinned
          lines.concat(yours_lines)
          lines
        else
          ["  #{paint("Could not resolve the running commit for v#{deployed&.version} " \
                      "(#{deployed&.description}).", :yellow)}"]
        end
      end

      def yours_lines
        mine = @report.mine
        return [] if mine.nil?

        note = mine.had_own_build ? "✓ released, then absorbed by current" : "✓ absorbed by current deploy"
        committed_at = @report.commits[mine.sha]&.committed_at
        [""] + row_lines("Yours:   ", :cyan, mine.sha, age(committed_at), extra: paint(note, :cyan))
      end

      def row_lines(label, color_key, sha, age, extra: nil)
        info = @report.commits[sha]
        subject = info&.subject || NOT_FOUND_SUBJECT
        author = info&.author_name || "?"
        age_blurb = age ? "(#{age}) " : ""
        first = "  #{paint(label, color_key)}  #{paint(sha[0, 9], :bold)}  #{paint("#{age_blurb}by #{author}", :dim)}"
        first = "#{first}  #{extra}" if extra
        [first, "  #{paint('→', :dim)} #{linkify(subject, info ? sha : nil)}"]
      end

      def delta_text
        case @report.delta
        when :current
          paint("★ current", :green)
        when Integer
          count = @report.delta
          paint("↓ #{count} #{count == 1 ? 'commit' : 'commits'} behind origin/#{@branch}", :yellow)
        end
      end

      def pinned_line
        deployed = snapshot.deployed
        "  #{paint("⏸ v#{deployed.version} (#{deployed.description}) — newer build " \
                   "#{snapshot.latest_built_sha[0, 9]} succeeded but is not running", :yellow)}"
      end

      # Subjects ending in " (#1234)" (merge convention) strip the suffix and
      # link to the PR; otherwise link the commit. Commits absent from the
      # local repo (sha == nil here) skip linking entirely.
      def linkify(subject, sha)
        if @repo && (match = subject.match(/\A(?<base>.*) \(#(?<pr>\d+)\)\z/))
          "#{tasked(match[:base])} • #{link("https://github.com/#{@repo}/pull/#{match[:pr]}", "↗ ##{match[:pr]}")}"
        elsif @repo && sha
          "#{tasked(subject)} • #{link("https://github.com/#{@repo}/commit/#{sha}", "↗ #{sha[0, 9]}")}"
        else
          tasked(subject)
        end
      end

      # Configured task ids stay visually identical — they just become clickable.
      def tasked(text)
        return text unless @task && @hyperlinks

        text.gsub(@task.pattern) { |task_id| link(@task.url_for(task_id), task_id) }
      end

      def link(url, text)
        @hyperlinks ? "\e]8;;#{url}\a#{text}\e]8;;\a" : text
      end

      def age(time)
        return nil if time.nil?

        seconds = (@now - time).to_i.clamp(0..)
        if seconds < 60 then "#{seconds}s ago"
        elsif seconds < 3600 then "#{seconds / 60}m ago"
        elsif seconds < 86_400 then "#{seconds / 3600}h ago"
        else "#{seconds / 86_400}d ago"
        end
      end

      def paint(text, key)
        @color ? "#{COLORS[key]}#{text}#{COLORS[:reset]}" : text
      end

      def code(key)
        @color ? COLORS[key] : ""
      end
    end
  end
end
