# frozen_string_literal: true

RSpec.describe Noticed::Openwa::Client do
  subject(:client) { OpenwaSpecSupport.client }

  let(:chat_id) { described_class.chat_id(OpenwaSpecSupport.number) }

  describe ".new" do
    it "requires the url, the API key and the session" do
      expect { described_class.new(url: "https://openwa.test", api_key: " ", session_id: "s") }
        .to raise_error(ArgumentError, /required/)
    end
  end

  describe ".chat_id" do
    it "turns a number into its chat id", :aggregate_failures do
      expect(described_class.chat_id("+55 (61) 99110-1515")).to eq("5561991101515@c.us")
      expect(described_class.chat_id("5561991101515@c.us")).to eq("5561991101515@c.us")
    end
  end

  describe "#check_number" do
    context "when the number is on WhatsApp", vcr: { cassette_name: "check_number/found" } do
      it "returns the chat id WhatsApp holds for it", :aggregate_failures do
        result = client.check_number(OpenwaSpecSupport.number)

        expect(result[:exists]).to be(true)
        expect(result[:whatsapp_id]).to end_with("@c.us")
      end
    end

    context "when the number isn't on WhatsApp", vcr: { cassette_name: "check_number/not_found" } do
      it "returns no chat id" do
        expect(client.check_number(OpenwaSpecSupport.number_not_on_whatsapp)).to eq(exists: false, whatsapp_id: nil)
      end
    end

    context "when the API key is wrong", vcr: { cassette_name: "check_number/wrong_api_key" } do
      subject(:client) { OpenwaSpecSupport.client(api_key: "wrong-api-key") }

      it "raises an authentication error", :aggregate_failures do
        expect { client.check_number(OpenwaSpecSupport.number) }.to raise_error(Noticed::Openwa::AuthenticationError) do |error|
          expect(error.status).to eq(401)
          expect(error.message).not_to include(OpenwaSpecSupport.digits(OpenwaSpecSupport.number))
        end
      end
    end

    context "when the session doesn't exist", vcr: { cassette_name: "check_number/unknown_session" } do
      subject(:client) { OpenwaSpecSupport.client(session_id: "noticed-openwa-missing-session") }

      it "raises a retryable error: nothing was sent" do
        expect { client.check_number(OpenwaSpecSupport.number) }.to raise_error(Noticed::Openwa::RetryableError, /check_number: 400/)
      end
    end

    it "refuses a number without digits" do
      expect { client.check_number("+") }.to raise_error(ArgumentError)
    end

    context "when OpenWA can't be reached" do
      subject(:client) { described_class.new(url: "http://127.0.0.1:1", api_key: "key", session_id: "session") }

      it "raises a retryable error" do
        expect { client.check_number(OpenwaSpecSupport.number) }.to raise_error(Noticed::Openwa::RetryableError)
      end
    end
  end

  describe "#send_text", vcr: { cassette_name: "send_text/sent" } do
    it "returns the message's id" do
      response = client.send_text(chat_id, "noticed-openwa: send_text", idempotency_key: OpenwaSpecSupport.idempotency_key)

      expect(response).to include("messageId" => a_kind_of(String))
    end
  end

  describe "#send_text with a used idempotency key", vcr: { cassette_name: "send_text/replayed" } do
    it "replays the first answer instead of sending again" do
      key = OpenwaSpecSupport.idempotency_key
      first = client.send_text(chat_id, "noticed-openwa: sent once", idempotency_key: key)

      expect(client.send_text(chat_id, "noticed-openwa: sent once", idempotency_key: key)["messageId"])
        .to eq(first["messageId"])
    end
  end

  describe "#send_text to a number not on WhatsApp", vcr: { cassette_name: "send_text/not_on_whatsapp" } do
    it "raises a not on WhatsApp error", :aggregate_failures do
      # The guard: the number must not be on WhatsApp, or the message would reach a real account.
      expect(client.check_number(OpenwaSpecSupport.number_not_on_whatsapp)[:exists]).to be(false)

      expect do
        client.send_text(described_class.chat_id(OpenwaSpecSupport.number_not_on_whatsapp), "noticed-openwa: nobody",
                         idempotency_key: OpenwaSpecSupport.idempotency_key)
      end.to raise_error(Noticed::Openwa::NotOnWhatsappError) do |error|
        expect(error.message).not_to include(OpenwaSpecSupport.digits(OpenwaSpecSupport.number_not_on_whatsapp))
      end
    end
  end

  describe "#send_text errors" do
    def self.answer(code, message, body)
      { vcr: { cassette_name: "templates/send_text", record: :none,
               erb: { code:, message:, body: JSON.generate(body) } } }
    end

    def send_text = client.send_text(chat_id, "noticed-openwa: errors", idempotency_key: OpenwaSpecSupport.idempotency_key)

    context "when the message may have been sent",
            **answer(409, "Conflict", { statusCode: 409, message: "Outcome unknown", code: "IDEMPOTENCY_OUTCOME_UNKNOWN" }) do
      it "raises an unknown outcome error", :aggregate_failures do
        expect { send_text }.to raise_error(Noticed::Openwa::UnknownOutcomeError) { |error| expect(error.code).to eq("IDEMPOTENCY_OUTCOME_UNKNOWN") }
      end
    end

    context "when the same key is still in progress",
            **answer(409, "Conflict", { statusCode: 409, message: "In progress", code: "IDEMPOTENCY_KEY_IN_PROGRESS" }) do
      it "raises a retryable error" do
        expect { send_text }.to raise_error(Noticed::Openwa::RetryableError)
      end
    end

    context "when the session's sends are paced",
            **answer(429, "Too Many Requests", { statusCode: 429, message: "Slow down", code: "SEND_PACING_LIMITED",
                                                 retryAfterSeconds: 30 }) do
      it "raises a retryable error with the wait", :aggregate_failures do
        expect { send_text }.to raise_error(Noticed::Openwa::RetryableError) { |error| expect(error.retry_after).to eq(30) }
      end
    end

    context "when WhatsApp is unavailable",
            **answer(503, "Service Unavailable", { statusCode: 503, message: "WhatsApp did not answer" }) do
      it "raises a retryable error" do
        expect { send_text }.to raise_error(Noticed::Openwa::RetryableError, /send_text: 503/)
      end
    end

    context "when the request is invalid", **answer(400, "Bad Request", { statusCode: 400, message: [ "text must be a string" ] }) do
      it "raises a request error" do
        expect { send_text }.to raise_error(Noticed::Openwa::RequestError, /text must be a string/)
      end
    end
  end

  it "refuses an invalid idempotency key" do
    expect { client.send_text(chat_id, "text", idempotency_key: "with spaces") }.to raise_error(ArgumentError)
  end

  describe "#send_image", vcr: { cassette_name: "send_image/sent" } do
    it "sends the bytes as base64, with the caption" do
      response = client.send_image(chat_id, content: OpenwaSpecSupport::PNG, mimetype: "image/png",
                                            caption: "noticed-openwa: send_image",
                                            idempotency_key: OpenwaSpecSupport.idempotency_key)

      expect(response).to include("messageId" => a_kind_of(String))
    end
  end

  describe "#send_document", vcr: { cassette_name: "send_document/sent" } do
    it "sends the bytes as base64, with the file name and caption" do
      response = client.send_document(chat_id, content: OpenwaSpecSupport::PDF, mimetype: "application/pdf",
                                               filename: "noticed-openwa.pdf", caption: "noticed-openwa: send_document",
                                               idempotency_key: OpenwaSpecSupport.idempotency_key)

      expect(response).to include("messageId" => a_kind_of(String))
    end
  end

  describe "#send_message" do
    context "without files", vcr: { cassette_name: "send_message/text" } do
      it "sends the text alone" do
        expect(client.send_message(chat_id, text: "noticed-openwa: send_message", idempotency_key: OpenwaSpecSupport.idempotency_key).size)
          .to eq(1)
      end
    end

    context "with files", vcr: { cassette_name: "send_message/files" } do
      let(:files) do
        [ { content: -> { OpenwaSpecSupport::PDF }, mimetype: "application/pdf", filename: "noticed-openwa-1.pdf" },
          { content: OpenwaSpecSupport::PNG, mimetype: "image/png", filename: "noticed-openwa-2.png" } ]
      end

      it "sends one message per file, the text as the first one's caption", :aggregate_failures do
        key = OpenwaSpecSupport.idempotency_key
        responses = client.send_message(chat_id, text: "noticed-openwa: send_message with files", files:, idempotency_key: key)

        expect(responses.size).to eq(2)
        expect(a_request(:post, %r{/messages/send-document\z}).with(headers: { "Idempotency-Key" => "#{key}-1" }) { |request|
          JSON.parse(request.body)["caption"] == "noticed-openwa: send_message with files"
        }).to have_been_made
        expect(a_request(:post, %r{/messages/send-image\z}).with(headers: { "Idempotency-Key" => "#{key}-2" }) { |request|
          !JSON.parse(request.body).key?("caption")
        }).to have_been_made
      end
    end
  end
end
