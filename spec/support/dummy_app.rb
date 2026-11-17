# frozen_string_literal: true

# noticed is a Rails engine: its delivery methods are Active Jobs, and its ephemeral notifiers use the app's routes.
require "rails"
require "active_job/railtie"
require "active_record/railtie"
require "noticed"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("../..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.active_job.queue_adapter = :test
    config.secret_key_base = "noticed-openwa-specs"
  end
end

Rails.application.initialize!
