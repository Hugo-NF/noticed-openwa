# frozen_string_literal: true

module Noticed
  module DeliveryMethods
    # deliver_by :openwa, url:, api_key:, session_id:, to:, text:, and optionally files:, idempotency_key:, ca_file:,
    # after_send:
    #
    # Each option is a value, a lambda (evaluated on the notification) or the name of a notifier method. `to` is a phone
    # number or a chat id; `files` is [{ content:, mimetype:, filename: }] (content may be a lambda); the idempotency key
    # defaults to the notification's, so a retried job never sends a message twice. `after_send` is called once every
    # message was sent, with OpenWA's answers, so the app can keep their ids and match the webhook's receipts to the
    # notification.
    class Openwa < DeliveryMethod
      required_options :url, :api_key, :session_id, :to, :text

      def deliver
        answers = client.send_message(Noticed::Openwa::Client.chat_id(evaluate_option(:to)),
                                      text: evaluate_option(:text),
                                      files: Array(evaluate_option(:files)),
                                      idempotency_key: evaluate_option(:idempotency_key) || default_idempotency_key)
        after_send(answers)
        answers
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

      private

      # evaluate_option passes no arguments: like noticed's own callbacks (fcm's invalid_token), a lambda is run on the
      # notification with the answers, and a notifier method gets the notification and the answers.
      def after_send(answers)
        callback = config[:after_send]
        if callback.respond_to?(:call)
          notification.instance_exec(answers, &callback)
        elsif callback.is_a?(Symbol) && event.respond_to?(callback, true)
          event.send(callback, notification, answers)
        end
      end
    end
  end
end

ActiveSupport.run_load_hooks :noticed_delivery_methods_openwa, Noticed::DeliveryMethods::Openwa
