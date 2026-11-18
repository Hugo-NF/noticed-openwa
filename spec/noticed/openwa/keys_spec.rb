# frozen_string_literal: true

RSpec.describe Noticed::Openwa::Keys do
  describe ".symbolize" do
    subject(:symbolized) do
      described_class.symbolize("messageId" => "1", "lastTriggeredAt" => nil, "URLHost" => "h", "X-Retry-Count" => "0",
                                "data" => { "chatId" => "c" }, "list" => [ { "retryCount" => 3 }, "value" ])
    end

    it "turns every key into a snake_case symbol, nested ones included, and keeps the values" do
      expect(symbolized).to eq(message_id: "1", last_triggered_at: nil, url_host: "h", x_retry_count: "0",
                               data: { chat_id: "c" }, list: [ { retry_count: 3 }, "value" ])
    end
  end
end
