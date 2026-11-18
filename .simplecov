# frozen_string_literal: true

require "simplecov-json"

# Loaded by `require "simplecov"` (spec/spec_helper.rb). Only the gem's code is measured: lib/, every file of it, even
# one no spec loads.
SimpleCov.configure do
  cover "lib/**/*.rb"
  # Loaded by the gemspec, before SimpleCov starts: never measured. A placeholder the release workflow fills.
  skip "lib/noticed/openwa/version.rb"

  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::JSONFormatter
  ])
end
