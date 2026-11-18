# frozen_string_literal: true

RSpec.describe Noticed::BulkDeliveryMethods::Openwa do
  # As noticed runs it for an ephemeral notifier: once for the event, with all its recipients.
  subject(:delivery) do
    described_class.new.perform(:openwa, "OpenwaSpecBulkNotifier::Notification", recipient: recipients, params:,
                                                                                  overrides:)
  end

  let(:recipients) { [ Object.new, Object.new ] }
  let(:key) { OpenwaSpecSupport.idempotency_key }
  let(:overrides) { {} }
  let(:answer) { a_hash_including(message_id: a_kind_of(String), timestamp: a_kind_of(Integer), chat_id: a_kind_of(String)) }

  before do
    notifier = Class.new(Noticed::Ephemeral) do
      ca_file = ENV["OPENWA_CA_FILE"].to_s

      bulk_deliver_by :openwa,
                      url: -> { ENV.fetch("OPENWA_URL") },
                      api_key: -> { ENV.fetch("OPENWA_API_KEY") },
                      session_id: -> { ENV.fetch("OPENWA_SESSION_ID") },
                      ca_file: (ca_file unless ca_file.empty?),
                      to: -> { params[:to] },
                      text: -> { params[:text] },
                      files: -> { params[:files] },
                      idempotency_key: -> { params[:key] }

      def keep_answers(event, answers) = params[:sent] << [ event, answers ]

      def keep_missing(event, chat_id, error) = params[:missing] << [ event, chat_id, error ]
    end
    stub_const("OpenwaSpecBulkNotifier", notifier)
  end

  it "requires the connection, the chat and the text" do
    expect(described_class.required_option_names).to eq(%i[url api_key session_id to text])
  end

  describe "a text to a chat", vcr: { cassette_name: "bulk_delivery_method/text" } do
    let(:params) { { to: OpenwaSpecSupport.number, text: "noticed-openwa: bulk delivery method", key: } }

    it "sends it once, whatever the recipients, with the idempotency key" do
      delivery

      expect(a_request(:post, %r{/messages/send-text\z}).with(headers: { "Idempotency-Key" => key })).to have_been_made.once
    end
  end

  describe "a text with a file", vcr: { cassette_name: "bulk_delivery_method/file" } do
    let(:params) do
      { to: OpenwaSpecSupport.number, text: "noticed-openwa: bulk delivery method with a file", key:,
        files: [ { content: OpenwaSpecSupport::PDF, mimetype: "application/pdf", filename: "noticed-openwa.pdf" } ] }
    end

    it "sends the file with the text as its caption" do
      delivery

      expect(a_request(:post, %r{/messages/send-document\z}).with(headers: { "Idempotency-Key" => "#{key}-1" }) { |request|
        JSON.parse(request.body).values_at("caption", "filename") == [ params[:text], "noticed-openwa.pdf" ]
      }).to have_been_made
    end
  end

  describe "a text with two images", vcr: { cassette_name: "bulk_delivery_method/images" } do
    let(:params) do
      { to: OpenwaSpecSupport.number, text: "noticed-openwa: bulk delivery method with two images", key:,
        files: [ { content: OpenwaSpecSupport::PNG, mimetype: "image/png", filename: "noticed-openwa-1.png" },
                 { content: OpenwaSpecSupport::RED_PNG, mimetype: "image/png", filename: "noticed-openwa-2.png" } ] }
    end

    it "sends each image as its own message, the text as the last one's caption", :aggregate_failures do
      delivery

      [ [ 1, OpenwaSpecSupport::PNG, nil ], [ 2, OpenwaSpecSupport::RED_PNG, params[:text] ] ].each do |position, image, caption|
        expect(a_request(:post, %r{/messages/send-image\z}).with(headers: { "Idempotency-Key" => "#{key}-#{position}" }) { |request|
          body = JSON.parse(request.body)
          body["base64"] == Base64.strict_encode64(image) && body["caption"] == caption
        }).to have_been_made.once
      end
    end
  end

  describe "a text to a list of chats, a group's included", vcr: { cassette_name: "bulk_delivery_method/list" } do
    let(:params) do
      { to: [ OpenwaSpecSupport.number, OpenwaSpecSupport.group ], text: "noticed-openwa: bulk delivery method to a list",
        key: }
    end

    it "sends it to each chat, each key suffixed by the chat's position", :aggregate_failures do
      delivery

      expect(a_request(:post, %r{/messages/send-text\z}).with(headers: { "Idempotency-Key" => "#{key}-chat1" }) { |request|
        JSON.parse(request.body)["chatId"] == Noticed::Openwa::Client.chat_id(OpenwaSpecSupport.number)
      }).to have_been_made.once
      expect(a_request(:post, %r{/messages/send-text\z}).with(headers: { "Idempotency-Key" => "#{key}-chat2" }) { |request|
        JSON.parse(request.body)["chatId"] == OpenwaSpecSupport.group
      }).to have_been_made.once
    end
  end

  describe "an empty list of chats" do
    let(:params) { { to: [], text: "noticed-openwa: nobody", key:, sent: [] } }
    let(:overrides) { { after_send: :keep_answers } }

    it "sends nothing", :aggregate_failures do
      expect(delivery).to eq([])
      expect(params[:sent]).to be_empty
    end
  end

  describe "if: false" do
    let(:params) { { to: OpenwaSpecSupport.number, text: "noticed-openwa: skipped", key: } }
    let(:overrides) { { if: false } }

    it "skips the delivery" do
      expect(delivery).to be(false)
    end
  end

  describe "after_send" do
    let(:params) { { to: OpenwaSpecSupport.number, text: "noticed-openwa: bulk delivery method", key:, sent: [] } }

    context "with a lambda", vcr: { cassette_name: "bulk_delivery_method/text" } do
      let(:overrides) { { after_send: ->(answers) { params[:sent] << [ self, answers ] } } }

      it "is called once, on the event, with OpenWA's answer" do
        delivery

        expect(params[:sent]).to match([ [ an_instance_of(OpenwaSpecBulkNotifier), [ answer ] ] ])
      end
    end

    context "with a notifier method's name", vcr: { cassette_name: "bulk_delivery_method/text" } do
      let(:overrides) { { after_send: :keep_answers } }

      it "calls it with the event and OpenWA's answers" do
        delivery

        expect(params[:sent]).to match([ [ an_instance_of(OpenwaSpecBulkNotifier), [ answer ] ] ])
      end
    end

    context "with a list of chats", vcr: { cassette_name: "bulk_delivery_method/list" } do
      let(:params) do
        { to: [ OpenwaSpecSupport.number, OpenwaSpecSupport.group ], key:, sent: [],
          text: "noticed-openwa: bulk delivery method to a list" }
      end
      let(:overrides) { { after_send: :keep_answers } }

      it "is called once, with every chat's answer, in order, each with its chat" do
        delivery

        expect(params[:sent]).to match([ [ an_instance_of(OpenwaSpecBulkNotifier),
                                           [ a_hash_including(chat_id: Noticed::Openwa::Client.chat_id(OpenwaSpecSupport.number)),
                                             a_hash_including(chat_id: OpenwaSpecSupport.group) ] ] ])
      end
    end

    context "when the send fails",
            vcr: { cassette_name: "templates/send_text", record: :none,
                   erb: { code: 503, message: "Service Unavailable",
                          body: JSON.generate(statusCode: 503, message: "WhatsApp did not answer") } } do
      let(:overrides) { { after_send: :keep_answers } }

      it "isn't called", :aggregate_failures do
        expect { delivery }.to raise_error(Noticed::Openwa::RetryableError)
        expect(params[:sent]).to be_empty
      end
    end
  end

  describe "a list with a number not on WhatsApp", vcr: { cassette_name: "bulk_delivery_method/not_on_whatsapp" } do
    let(:params) do
      { to: [ OpenwaSpecSupport.number_not_on_whatsapp, OpenwaSpecSupport.number ], key:, sent: [], missing: [],
        text: "noticed-openwa: bulk delivery method, one chat not on WhatsApp" }
    end

    # The guard: the number must not be on WhatsApp, or the message would reach a real account.
    before do
      raise "#{OpenwaSpecSupport.number_not_on_whatsapp} is on WhatsApp" if
        OpenwaSpecSupport.client.check_number(OpenwaSpecSupport.number_not_on_whatsapp)[:exists]
    end

    context "with not_on_whatsapp" do
      let(:overrides) { { not_on_whatsapp: :keep_missing, after_send: :keep_answers } }

      it "hands it that chat, on the event, and still sends to the others", :aggregate_failures do
        delivery

        expect(params[:missing]).to match([ [ an_instance_of(OpenwaSpecBulkNotifier),
                                              Noticed::Openwa::Client.chat_id(OpenwaSpecSupport.number_not_on_whatsapp),
                                              an_instance_of(Noticed::Openwa::NotOnWhatsappError) ] ])
        expect(a_request(:post, %r{/messages/send-text\z}).with(headers: { "Idempotency-Key" => "#{key}-chat2" }))
          .to have_been_made.once
        expect(params[:sent]).to match([ [ an_instance_of(OpenwaSpecBulkNotifier), [ answer ] ] ])
      end
    end

    context "without not_on_whatsapp" do
      it "raises the error, before the chats after it", :aggregate_failures do
        expect { delivery }.to raise_error(Noticed::Openwa::NotOnWhatsappError)
        expect(a_request(:post, %r{/messages/send-text\z}).with(headers: { "Idempotency-Key" => "#{key}-chat2" }))
          .not_to have_been_made
      end
    end
  end

  describe "#default_idempotency_key" do
    let(:method) { described_class.new }

    it "is the event's id, apart from a notification's, none for an event without one", :aggregate_failures do
      method.instance_variable_set(:@event, Struct.new(:id).new("1234"))
      expect(method.default_idempotency_key).to eq("noticed-event-1234")

      method.instance_variable_set(:@event, Object.new)
      expect(method.default_idempotency_key).to be_nil
    end
  end
end
