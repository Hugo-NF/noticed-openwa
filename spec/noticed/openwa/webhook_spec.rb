# frozen_string_literal: true

RSpec.describe Noticed::Openwa::Webhook do
  let(:secret) { OpenwaSpecSupport::WEBHOOK_FIXTURE_SECRET }

  # A delivery a recording can't trigger on demand, built as OpenWA's code builds it, and signed with the specs' secret.
  def built_delivery(event, data)
    body = JSON.generate(event:, timestamp: "2026-11-17T21:10:00.000Z", sessionId: "openwa-session-test",
                         idempotencyKey: "built_#{event}", deliveryId: "dlv_built",
                         data: { sessionId: "openwa-session-test", **data })
    [ body, { "X-OpenWA-Signature" => "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}" } ]
  end

  describe ".verify!" do
    let(:delivery) { OpenwaSpecSupport.webhook_delivery("message_ack_read") }
    let(:body) { delivery.first }
    let(:headers) { delivery.last }
    let(:signature) { headers.fetch("X-OpenWA-Signature") }

    it "accepts every recorded delivery", :aggregate_failures do
      OpenwaSpecSupport.webhook_fixtures.each do |name|
        expect(described_class.verify!(*OpenwaSpecSupport.webhook_delivery(name), secret)).to be(true)
      end
    end

    it "finds the signature in a Rack env" do
      expect(described_class.verify!(body, { "HTTP_X_OPENWA_SIGNATURE" => signature }, secret)).to be(true)
    end

    it "finds the signature in any case" do
      expect(described_class.verify!(body, { "x-openwa-signature" => signature }, secret)).to be(true)
    end

    it "refuses a tampered body" do
      expect { described_class.verify!(body.sub('"read"', '"sent"'), headers, secret) }
        .to raise_error(Noticed::Openwa::InvalidSignatureError, /doesn't match/)
    end

    it "refuses a wrong secret" do
      expect { described_class.verify!(body, headers, "another-webhook-secret") }
        .to raise_error(Noticed::Openwa::InvalidSignatureError)
    end

    it "refuses a delivery without a signature" do
      expect { described_class.verify!(body, {}, secret) }
        .to raise_error(Noticed::Openwa::InvalidSignatureError, /no valid/)
    end

    it "refuses a malformed signature" do
      expect { described_class.verify!(body, { "X-OpenWA-Signature" => signature.delete_prefix("sha256=") }, secret) }
        .to raise_error(Noticed::Openwa::InvalidSignatureError, /no valid/)
    end

    it "requires the secret" do
      expect { described_class.verify!(body, headers, "") }.to raise_error(ArgumentError)
    end
  end

  describe ".parse" do
    subject(:event) { described_class.parse(*delivery) }

    context "with a read ack" do
      let(:delivery) { OpenwaSpecSupport.webhook_delivery("message_ack_read") }

      it "returns the message's status", :aggregate_failures do
        expect(event).to have_attributes(type: :message_status, event: "message.ack", status: "read",
                                         message_id: "true_100000000000001@lid_3EB09F3F44E302C0AC7D78_out",
                                         chat_id: "100000000000001@lid", session_id: "openwa-session-test",
                                         occurred_at: Time.utc(2026, 11, 17, 21, 1, 42.724r), reason: nil)
        expect(event.idempotency_key).to eq(delivery.last.fetch("X-OpenWA-Idempotency-Key"))
        expect(event.payload).to eq(JSON.parse(delivery.first))
      end
    end

    %w[sent delivered failed].each do |status|
      context "with a #{status} ack" do
        let(:delivery) { OpenwaSpecSupport.webhook_delivery("message_ack_#{status}") }

        it "returns the status" do
          expect(event).to have_attributes(type: :message_status, status:)
        end
      end
    end

    %w[disconnected initializing qr_ready authenticating ready].each do |status|
      context "with the session's #{status} status" do
        let(:delivery) { OpenwaSpecSupport.webhook_delivery("session_status_#{status}") }

        it "returns OpenWA's status as the state" do
          expect(event).to have_attributes(type: :session_state, event: "session.status", state: status,
                                           session_id: "openwa-session-test")
        end
      end
    end

    context "with the session disconnected" do
      let(:delivery) { OpenwaSpecSupport.webhook_delivery("session_disconnected") }

      it "returns the state and the reason" do
        expect(event).to have_attributes(type: :session_state, state: "disconnected", reason: "LOGOUT")
      end
    end

    context "with the session reconnecting" do
      let(:delivery) { built_delivery("session.reconnect_loop", attempts: 5, nextDelayMs: 30_000) }

      it "returns the state and the attempts" do
        expect(event).to have_attributes(state: "reconnecting", details: { attempts: 5, next_delay_ms: 30_000 })
      end
    end

    context "with the session's account restricted" do
      let(:delivery) do
        built_delivery("session.restriction", active: true, kind: "rate_limit", code: 463,
                                              expiresAt: "2026-11-18T00:00:00.000Z")
      end

      it "returns the state and the restriction" do
        expect(event).to have_attributes(state: "restricted",
                                         details: { kind: "rate_limit", code: 463, expires_at: Time.utc(2026, 11, 18) })
      end
    end

    context "with the restriction lifted" do
      let(:delivery) do
        built_delivery("session.restriction", active: false, kind: "rate_limit", code: 463, expiresAt: nil)
      end

      it "returns the state" do
        expect(event).to have_attributes(state: "unrestricted",
                                         details: { kind: "rate_limit", code: 463, expires_at: nil })
      end
    end

    %w[message_failed message_sent].each do |name|
      context "with #{name.tr('_', '.')}" do
        let(:delivery) { OpenwaSpecSupport.webhook_delivery(name) }

        it "skips it" do
          expect(event).to be_nil
        end
      end
    end

    context "without an idempotency key in the body" do
      let(:delivery) do
        recorded = JSON.parse(OpenwaSpecSupport.webhook_delivery("session_status_ready").first)
        body = JSON.generate(recorded.except("idempotencyKey"))
        [ body, { "x-openwa-idempotency-key" => "from-the-header" } ]
      end

      it "takes the header's" do
        expect(event.idempotency_key).to eq("from-the-header")
      end
    end

    context "with a body that isn't JSON" do
      let(:delivery) { [ "<html>", {} ] }

      it "raises an error" do
        expect { event }.to raise_error(Noticed::Openwa::Error, /isn't JSON/)
      end
    end

    context "with JSON that isn't an OpenWA event" do
      let(:delivery) { [ '{"status":"read"}', {} ] }

      it "raises an error" do
        expect { event }.to raise_error(Noticed::Openwa::Error, /isn't an OpenWA event/)
      end
    end

    context "with a timestamp that isn't ISO 8601" do
      let(:delivery) { [ '{"event":"session.status","timestamp":"yesterday","data":{"status":"ready"}}', {} ] }

      it "raises an error" do
        expect { event }.to raise_error(Noticed::Openwa::Error, /timestamp/)
      end
    end
  end
end
