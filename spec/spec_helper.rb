# frozen_string_literal: true

# Before anything of the gem is loaded, or its files aren't measured (configured in .simplecov).
require "simplecov"
SimpleCov.start

# A real OpenWA session's values, read only to record cassettes (OPENWA_RECORD=true; README, "Recording the
# cassettes"): KEY=VALUE lines. Otherwise the specs replay with the placeholders below, whatever the local file says.
local_env = File.expand_path("../.env.test.local", __dir__)
if ENV["OPENWA_RECORD"] == "true" && File.exist?(local_env)
  File.readlines(local_env, chomp: true).each do |line|
    key, value = line.split("=", 2)
    # A value may be quoted, as in other .env files: one pair of matching quotes around it isn't part of it.
    value = value[1..-2] if value&.match?(/\A(["']).*\1\z/)
    # An empty value (.env.test.example's) is left out: the placeholder's default applies.
    ENV[key] ||= value unless value.to_s.empty? || !key.match?(/\A[A-Z][A-Z0-9_]*\z/)
  end
end

# Without them, the placeholders the cassettes are replayed with.
{
  "OPENWA_URL" => "https://openwa.test",
  "OPENWA_API_KEY" => "openwa_api_key_1234567890",
  "OPENWA_SESSION_ID" => "openwa-session-test",
  "OPENWA_TEST_NUMBER" => "+5561900000001",
  "OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP" => "+5561900000002",
  "OPENWA_WEBHOOK_SECRET" => "openwa_webhook_secret_1234567890",
  "OPENWA_TEST_WEBHOOK_URL" => "https://webhook.test/noticed-openwa",
  "OPENWA_SESSION_PHONE" => "5561900000003",
  "OPENWA_SESSION_PUSH_NAME" => "noticed-openwa test",
  "OPENWA_TEST_GROUP" => "120363000000000001@g.us"
}.each { |key, value| ENV[key] = value if ENV[key].to_s.empty? }

require_relative "support/dummy_app"
require "noticed/openwa"
require "securerandom"
require "vcr"
require "webmock/rspec"

module OpenwaSpecSupport
  # A 1x1 PNG and a one-page PDF: what the sends carry.
  PNG = [ "89504e470d0a1a0a0000000d4948445200000001000000010806000000" \
          "1f15c4890000000d49444154789c636060606000000005000157a7e5d00000000049454e44ae426082" ].pack("H*")
  # A second image, a red pixel, for messages with more than one.
  RED_PNG = [ "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de0000000c49444154789c63f8cfc000" \
              "0003010100c9fe92ef0000000049454e44ae426082" ].pack("H*")
  PDF = "%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" \
        "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"

  module_function

  def client(**options)
    ca_file = ENV["OPENWA_CA_FILE"].to_s
    Noticed::Openwa::Client.new(url: ENV.fetch("OPENWA_URL"), api_key: ENV.fetch("OPENWA_API_KEY"),
                                session_id: ENV.fetch("OPENWA_SESSION_ID"),
                                ca_file: ca_file.empty? ? nil : ca_file, **options)
  end

  def number = ENV.fetch("OPENWA_TEST_NUMBER")

  def number_not_on_whatsapp = ENV.fetch("OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP")

  # A WhatsApp group of the maintainer's, with their own number in it: it receives the bulk delivery's test messages.
  def group = ENV.fetch("OPENWA_TEST_GROUP")

  def digits(value) = value.to_s.delete("^0-9")

  # WhatsApp may hold a Brazilian mobile number without its ninth digit.
  def without_ninth_digit(value)
    digits = digits(value)
    digits[0, 4] + digits[5..] if digits.start_with?("55") && digits.size == 13
  end

  # The maintainer's: the recording session's events are delivered there while the webhook exists.
  def webhook_url = ENV.fetch("OPENWA_TEST_WEBHOOK_URL")

  def webhook_secret = ENV.fetch("OPENWA_WEBHOOK_SECRET")

  # A WhatsApp privacy id's digits, before `@lid`, and what the cassettes and webhook fixtures hold instead.
  LID = /\d{8,}(?=@lid)/
  LID_PLACEHOLDER = "100000000000001"

  # script/webhook_fixtures.rb signs the webhook fixtures (spec/fixtures/webhooks/) with it.
  WEBHOOK_FIXTURE_SECRET = "noticed-openwa-webhook-fixtures"

  # A webhook fixture's raw body and headers, as a delivery reaches the app.
  def webhook_delivery(name)
    fixture = JSON.parse(File.read(File.expand_path("fixtures/webhooks/#{name}.json", __dir__)))
    [ fixture.fetch("body"), fixture.fetch("headers") ]
  end

  def webhook_fixtures
    Dir[File.expand_path("fixtures/webhooks/*.json", __dir__)].map { File.basename(_1, ".json") }.sort
  end

  def idempotency_key = "noticed-openwa-spec-#{SecureRandom.uuid}"
end

record_mode = ENV.fetch("VCR_RECORD_MODE", "once").to_sym

VCR.configure do |config|
  config.hook_into :webmock
  config.cassette_library_dir = File.expand_path("fixtures/vcr_cassettes", __dir__)
  config.configure_rspec_metadata!
  # A local OpenWA (docker-compose.yml) is on localhost: it's recorded like any other. Only 127.0.0.1 passes through, for
  # the spec of an OpenWA that can't be reached.
  config.ignore_hosts "127.0.0.1"
  config.default_cassette_options = { record: record_mode }

  # The settings, the webhook's URL and secret, the numbers and the session's phone and name never go into a cassette;
  # replayed, they're the environment's values (the placeholders above). The placeholders are valid in a URI, and none
  # is a prefix of another.
  {
    "https://openwa-host.placeholder" => -> { ENV["OPENWA_URL"].to_s[%r{\A[a-z]+://[^/]+}] },
    "openwa-api-key-placeholder" => -> { ENV["OPENWA_API_KEY"] },
    "openwa-session-placeholder" => -> { ENV["OPENWA_SESSION_ID"] },
    "openwa-webhook-secret-placeholder" => -> { ENV["OPENWA_WEBHOOK_SECRET"] },
    "https://openwa-webhook-url.placeholder" => -> { ENV["OPENWA_TEST_WEBHOOK_URL"] },
    "openwa-session-phone" => -> { OpenwaSpecSupport.digits(ENV["OPENWA_SESSION_PHONE"]) },
    "openwa-push-name" => -> { ENV["OPENWA_SESSION_PUSH_NAME"] },
    "openwa-group-id" => -> { ENV["OPENWA_TEST_GROUP"].to_s.split("@").first },
    "openwa-number-a" => -> { OpenwaSpecSupport.digits(ENV["OPENWA_TEST_NUMBER"]) },
    "openwa-whatsapp-id-a" => -> { OpenwaSpecSupport.without_ninth_digit(ENV["OPENWA_TEST_NUMBER"]) },
    "openwa-number-b" => -> { OpenwaSpecSupport.digits(ENV["OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP"]) },
    "openwa-whatsapp-id-b" => -> { OpenwaSpecSupport.without_ninth_digit(ENV["OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP"]) }
  }.each do |placeholder, value|
    config.filter_sensitive_data(placeholder) { value.call.to_s.then { |text| text.empty? ? nil : text } }
  end

  # The Host header names OpenWA's host: it isn't matched on, so it isn't kept.
  config.before_record { |interaction| interaction.request.headers.delete("Host") }

  # WhatsApp's privacy ids (LIDs, <digits>@lid) name accounts as numbers do, the maintainer's own included, and appear in
  # the message ids OpenWA answers: whichever account they are, they're replaced, unlike the values above, by one
  # placeholder (the specs never read them back).
  config.before_record do |interaction|
    [ interaction.request.uri, interaction.request.body, interaction.response.body ].each do |text|
      text&.gsub!(OpenwaSpecSupport::LID, OpenwaSpecSupport::LID_PLACEHOLDER)
    end
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.include_chain_clauses_in_custom_matcher_descriptions = true }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand config.seed
end
