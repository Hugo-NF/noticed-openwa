# frozen_string_literal: true

module Noticed
  module Openwa
    # What `deliver_by :openwa` and `bulk_deliver_by :openwa` share: the client their options configure, sending the text
    # with its files to one chat, and their callbacks. The class that includes it is a noticed delivery method, with
    # `evaluate_option`, and names what its callbacks run on (`callback_record`: the notification, or the event).
    module Delivery
      def client
        @client ||= Client.new(url: evaluate_option(:url), api_key: evaluate_option(:api_key),
                               session_id: evaluate_option(:session_id), ca_file: evaluate_option(:ca_file))
      end

      private

      # OpenWA's answers for the message sent to `to`, a phone number or a chat id: the location first, when there's
      # one (a pin with its own description), then the text and the files; the message with the text replies to
      # `reply_to`, when given. A chat WhatsApp can't resolve goes to
      # `not_on_whatsapp` when the app gives one, instead of failing the job: nothing more is sent. Without it, the
      # error is raised.
      def send_to(to, idempotency_key)
        chat_id = Client.chat_id(to)
        answers = send_location_to(chat_id, idempotency_key)
        answers + client.send_message(chat_id, text: evaluate_option(:text), files: Array(evaluate_option(:files)),
                                               quoted_message_id: evaluate_option(:reply_to), idempotency_key:)
      rescue NotOnWhatsappError => e
        raise unless config[:not_on_whatsapp]

        run_callback(:not_on_whatsapp, chat_id, e)
        []
      end

      # The pin of the `location` option, before the message: none without one.
      def send_location_to(chat_id, idempotency_key)
        location = evaluate_option(:location)
        return [] unless location

        location = location.to_h.slice(:latitude, :longitude, :description, :address)
        [ client.send_location(chat_id, **location, idempotency_key: idempotency_key && "#{idempotency_key}-location") ]
      end

      # evaluate_option passes no arguments: as noticed's own callbacks (fcm's invalid_token), a lambda is run on the
      # record with the arguments, and a notifier method gets the record and the arguments.
      def run_callback(name, *arguments)
        callback = config[name]
        if callback.respond_to?(:call)
          callback_record.instance_exec(*arguments, &callback)
        elsif callback.is_a?(Symbol) && event.respond_to?(callback, true)
          event.send(callback, callback_record, *arguments)
        end
      end
    end
  end
end
