# frozen_string_literal: true

RSpec.describe Noticed::DeliveryMethods::Openwa do
  subject(:delivery) do
    described_class.new.perform(:openwa, "OpenwaSpecNotifier::Notification", recipient: Object.new, params:, overrides:)
  end

  let(:key) { OpenwaSpecSupport.idempotency_key }
  let(:overrides) { {} }

  before do
    notifier = Class.new(Noticed::Ephemeral) do
      ca_file = ENV["OPENWA_CA_FILE"].to_s

      deliver_by :openwa,
                 url: -> { ENV.fetch("OPENWA_URL") },
                 api_key: -> { ENV.fetch("OPENWA_API_KEY") },
                 session_id: -> { ENV.fetch("OPENWA_SESSION_ID") },
                 ca_file: (ca_file unless ca_file.empty?),
                 to: -> { params[:to] },
                 text: -> { params[:text] },
                 files: -> { params[:files] },
                 idempotency_key: -> { params[:key] }

      def keep_answers(notification, answers) = params[:sent] << [ notification, answers ]

      def keep_missing(notification, chat_id, error) = params[:missing] << [ notification, chat_id, error ]
    end
    stub_const("OpenwaSpecNotifier", notifier)
  end

  it "requires the connection, the recipient and the text" do
    expect(described_class.required_option_names).to eq(%i[url api_key session_id to text])
  end

  describe "a text", vcr: { cassette_name: "delivery_method/text" } do
    let(:params) { { to: OpenwaSpecSupport.number, text: "noticed-openwa: delivery method", key: } }

    it "sends it to the number, with the idempotency key" do
      delivery

      expect(a_request(:post, %r{/messages/send-text\z}).with(headers: { "Idempotency-Key" => key })).to have_been_made
    end
  end

  describe "a text with a file", vcr: { cassette_name: "delivery_method/file" } do
    let(:params) do
      { to: OpenwaSpecSupport.number, text: "noticed-openwa: delivery method with a file", key:,
        files: [ { content: OpenwaSpecSupport::PDF, mimetype: "application/pdf", filename: "noticed-openwa.pdf" } ] }
    end

    it "sends the file with the text as its caption" do
      delivery

      expect(a_request(:post, %r{/messages/send-document\z}).with(headers: { "Idempotency-Key" => "#{key}-1" }) { |request|
        JSON.parse(request.body).values_at("caption", "filename") == [ params[:text], "noticed-openwa.pdf" ]
      }).to have_been_made
    end
  end

  describe "after_send" do
    let(:params) { { to: OpenwaSpecSupport.number, text: "noticed-openwa: delivery method", key:, sent: [] } }
    let(:overrides) { { after_send: ->(answers) { params[:sent] << [ self, answers ] } } }
    let(:answer) { a_hash_including("messageId" => a_kind_of(String), "timestamp" => a_kind_of(Integer)) }

    context "with a text", vcr: { cassette_name: "delivery_method/text" } do
      it "is called once, on the notification, with OpenWA's answer" do
        delivery

        expect(params[:sent]).to match([ [ an_instance_of(OpenwaSpecNotifier::Notification), [ answer ] ] ])
      end
    end

    context "with a text and a file", vcr: { cassette_name: "delivery_method/file" } do
      let(:params) do
        { to: OpenwaSpecSupport.number, text: "noticed-openwa: delivery method with a file", key:, sent: [],
          files: [ { content: OpenwaSpecSupport::PDF, mimetype: "application/pdf", filename: "noticed-openwa.pdf" } ] }
      end

      it "is called once, with the file's answer" do
        delivery

        expect(params[:sent]).to match([ [ an_instance_of(OpenwaSpecNotifier::Notification), [ answer ] ] ])
      end
    end

    context "with a notifier method's name", vcr: { cassette_name: "delivery_method/text" } do
      let(:overrides) { { after_send: :keep_answers } }

      it "calls it with the notification and OpenWA's answers" do
        delivery

        expect(params[:sent]).to match([ [ an_instance_of(OpenwaSpecNotifier::Notification), [ answer ] ] ])
      end
    end

    context "when the send fails",
            vcr: { cassette_name: "templates/send_text", record: :none,
                   erb: { code: 503, message: "Service Unavailable",
                          body: JSON.generate(statusCode: 503, message: "WhatsApp did not answer") } } do
      it "isn't called", :aggregate_failures do
        expect { delivery }.to raise_error(Noticed::Openwa::RetryableError)
        expect(params[:sent]).to be_empty
      end
    end
  end

  describe "to a number not on WhatsApp", vcr: { cassette_name: "delivery_method/not_on_whatsapp" } do
    let(:params) do
      { to: OpenwaSpecSupport.number_not_on_whatsapp, text: "noticed-openwa: nobody", key:, sent: [], missing: [] }
    end
    let(:chat_id) { Noticed::Openwa::Client.chat_id(OpenwaSpecSupport.number_not_on_whatsapp) }
    let(:missing) do
      [ [ an_instance_of(OpenwaSpecNotifier::Notification), chat_id, an_instance_of(Noticed::Openwa::NotOnWhatsappError) ] ]
    end

    # The guard: the number must not be on WhatsApp, or the message would reach a real account.
    before do
      raise "#{OpenwaSpecSupport.number_not_on_whatsapp} is on WhatsApp" if
        OpenwaSpecSupport.client.check_number(OpenwaSpecSupport.number_not_on_whatsapp)[:exists]
    end

    context "with not_on_whatsapp" do
      let(:overrides) do
        { not_on_whatsapp: ->(chat_id, error) { params[:missing] << [ self, chat_id, error ] }, after_send: :keep_answers }
      end

      it "hands it the chat id and the error, on the notification, instead of raising", :aggregate_failures do
        expect { delivery }.not_to raise_error
        expect(params[:missing]).to match(missing)
        expect(params[:sent]).to be_empty
      end
    end

    context "with a notifier method's name" do
      let(:overrides) { { not_on_whatsapp: :keep_missing } }

      it "calls it with the notification, the chat id and the error" do
        delivery

        expect(params[:missing]).to match(missing)
      end
    end

    context "without not_on_whatsapp" do
      it "raises the error" do
        expect { delivery }.to raise_error(Noticed::Openwa::NotOnWhatsappError)
      end
    end
  end

  describe "#default_idempotency_key" do
    let(:method) { described_class.new }

    it "is the notification's id, none for a notification without one", :aggregate_failures do
      method.instance_variable_set(:@notification, Struct.new(:id).new("1234"))
      expect(method.default_idempotency_key).to eq("noticed-1234")

      method.instance_variable_set(:@notification, Object.new)
      expect(method.default_idempotency_key).to be_nil
    end
  end
end
