# frozen_string_literal: true

module Onair
  module Auth
    # Minimal ~/.netrc reader — just enough to pull the token the Heroku CLI
    # stores under `machine api.heroku.com`. Handles both same-line and
    # multi-line entry styles (the format is whitespace-token based).
    module Netrc
      def self.token(host, path: File.join(Dir.home, ".netrc"))
        return nil unless File.readable?(path)

        tokens = File.read(path).split(/\s+/)
        tokens.each_with_index do |word, index|
          return password_after(tokens, index + 2) if word == "machine" && tokens[index + 1] == host
        end
        nil
      end

      def self.password_after(tokens, start)
        tokens[start..].each_slice(2) do |key, value|
          return nil if ["machine", "default", nil].include?(key)
          return value if key == "password"
        end
        nil
      end
      private_class_method :password_after
    end
  end
end
