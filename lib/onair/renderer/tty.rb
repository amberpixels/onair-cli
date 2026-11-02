# frozen_string_literal: true

module Onair
  module Renderer
    # Pure function of Report + flags: no IO, snapshot-testable.
    class Tty
      COLORS = {
        bold: "\e[1m",
        green: "\e[0;32m",
        red: "\e[0;31m",
        yellow: "\e[1;33m",
        dim: "\e[2m",
        purple: "\e[38;5;176m",
        cyan: "\e[0;36m",
        reset: "\e[0m"
      }.freeze

      NOT_FOUND_SUBJECT = "(commit not found in local git)"
      LABEL_WIDTH = "Releasing:".length

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
        lines.concat(release_lines)
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

        if pending.sha.nil?
          started = pending.started_at && "started #{age(pending.started_at)}"
          return commitless_row("Pending:", :yellow, "build #{pending.build_id}", started,
            paint("⟳ deploying", :yellow)) + [""]
        end

        row_lines("Pending:", :yellow, pending.sha, age(pending.started_at)) + [""]
      end

      # Same-commit releases (config changes, rollbacks) name what they are,
      # since the sha alone would look like the deploy below.
      def release_lines
        release = snapshot.release
        return [] if release.nil?
        return build_failed_lines(release) if release.sha.nil?

        label, color, note = release.version.nil? ? versionless_release(release) : versioned_release(release)
        row_lines(label, color, release.sha, age(release.started_at), extra: paint(note, color)) + [""]
      end

      def versioned_release(release)
        detail = version_label(release.version)
        detail = [detail, release.description].compact.join(": ") if release.sha == snapshot.deployed&.sha
        if release.status == :failed
          ["Failed:", :red, "✗ release phase failed (#{detail})"]
        else
          ["Releasing:", :yellow, "⟳ release phase (#{detail})"]
        end
      end

      # A platform that numbers no releases names the deploy by its description.
      def versionless_release(release)
        if release.status == :failed
          ["Failed:", :red, "✗ deploy failed (#{release.description})"]
        else
          ["Releasing:", :yellow, "⟳ deploying (#{release.description})"]
        end
      end

      # A failed build whose commit the platform does not record.
      def build_failed_lines(release)
        commitless_row("Failed:", :red, release.description, age(release.started_at),
          paint("✗ build failed", :red)) + [""]
      end

      def deployed_lines
        deployed = snapshot.deployed
        return ["  #{paint("No deployments recorded yet.", :yellow)}"] if deployed.nil?

        if deployed.sha
          lines = row_lines("Deployed:", :green, deployed.sha, age(deployed.deployed_at), extra: delta_text)
          lines << rollout_line if @report.rollout
          lines << pinned_line if @report.pinned
          lines.concat(yours_lines)
          lines
        else
          subject = ["the running commit", version_label(deployed.version)].compact.join(" for ")
          ["  #{paint("Could not resolve #{subject} (#{deployed.description}).", :yellow)}"]
        end
      end

      # The dynos list can look finished while preboot still routes some
      # traffic to the previous release, so that window gets its own line.
      def rollout_line
        rollout = @report.rollout
        target = [version_label(rollout.version)].compact.map { |label| " #{label}" }.join
        text, color = if rollout.complete?
          ["✓ rolled out#{target}: #{process_counts(rollout)}", :dim]
        elsif rollout.processes.all?(&:complete?)
          ["⟳ #{rollout.overlap_note || "previous release may still serve"} for " \
           "~#{remaining(rollout.overlap_until)} (estimate)", :yellow]
        else
          ["⟳ rolling out#{target}: #{process_counts(rollout)}", :yellow]
        end
        "  #{paint(text, color)}"
      end

      def process_counts(rollout)
        rollout.processes.map do |process|
          parts = ["#{process.type} #{process.up}/#{process.total}"]
          parts.concat(process.waiting.map { |state, count| "#{count} #{state}" })
          parts << "#{process.previous} on older release" if process.previous.positive?
          parts.join(", ")
        end.join(" · ")
      end

      def remaining(time)
        seconds = (time - @now).ceil.clamp(0..)
        (seconds < 60) ? "#{seconds}s" : "#{(seconds / 60.0).ceil}m"
      end

      def yours_lines
        mine = @report.mine
        return [] if mine.nil?

        note = mine.had_own_build ? "✓ released, then absorbed by current" : "✓ absorbed by current deploy"
        committed_at = @report.commits[mine.sha]&.committed_at
        [""] + row_lines("Yours:", :cyan, mine.sha, age(committed_at), extra: paint(note, :cyan))
      end

      def row_lines(label, color_key, sha, age, extra: nil)
        info = @report.commits[sha]
        subject = info&.subject || NOT_FOUND_SUBJECT
        author = info&.author_name || "?"
        age_blurb = age ? "(#{age}) " : ""
        padded = label.ljust(LABEL_WIDTH)
        first = "  #{paint(padded, color_key)}  #{paint(sha[0, 9], :bold)}  #{paint("#{age_blurb}by #{author}", :dim)}"
        first = "#{first}  #{extra}" if extra
        [first, "  #{paint("→", :dim)} #{linkify(subject, info ? sha : nil)}"]
      end

      # A row for a build with no commit: its name stands where the sha would,
      # and there is no subject line to show.
      def commitless_row(label, color_key, name, age, extra)
        age_blurb = age ? "  #{paint("(#{age})", :dim)}" : ""
        ["  #{paint(label.ljust(LABEL_WIDTH), color_key)}  #{paint(name, :bold)}#{age_blurb}  #{extra}"]
      end

      def version_label(version)
        version && "v#{version}"
      end

      def delta_text
        case @report.delta
        when :current
          paint("★ current", :green)
        when Integer
          count = @report.delta
          paint("↓ #{count} #{(count == 1) ? "commit" : "commits"} behind origin/#{@branch}", :yellow)
        end
      end

      def pinned_line
        deployed = snapshot.deployed
        running = [version_label(deployed.version), "(#{deployed.description})"].compact.join(" ")
        "  #{paint("⏸ #{running} - newer build " \
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
