# frozen_string_literal: true

module Noticed
  module Openwa
    # What `deliver_by :openwa` and `bulk_deliver_by :openwa` share: the client their options configure, and sending the
    # text with its files to one chat. The class that includes it is a noticed delivery method, with `evaluate_option`.
    module Delivery
      def client
        @client ||= Client.new(url: evaluate_option(:url), api_key: evaluate_option(:api_key),
                               session_id: evaluate_option(:session_id), ca_file: evaluate_option(:ca_file))
      end

      private

      # OpenWA's answers for the message sent to `to`, a phone number or a chat id.
      def send_to(to, idempotency_key)
        client.send_message(Client.chat_id(to), text: evaluate_option(:text), files: Array(evaluate_option(:files)),
                                                idempotency_key:)
      end
    end
  end
end
