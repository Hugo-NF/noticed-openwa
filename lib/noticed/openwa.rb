# frozen_string_literal: true

require "noticed"
require "noticed/openwa/version"
require "noticed/openwa/error"
require "noticed/openwa/client"
require "noticed/openwa/webhook"
require "noticed/openwa/delivery"

module Noticed
  # The delivery methods are loaded on first use (`deliver_by :openwa`, `bulk_deliver_by :openwa`): they're Active Jobs,
  # so they need the app's jobs.
  module DeliveryMethods
    autoload :Openwa, "noticed/delivery_methods/openwa"
  end

  module BulkDeliveryMethods
    autoload :Openwa, "noticed/bulk_delivery_methods/openwa"
  end
end
