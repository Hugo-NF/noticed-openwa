# frozen_string_literal: true

# A real OpenWA session's values, read only to record cassettes (OPENWA_RECORD=true; README, "Recording the
# cassettes"): KEY=VALUE lines. Otherwise the specs replay with the placeholders below, whatever the local file says.
local_env = File.expand_path("../.env.test.local", __dir__)
if ENV["OPENWA_RECORD"] == "true" && File.exist?(local_env)
  File.readlines(local_env, chomp: true).each do |line|
    key, value = line.split("=", 2)
    ENV[key] ||= value if value && key.match?(/\A[A-Z][A-Z0-9_]*\z/)
  end
end

# Without them, the placeholders the cassettes are replayed with.
{
  "OPENWA_URL" => "https://openwa.test",
  "OPENWA_API_KEY" => "openwa_api_key_1234567890",
  "OPENWA_SESSION_ID" => "openwa-session-test",
  "OPENWA_TEST_NUMBER" => "+5561900000001",
  "OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP" => "+5561900000002"
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

  def digits(value) = value.to_s.delete("^0-9")

  # WhatsApp may hold a Brazilian mobile number without its ninth digit.
  def without_ninth_digit(value)
    digits = digits(value)
    digits[0, 4] + digits[5..] if digits.start_with?("55") && digits.size == 13
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

  # The settings and the numbers never go into a cassette; replayed, they're the environment's values (the placeholders
  # above). The placeholders are valid in a URI, and none is a prefix of another.
  {
    "https://openwa-host.placeholder" => -> { ENV["OPENWA_URL"].to_s[%r{\A[a-z]+://[^/]+}] },
    "openwa-api-key-placeholder" => -> { ENV["OPENWA_API_KEY"] },
    "openwa-session-placeholder" => -> { ENV["OPENWA_SESSION_ID"] },
    "openwa-number-a" => -> { OpenwaSpecSupport.digits(ENV["OPENWA_TEST_NUMBER"]) },
    "openwa-whatsapp-id-a" => -> { OpenwaSpecSupport.without_ninth_digit(ENV["OPENWA_TEST_NUMBER"]) },
    "openwa-number-b" => -> { OpenwaSpecSupport.digits(ENV["OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP"]) },
    "openwa-whatsapp-id-b" => -> { OpenwaSpecSupport.without_ninth_digit(ENV["OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP"]) }
  }.each do |placeholder, value|
    config.filter_sensitive_data(placeholder) { value.call.to_s.then { |text| text.empty? ? nil : text } }
  end

  # The Host header names OpenWA's host: it isn't matched on, so it isn't kept.
  config.before_record { |interaction| interaction.request.headers.delete("Host") }
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.include_chain_clauses_in_custom_matcher_descriptions = true }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand config.seed
end
