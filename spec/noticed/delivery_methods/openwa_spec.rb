# frozen_string_literal: true

RSpec.describe Noticed::DeliveryMethods::Openwa do
  subject(:delivery) do
    described_class.new.perform(:openwa, "OpenwaSpecNotifier::Notification", recipient: Object.new, params:)
  end

  let(:key) { OpenwaSpecSupport.idempotency_key }

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
