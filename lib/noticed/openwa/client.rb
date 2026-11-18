# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"
require_relative "keys"

module Noticed
  module Openwa
    # The parts of OpenWA's REST API a delivery needs: sending a text, an image or a document to a chat, checking a
    # number is on WhatsApp, reading the session's status, and registering (or unregistering) the session's webhook.
    # Every call authenticates with the `X-API-Key` header, in the given session.
    class Client
      CHAT_SUFFIX = "@c.us"
      IDEMPOTENCY_KEY = /\A[\x21-\x7e]{1,255}\z/
      NETWORK_ERRORS = [ Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
                         SocketError, EOFError, IOError, OpenSSL::SSL::SSLError ].freeze
      NOT_ON_WHATSAPP = /not (?:a )?registered|not on whatsapp/i
      # A 404 for a quoted message OpenWA can't find (a send's quotedMessageId), not for the session.
      MESSAGE_NOT_FOUND = /\AMessage .+ not found/
      # A 400 for a session that isn't started: nothing was sent, and it can be started again.
      SESSION_NOT_STARTED = /session is not (?:started|active)/i
      # Digits long enough to be a number, kept out of error messages.
      NUMBER = /\d{6,}/
      # The audio WhatsApp plays in the chat; any other audio goes as a document.
      AUDIO_TYPES = %w[audio/mpeg audio/mp4 audio/aac audio/ogg audio/amr].freeze
      # What a voice note (OpenWA's ptt) must be: OGG with Opus.
      VOICE_NOTE_TYPE = "audio/ogg"

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

      # { state:, reason:, restriction:, raw: }: the session's status as OpenWA holds it (`ready`, `disconnected`,
      # `qr_ready`, ...: the states of `session.status` webhook events), why when it isn't working (OpenWA's
      # `lastError`), the restriction WhatsApp placed on its account ({ kind:, code:, expires_at: }, nil without one),
      # and OpenWA's answer. A restricted session can still be `ready`. An unknown session raises RequestError.
      def session_status
        body = request(Net::HTTP::Get, nil, operation: "session_status")
        restriction = body[:restriction]
        restriction &&= { kind: restriction[:kind], code: restriction[:code],
                          expires_at: restriction[:expires_at] && Time.iso8601(restriction[:expires_at]) }
        { state: body[:status], reason: body[:last_error], restriction:, raw: body }
      end

      # { exists:, whatsapp_id: }: whether WhatsApp has an account for the number, and the chat id it holds for it (it
      # can differ from the digits given), nil when it has none.
      def check_number(number)
        digits = number.to_s.delete("^0-9")
        raise ArgumentError, "the number has no digits" if digits.empty?

        body = request(Net::HTTP::Get, "contacts/check/#{digits}", operation: "check_number")
        { exists: body[:exists] == true, whatsapp_id: body[:whatsapp_id] }
      end

      # Each send returns OpenWA's answer and the chat it went to ({ message_id:, timestamp:, chat_id: }): the message
      # was handed to the session, not yet delivered. The idempotency key makes a retry with the same key and body replay
      # the first answer.
      def send_text(chat_id, text, link_preview: nil, quoted_message_id: nil, idempotency_key: nil)
        body = { chatId: chat_id, text:, linkPreview: link_preview, quotedMessageId: quoted_message_id }
        send_message_request("send-text", body, idempotency_key)
      end

      # content: the file's bytes, sent as base64.
      def send_image(chat_id, content:, mimetype:, caption: nil, quoted_message_id: nil, idempotency_key: nil)
        body = { chatId: chat_id, base64: Base64.strict_encode64(content), mimetype:, caption:,
                 quotedMessageId: quoted_message_id }
        send_message_request("send-image", body, idempotency_key)
      end

      # An MP4 (H.264 and AAC), which plays in the chat; other formats can't be counted on to, so send them as documents.
      def send_video(chat_id, content:, mimetype: "video/mp4", caption: nil, quoted_message_id: nil,
                     idempotency_key: nil)
        body = { chatId: chat_id, base64: Base64.strict_encode64(content), mimetype:, caption:,
                 quotedMessageId: quoted_message_id }
        send_message_request("send-video", body, idempotency_key)
      end

      # An audio file, played in the chat (one of AUDIO_TYPES), or a voice note (voice_note: true, an OGG with Opus):
      # WhatsApp shows no caption on either.
      def send_audio(chat_id, content:, mimetype:, voice_note: false, quoted_message_id: nil, idempotency_key: nil)
        check_voice_note!(mimetype) if voice_note
        body = { chatId: chat_id, base64: Base64.strict_encode64(content), mimetype:, ptt: (true if voice_note),
                 quotedMessageId: quoted_message_id }
        send_message_request("send-audio", body, idempotency_key)
      end

      # A map pin: description is the place's name, shown on the pin, and address the line under it.
      def send_location(chat_id, latitude:, longitude:, description: nil, address: nil, quoted_message_id: nil,
                        idempotency_key: nil)
        raise ArgumentError, "latitude and longitude are required" if latitude.nil? || longitude.nil?

        body = { chatId: chat_id, latitude: Float(latitude), longitude: Float(longitude), description:, address:,
                 quotedMessageId: quoted_message_id }
        send_message_request("send-location", body, idempotency_key)
      end

      def send_document(chat_id, content:, mimetype:, filename:, caption: nil, quoted_message_id: nil,
                        idempotency_key: nil)
        body = { chatId: chat_id, base64: Base64.strict_encode64(content), mimetype:, filename:, caption:,
                 quotedMessageId: quoted_message_id }
        send_message_request("send-document", body, idempotency_key)
      end

      # A text with its files: one message per file, the text as the last one's caption, where the chat shows it
      # without scrolling back over the others (images as images, MP4s as videos, AUDIO_TYPES as audio, the rest as
      # documents), or the text alone without files. WhatsApp shows no caption on audio: when the last file is audio, the
      # text follows the files as a message of its own. files: [{ content:, mimetype:, filename:, voice_note: }]; content
      # may be a lambda, called only when that file is sent. Each message's idempotency key is the given one, suffixed
      # with its position when there are files (`-text` for a text after them). quoted_message_id makes the message with
      # the text a reply to that message. Returns OpenWA's answers.
      def send_message(chat_id, text:, files: [], idempotency_key: nil, link_preview: nil, quoted_message_id: nil)
        return [ send_text(chat_id, text, link_preview:, quoted_message_id:, idempotency_key:) ] if files.empty?

        files.each { |file| check_voice_note!(file.fetch(:mimetype)) if file[:voice_note] }
        captioned = media_kind(files.last.fetch(:mimetype)) != :audio
        answers = files.each_with_index.map do |file, index|
          with_text = captioned && index == files.size - 1
          send_file(chat_id, file, caption: (text if with_text), quoted_message_id: (quoted_message_id if with_text),
                                   idempotency_key: idempotency_key && "#{idempotency_key}-#{index + 1}")
        end
        return answers if captioned

        answers << send_text(chat_id, text, link_preview:, quoted_message_id:,
                                            idempotency_key: idempotency_key && "#{idempotency_key}-text")
      end

      # The session's webhooks, as OpenWA returns them ({ id:, url:, events:, active:, ... }); never
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
        existing = listed.find { |webhook| webhook[:url] == url } if listed.is_a?(Array)
        if existing
          request(Net::HTTP::Put, "webhooks/#{URI.encode_www_form_component(existing[:id])}",
                  body: body.merge(active: true), operation: "register_webhook", secrets: [ secret ])
        else
          request(Net::HTTP::Post, "webhooks", body:, operation: "register_webhook", secrets: [ secret ])
        end
      end

      # Deletes the session's webhooks for url, every one of them. Returns how many were deleted: 0 when there was none.
      def unregister_webhook(url:)
        raise ArgumentError, "url is required" if blank?(url)

        listed = request(Net::HTTP::Get, "webhooks", operation: "unregister_webhook")
        matching = listed.is_a?(Array) ? listed.select { |webhook| webhook[:url] == url } : []
        matching.each do |webhook|
          request(Net::HTTP::Delete, "webhooks/#{URI.encode_www_form_component(webhook[:id])}",
                  operation: "unregister_webhook")
        end
        matching.size
      end

      private

      def send_file(chat_id, file, caption:, quoted_message_id:, idempotency_key:)
        content = file.fetch(:content)
        content = content.call if content.respond_to?(:call)
        mimetype = file.fetch(:mimetype)

        case media_kind(mimetype)
        when :image then send_image(chat_id, content:, mimetype:, caption:, quoted_message_id:, idempotency_key:)
        when :video then send_video(chat_id, content:, mimetype:, caption:, quoted_message_id:, idempotency_key:)
        when :audio
          send_audio(chat_id, content:, mimetype:, voice_note: file[:voice_note], quoted_message_id:, idempotency_key:)
        else
          send_document(chat_id, content:, mimetype:, filename: file.fetch(:filename), caption:, quoted_message_id:,
                                 idempotency_key:)
        end
      end

      # How a file of this type is sent: :image, :video, :audio or :document.
      def media_kind(mimetype)
        type = mimetype.to_s.split(";").first.to_s.strip.downcase
        if type.start_with?("image/") then :image
        elsif type == "video/mp4" then :video
        elsif AUDIO_TYPES.include?(type) then :audio
        else :document
        end
      end

      def check_voice_note!(mimetype)
        return if mimetype.to_s.split(";").first.to_s.strip.downcase == VOICE_NOTE_TYPE

        raise ArgumentError, "a voice note must be an OGG with Opus (#{VOICE_NOTE_TYPE})"
      end

      def send_message_request(endpoint, body, idempotency_key)
        if idempotency_key && !IDEMPOTENCY_KEY.match?(idempotency_key)
          raise ArgumentError, "the idempotency key must be 1-255 visible ASCII characters"
        end

        answer = request(Net::HTTP::Post, "messages/#{endpoint}", body: body.compact,
                                                                  headers: { "Idempotency-Key" => idempotency_key }.compact,
                                                                  operation: endpoint.tr("-", "_"))
        answer.merge(chat_id: body[:chatId])
      rescue QuotedMessageNotFoundError
        raise unless body[:quotedMessageId]

        # OpenWA sent nothing and released the key: the message goes again, without the quote.
        send_message_request(endpoint, body.except(:quotedMessageId), idempotency_key)
      end

      # secrets: values kept out of the error's message, should OpenWA's reason quote them.
      def request(method, path, operation:, body: nil, headers: {}, secrets: [])
        uri = URI([ "#{url}/api/sessions/#{URI.encode_www_form_component(session_id)}", path ].compact.join("/"))
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
        return Keys.symbolize(body) if status.between?(200, 299)

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
        when 404 then MESSAGE_NOT_FOUND.match?(messages(body)) ? QuotedMessageNotFoundError : RequestError
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
