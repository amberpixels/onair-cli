# frozen_string_literal: true

require_relative "lib/onair/version"

Gem::Specification.new do |spec|
  spec.name = "onair-cli"
  spec.version = Onair::VERSION
  spec.authors = ["Eugene"]
  spec.email = ["amber.pixels.io@gmail.com"]

  spec.summary = "See what's on air in production."
  spec.description = "Reports which commit is actually running in production and where it sits " \
                     "relative to origin/main. Truthful after rollbacks, fast, zero runtime dependencies."
  spec.homepage = "https://github.com/amberpixels/onair-cli"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["onair"]
  spec.require_paths = ["lib"]
end
