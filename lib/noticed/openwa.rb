# frozen_string_literal: true

require "noticed"
require "noticed/openwa/version"
require "noticed/openwa/error"
require "noticed/openwa/client"
require "noticed/openwa/webhook"

module Noticed
  # The delivery method is loaded on first use (`deliver_by :openwa`): it's an Active Job, so it needs the app's jobs.
  module DeliveryMethods
    autoload :Openwa, "noticed/delivery_methods/openwa"
  end
end
