# frozen_string_literal: true

module Noticed
  module DeliveryMethods
    # deliver_by :openwa, url:, api_key:, session_id:, to:, text:, and optionally files:, idempotency_key:, ca_file:
    #
    # Each option is a value, a lambda (evaluated on the notification) or the name of a notifier method. `to` is a phone
    # number or a chat id; `files` is [{ content:, mimetype:, filename: }] (content may be a lambda); the idempotency key
    # defaults to the notification's, so a retried job never sends a message twice.
    class Openwa < DeliveryMethod
      required_options :url, :api_key, :session_id, :to, :text

      def deliver
        client.send_message(Noticed::Openwa::Client.chat_id(evaluate_option(:to)),
                            text: evaluate_option(:text),
                            files: Array(evaluate_option(:files)),
                            idempotency_key: evaluate_option(:idempotency_key) || default_idempotency_key)
      end

      # The notification's id (an ephemeral notification has none: no key).
      def default_idempotency_key
        id = notification.id if notification.respond_to?(:id)
        "noticed-#{id}" if id
      end

      def client
        Noticed::Openwa::Client.new(url: evaluate_option(:url), api_key: evaluate_option(:api_key),
                                    session_id: evaluate_option(:session_id), ca_file: evaluate_option(:ca_file))
      end
    end
  end
end

ActiveSupport.run_load_hooks :noticed_delivery_methods_openwa, Noticed::DeliveryMethods::Openwa
