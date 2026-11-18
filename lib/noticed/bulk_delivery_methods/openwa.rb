# frozen_string_literal: true

module Noticed
  module BulkDeliveryMethods
    # bulk_deliver_by :openwa, url:, api_key:, session_id:, to:, text:, and optionally files:, idempotency_key:, ca_file:,
    # after_send:
    #
    # Once per event, whatever its recipients: the message goes to `to`, a phone number or a chat id (a group's
    # included), or to each of a list of them. The options are those of `deliver_by :openwa`, evaluated on the event.
    # The idempotency key defaults to the event's; with a list, each chat's is suffixed by its position, so a retry
    # replays the chats already sent instead of sending them twice. `after_send` is called once every message was sent,
    # with OpenWA's answers for every chat, in order.
    class Openwa < BulkDeliveryMethod
      include Noticed::Openwa::Delivery

      required_options :url, :api_key, :session_id, :to, :text

      def deliver
        to = evaluate_option(:to)
        key = evaluate_option(:idempotency_key) || default_idempotency_key
        answers = if to.is_a?(Array)
          to.each_with_index.flat_map { |chat, index| send_to(chat, key && "#{key}-chat#{index + 1}") }
        else
          send_to(to, key)
        end
        after_send(answers) unless answers.empty?
        answers
      end

      # The event's id, apart from a notification's (`noticed-<id>`): the two can be equal. An ephemeral event has none:
      # no key.
      def default_idempotency_key
        id = event.id if event.respond_to?(:id)
        "noticed-event-#{id}" if id
      end

      private

      # As noticed's own callbacks do, a lambda is run on the event with the answers, and a notifier method gets the
      # event and the answers.
      def after_send(answers)
        callback = config[:after_send]
        if callback.respond_to?(:call)
          event.instance_exec(answers, &callback)
        elsif callback.is_a?(Symbol) && event.respond_to?(callback, true)
          event.send(callback, event, answers)
        end
      end
    end
  end
end

ActiveSupport.run_load_hooks :noticed_bulk_delivery_methods_openwa, Noticed::BulkDeliveryMethods::Openwa
