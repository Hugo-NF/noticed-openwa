# frozen_string_literal: true

require "json"
require "openssl"
require "time"

module Noticed
  module Openwa
    # OpenWA's webhook deliveries: verifying their signature and turning their body into an Event. The app keeps the
    # route, the controller and what each event means; nothing here holds state.
    module Webhook
      SIGNATURE_HEADER = "X-OpenWA-Signature"
      IDEMPOTENCY_KEY_HEADER = "X-OpenWA-Idempotency-Key"
      SIGNATURE = /\Asha256=(\h{64})\z/i
      # OpenWA also sends `message.failed` beside the `failed` ack, under another idempotency key: only the ack is
      # parsed, so a failure is one event.
      MESSAGE_STATUSES = %w[sent delivered read failed].freeze

      # type: :message_status or :session_state. event: OpenWA's event (`message.ack`, `session.status`, ...).
      # details: the session event's own fields (attempts, kind, code, expires_at, ...). payload: the delivery's body.
      Event = Data.define(:type, :event, :idempotency_key, :occurred_at, :session_id, :message_id, :chat_id, :status,
                          :state, :reason, :details, :payload) do
        def initialize(type:, event:, idempotency_key:, occurred_at:, session_id:, payload:, message_id: nil,
                       chat_id: nil, status: nil, state: nil, reason: nil, details: {})
          super
        end

        def message_status? = type == :message_status

        def session_state? = type == :session_state
      end

      class << self
        # Raises InvalidSignatureError unless the `X-OpenWA-Signature` header is the HMAC-SHA256 of the raw body with
        # the webhook's secret. raw_body: the request's body as received, before any parsing. headers: a hash (any
        # case), Rails' request.headers or a Rack env. There's no timestamp to check: retries and redrives keep the
        # first one, so the app dedupes on the event's idempotency key instead.
        def verify!(raw_body, headers, secret)
          raise ArgumentError, "the webhook's secret is required" if secret.to_s.empty?

          given = header(headers, SIGNATURE_HEADER).to_s.strip[SIGNATURE, 1]
          raise InvalidSignatureError, "OpenWA webhook: no valid #{SIGNATURE_HEADER} header" unless given

          expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, raw_body.to_s)
          unless OpenSSL.fixed_length_secure_compare(expected, given.downcase)
            raise InvalidSignatureError, "OpenWA webhook: the signature doesn't match the body"
          end

          true
        end

        # The delivery's Event, or nil for an event it doesn't handle (it isn't an error: the webhook may subscribe to
        # more). Raises Error for a body that isn't OpenWA's. Verify the delivery first.
        def parse(raw_body, headers = {})
          body = parse_json(raw_body)
          data = body["data"].is_a?(Hash) ? body["data"] : {}
          fields = event_fields(body["event"].to_s, data)
          return unless fields

          Event.new(event: body["event"], session_id: body["sessionId"] || data["sessionId"],
                    idempotency_key: body["idempotencyKey"] || header(headers, IDEMPOTENCY_KEY_HEADER),
                    occurred_at: time(body["timestamp"]), payload: body, **fields)
        end

        private

        def event_fields(event, data)
          case event
          when "message.ack" then message_fields(data)
          when "session.status" then session_fields(data["status"])
          when "session.disconnected" then session_fields("disconnected", reason: data["reason"])
          when "session.reconnect_loop"
            session_fields("reconnecting", details: { attempts: data["attempts"], next_delay_ms: data["nextDelayMs"] })
          when "session.restriction" then restriction_fields(data)
          end
        end

        def message_fields(data)
          status = data["status"].to_s
          return unless MESSAGE_STATUSES.include?(status)

          { type: :message_status, message_id: data["messageId"] || data["id"], chat_id: data["chatId"], status: }
        end

        def session_fields(state, reason: nil, details: {})
          return if state.to_s.empty?

          { type: :session_state, state: state.to_s, reason:, details: }
        end

        def restriction_fields(data)
          expires_at = data["expiresAt"] && time(data["expiresAt"])
          session_fields(data["active"] == false ? "unrestricted" : "restricted",
                         details: { kind: data["kind"], code: data["code"], expires_at: })
        end

        def parse_json(raw_body)
          body = JSON.parse(raw_body.to_s)
          openwa_event = body.is_a?(Hash) && body["event"].is_a?(String)
          raise Error, "OpenWA webhook: the body isn't an OpenWA event" unless openwa_event

          body
        rescue JSON::ParserError
          raise Error, "OpenWA webhook: the body isn't JSON"
        end

        def time(value)
          Time.iso8601(value.to_s)
        rescue ArgumentError
          raise Error, "OpenWA webhook: the timestamp isn't ISO 8601"
        end

        # Rails' request.headers and a Hash answer by name; a Rack env by its HTTP_ key; any other hash in any case.
        def header(headers, name)
          return if headers.nil?

          value = headers[name] || headers["HTTP_#{name.upcase.tr('-', '_')}"]
          return value if value || !headers.respond_to?(:each_pair)

          headers.each_pair { |key, each| return each if key.to_s.casecmp?(name) }
          nil
        end
      end
    end
  end
end
