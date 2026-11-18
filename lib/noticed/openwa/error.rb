# frozen_string_literal: true

module Noticed
  module Openwa
    # An error of OpenWA's API: its HTTP status (nil when no response came back) and its stable `code`, when it sends
    # one. The message names the operation, the status and the code, never the request: it holds numbers and texts.
    class Error < StandardError
      attr_reader :status, :code, :retry_after

      def initialize(message = nil, status: nil, code: nil, retry_after: nil)
        @status = status
        @code = code
        @retry_after = retry_after
        super(message)
      end
    end

    # The API key is missing, unknown, revoked or expired, or its scope doesn't allow the call (401, 403).
    class AuthenticationError < Error; end

    # WhatsApp can't resolve the recipient for this session: the number has no WhatsApp account, or WhatsApp Web won't
    # give its id (its LID) to this session, which can happen with a number the session never had a chat with. OpenWA
    # can't tell the two apart. Nothing was sent; retrying right away gets the same answer.
    class NotOnWhatsappError < Error; end

    # Nothing was sent, and the same call can be made again: the session isn't ready, a rate limit, a timeout, OpenWA or
    # WhatsApp unavailable, or the same idempotency key still in progress.
    class RetryableError < Error; end

    # The message may have been sent (`IDEMPOTENCY_OUTCOME_UNKNOWN`): retrying with the same key gets the same answer,
    # and a new key may send it twice.
    class UnknownOutcomeError < Error; end

    # OpenWA refused the request itself (an invalid number, file or body).
    class RequestError < Error; end

    # The message a send quotes (quoted_message_id) isn't one OpenWA can find (404): nothing was sent. The client's
    # sends send it again without the quote, so it only reaches the app from a call that can't.
    class QuotedMessageNotFoundError < RequestError; end

    # A webhook delivery whose `X-OpenWA-Signature` is missing, malformed or not the body's: don't trust it.
    class InvalidSignatureError < Error; end
  end
end
