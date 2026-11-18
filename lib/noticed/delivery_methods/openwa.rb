# frozen_string_literal: true

module Noticed
  module DeliveryMethods
    # deliver_by :openwa, url:, api_key:, session_id:, to:, text:, and optionally files:, location:, idempotency_key:,
    # ca_file:, after_send:, not_on_whatsapp:
    #
    # Each option is a value, a lambda (evaluated on the notification) or the name of a notifier method. `to` is a phone
    # number or a chat id; `files` is [{ content:, mimetype:, filename: }] (content may be a lambda); the idempotency key
    # defaults to the notification's, so a retried job never sends a message twice. `after_send` is called once every
    # message was sent, with OpenWA's answers, so the app can keep their ids and match the webhook's receipts to the
    # notification. `not_on_whatsapp` is called instead of failing the job when WhatsApp can't resolve the recipient, with
    # the chat id and the error, so the app can clear or flag the number.
    class Openwa < DeliveryMethod
      include Noticed::Openwa::Delivery

      required_options :url, :api_key, :session_id, :to, :text

      def deliver
        answers = send_to(evaluate_option(:to), evaluate_option(:idempotency_key) || default_idempotency_key)
        run_callback(:after_send, answers) unless answers.empty?
        answers
      end

      # The notification's id (an ephemeral notification has none: no key).
      def default_idempotency_key
        id = notification.id if notification.respond_to?(:id)
        "noticed-#{id}" if id
      end

      private

      def callback_record = notification
    end
  end
end

ActiveSupport.run_load_hooks :noticed_delivery_methods_openwa, Noticed::DeliveryMethods::Openwa
