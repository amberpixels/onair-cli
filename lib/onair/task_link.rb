# frozen_string_literal: true

module Onair
  # Optional, tracker-agnostic task linking. Configured entirely by the user:
  #
  #   task:
  #     pattern: 'ABC-\d+'
  #     url: 'https://acme.atlassian.net/browse/{task}'
  #
  # Any regex match in a commit subject becomes a link to the templated URL
  # ({task} is replaced with the matched text). No config — no behavior.
  TaskLink = Data.define(:pattern, :url_template) do
    def self.from_config(section)
      return nil if section.nil?

      pattern = section["pattern"].to_s
      url = section["url"].to_s
      raise Error, "task config needs both `pattern` and `url`" if pattern.empty? || url.empty?
      raise Error, "task.url must contain the {task} placeholder" unless url.include?("{task}")

      new(pattern: Regexp.new(pattern), url_template: url)
    rescue RegexpError => e
      raise Error, "invalid task.pattern: #{e.message}"
    end

    def find(subject)
      subject&.[](pattern)
    end

    def url_for(task_id)
      url_template.gsub("{task}", task_id)
    end
  end
end
