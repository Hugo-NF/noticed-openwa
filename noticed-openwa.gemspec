# frozen_string_literal: true

require_relative "lib/noticed/openwa/version"

Gem::Specification.new do |spec|
  spec.name = "noticed-openwa"
  spec.version = Noticed::Openwa::VERSION
  spec.authors = [ "Hugo-NF" ]
  spec.summary = "WhatsApp delivery for noticed through OpenWA"
  spec.description = "A noticed delivery method and a small client for OpenWA's REST API: sends a text, an image or " \
                     "a document to a number, and checks a number is on WhatsApp."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "noticed", ">= 2.0", "< 4"
end
