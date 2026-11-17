# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module Noticed
  module Openwa
    # The parts of OpenWA's REST API a delivery needs: sending a text, an image or a document to a chat, checking a
    # number is on WhatsApp, and registering (or unregistering) the session's webhook. Every call authenticates with the `X-API-Key`
    # header, in the given session.
    class Client
      CHAT_SUFFIX = "@c.us"
      IDEMPOTENCY_KEY = /\A[\x21-\x7e]{1,255}\z/
      NETWORK_ERRORS = [ Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
                         SocketError, EOFError, IOError, OpenSSL::SSL::SSLError ].freeze
      NOT_ON_WHATSAPP = /not (?:a )?registered|not on whatsapp/i
      # A 400 for a session that isn't started: nothing was sent, and it can be started again.
      SESSION_NOT_STARTED = /session is not (?:started|active)/i
      # Digits long enough to be a number, kept out of error messages.
      NUMBER = /\d{6,}/

      attr_reader :url, :session_id

      # ca_file: a CA bundle to trust, for an OpenWA behind a certificate of a private CA.
      def initialize(url:, api_key:, session_id:, open_timeout: 5, read_timeout: 60, ca_file: nil)
        raise ArgumentError, "url, api_key and session_id are required" if [ url, api_key, session_id ].any? { blank?(_1) }

        @url = url.to_s.chomp("/")
        @api_key = api_key
        @session_id = session_id
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @ca_file = ca_file
      end

      # The chat id of a number (any punctuation and a leading + are dropped); a chat id is returned as it is.
      def self.chat_id(number)
        number = number.to_s
        number.include?("@") ? number : "#{number.delete('^0-9')}#{CHAT_SUFFIX}"
      end

      # { exists:, whatsapp_id: }: whether WhatsApp has an account for the number, and the chat id it holds for it (it
      # can differ from the digits given), nil when it has none.
      def check_number(number)
        digits = number.to_s.delete("^0-9")
        raise ArgumentError, "the number has no digits" if digits.empty?

        body = request(Net::HTTP::Get, "contacts/check/#{digits}", operation: "check_number")
        { exists: body["exists"] == true, whatsapp_id: body["whatsappId"] }
      end

      # Each send returns OpenWA's answer ({ "messageId" =>, "timestamp" => }): the message was handed to the session,
      # not yet delivered. The idempotency key makes a retry with the same key and body replay the first answer.
      def send_text(chat_id, text, link_preview: nil, idempotency_key: nil)
        send_message_request("send-text", { chatId: chat_id, text:, linkPreview: link_preview }, idempotency_key)
      end

      # content: the file's bytes, sent as base64.
      def send_image(chat_id, content:, mimetype:, caption: nil, idempotency_key: nil)
        body = { chatId: chat_id, base64: Base64.strict_encode64(content), mimetype:, caption: }
        send_message_request("send-image", body, idempotency_key)
      end

      def send_document(chat_id, content:, mimetype:, filename:, caption: nil, idempotency_key: nil)
        body = { chatId: chat_id, base64: Base64.strict_encode64(content), mimetype:, filename:, caption: }
        send_message_request("send-document", body, idempotency_key)
      end

      # A text with its files: one message per file, the text as the first one's caption (images as images, the rest as
      # documents), or the text alone without files. files: [{ content:, mimetype:, filename: }]; content may be a
      # lambda, called only when that file is sent. Each message's idempotency key is the given one, suffixed with its
      # position when there are files. Returns OpenWA's answers.
      def send_message(chat_id, text:, files: [], idempotency_key: nil, link_preview: nil)
        return [ send_text(chat_id, text, link_preview:, idempotency_key:) ] if files.empty?

        files.each_with_index.map do |file, index|
          send_file(chat_id, file, caption: index.zero? ? text : nil,
                                   idempotency_key: idempotency_key && "#{idempotency_key}-#{index + 1}")
        end
      end

      # The session's webhooks, as OpenWA returns them ({ "id" =>, "url" =>, "events" =>, "active" =>, ... }); never
      # their secrets or headers.
      def webhooks
        request(Net::HTTP::Get, "webhooks", operation: "webhooks")
      end

      # Registers the session's webhook for url, safe to call on every deploy: the first webhook with the same url is
      # updated (and activated again), otherwise one is created. secret signs every delivery (`X-OpenWA-Signature`);
      # headers, when given, replace the stored ones. Returns the webhook.
      def register_webhook(url:, secret:, events:, retry_count: nil, headers: nil)
        raise ArgumentError, "url, secret and events are required" if blank?(url) || blank?(secret) || Array(events).empty?

        body = { url:, events: Array(events), secret:, headers:, retryCount: retry_count }.compact
        listed = request(Net::HTTP::Get, "webhooks", operation: "register_webhook")
        existing = listed.find { |webhook| webhook["url"] == url } if listed.is_a?(Array)
        if existing
          request(Net::HTTP::Put, "webhooks/#{URI.encode_www_form_component(existing['id'])}",
                  body: body.merge(active: true), operation: "register_webhook", secrets: [ secret ])
        else
          request(Net::HTTP::Post, "webhooks", body:, operation: "register_webhook", secrets: [ secret ])
        end
      end

      # Deletes the session's webhooks for url, every one of them. Returns how many were deleted: 0 when there was none.
      def unregister_webhook(url:)
        raise ArgumentError, "url is required" if blank?(url)

        listed = request(Net::HTTP::Get, "webhooks", operation: "unregister_webhook")
        matching = listed.is_a?(Array) ? listed.select { |webhook| webhook["url"] == url } : []
        matching.each do |webhook|
          request(Net::HTTP::Delete, "webhooks/#{URI.encode_www_form_component(webhook['id'])}",
                  operation: "unregister_webhook")
        end
        matching.size
      end

      private

      def send_file(chat_id, file, caption:, idempotency_key:)
        content = file.fetch(:content)
        content = content.call if content.respond_to?(:call)
        mimetype = file.fetch(:mimetype)

        if mimetype.start_with?("image/")
          send_image(chat_id, content:, mimetype:, caption:, idempotency_key:)
        else
          send_document(chat_id, content:, mimetype:, filename: file.fetch(:filename), caption:, idempotency_key:)
        end
      end

      def send_message_request(endpoint, body, idempotency_key)
        if idempotency_key && !IDEMPOTENCY_KEY.match?(idempotency_key)
          raise ArgumentError, "the idempotency key must be 1-255 visible ASCII characters"
        end

        request(Net::HTTP::Post, "messages/#{endpoint}", body: body.compact,
                                                         headers: { "Idempotency-Key" => idempotency_key }.compact,
                                                         operation: endpoint.tr("-", "_"))
      end

      # secrets: values kept out of the error's message, should OpenWA's reason quote them.
      def request(method, path, operation:, body: nil, headers: {}, secrets: [])
        uri = URI("#{url}/api/sessions/#{URI.encode_www_form_component(session_id)}/#{path}")
        request = method.new(uri, headers.merge("X-API-Key" => @api_key, "Accept" => "application/json"))
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end

        handle(http(uri).request(request), operation, secrets)
      rescue *NETWORK_ERRORS => e
        raise RetryableError, "OpenWA #{operation}: #{e.class}"
      end

      def http(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http.ca_file = @ca_file if @ca_file
        end
      end

      def handle(response, operation, secrets)
        status = response.code.to_i
        body = parse(response.body)
        return body if status.between?(200, 299)

        body = {} unless body.is_a?(Hash)
        raise error_class(status, body).new(error_message(operation, status, body, secrets),
                                            status:, code: body["code"], retry_after: retry_after(response, body))
      end

      def error_class(status, body)
        case status
        when 401, 403 then AuthenticationError
        when 409 then body["code"] == "IDEMPOTENCY_OUTCOME_UNKNOWN" ? UnknownOutcomeError : RetryableError
        when 408, 429, 500.. then RetryableError
        when 400 then client_error_class(body)
        else RequestError
        end
      end

      def client_error_class(body)
        case messages(body)
        when SESSION_NOT_STARTED then RetryableError
        when NOT_ON_WHATSAPP then NotOnWhatsappError
        else RequestError
        end
      end

      def error_message(operation, status, body, secrets)
        details = secrets.reduce(messages(body)) { |text, secret| text.gsub(secret.to_s, "[FILTERED]") }
        details = details.gsub(NUMBER, "[FILTERED]")
        [ "OpenWA #{operation}: #{status}", body["code"], (details unless details.empty?) ].compact.join(" ")
      end

      def messages(body) = Array(body["message"]).join("; ")

      def retry_after(response, body)
        seconds = body["retryAfterSeconds"] || response["Retry-After"]
        Integer(seconds.to_s, 10, exception: false)
      end

      def parse(body)
        parsed = body.to_s.empty? ? {} : JSON.parse(body)
        parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def blank?(value) = value.nil? || value.to_s.strip.empty?
    end
  end
end
