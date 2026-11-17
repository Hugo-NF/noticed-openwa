# frozen_string_literal: true

require "json"
require "openssl"

# Turns real OpenWA webhook deliveries into the specs' fixtures (README, "Recording the webhook fixtures"):
#
#   ruby script/webhook_fixtures.rb <requests>.json <file holding the webhook's secret>
#
# <requests>.json: the requests the webhook's URL received, oldest first, as
# { "data": [{ "headers": { name => value or [value] }, "content": "<raw body>" }] }.
#
# Each delivery's real signature is checked against its raw body first. Then the session id, the WhatsApp ids (LIDs)
# and the test number are replaced by the specs' placeholders, and the body is signed again with FIXTURE_SECRET, as
# OpenWA would sign it: the filtered body is a delivery the specs can verify. The acks a recording can't trigger on
# demand (sent, delivered, failed) and `message.failed` are made from the recorded `read` ack, and say so.
module WebhookFixtures
  # spec/spec_helper.rb's OpenwaSpecSupport::WEBHOOK_FIXTURE_SECRET.
  FIXTURE_SECRET = "noticed-openwa-webhook-fixtures"
  SESSION = "openwa-session-test"
  LID = "100000000000001"
  NUMBER = "5561900000001"
  DIRECTORY = File.expand_path("../spec/fixtures/webhooks", __dir__)
  KEPT_HEADERS = %w[Content-Type User-Agent X-OpenWA-Event X-OpenWA-Idempotency-Key X-OpenWA-Delivery-Id
                    X-OpenWA-Retry-Count].freeze
  ACKS = { "sent" => 1, "delivered" => 2, "failed" => -1 }.freeze
  RECORDED = "A real delivery, filtered and signed again with the specs' secret."
  MADE = "Made from the recorded read ack (a recording can't trigger it on demand), signed with the specs' secret."

  module_function

  def run(export_path, secret_path, env_path = File.expand_path("../.env.test.local", __dir__))
    env = File.readlines(env_path, chomp: true).filter_map { |line| line.split("=", 2) if line.match?(/\A[A-Z_]+=./) }
    env = env.to_h
    secret = File.read(secret_path).strip
    deliveries = JSON.parse(File.read(export_path)).fetch("data").map { |request| delivery(request) }
    deliveries.each { |each| verify!(each, secret) }

    filters = filters(deliveries, env)
    recorded = deliveries.map { |each| filtered(each, filters) }
    fixtures = recorded.to_h { |each| [ name(each), each ] }
    read = fixtures.fetch("message_ack_read") { abort "no read ack recorded: open the test message on the phone" }
    fixtures.merge!(made_from_read(read))

    Dir.mkdir(DIRECTORY) unless Dir.exist?(DIRECTORY)
    fixtures.each { |name, fixture| write(name, fixture) }
    puts fixtures.keys.sort
  end

  def delivery(request)
    headers = request.fetch("headers").transform_values { |value| Array(value).first }
    { "headers" => headers, "body" => request.fetch("content") }
  end

  def verify!(delivery, secret)
    given = delivery["headers"].find { |key, _| key.casecmp?("X-OpenWA-Signature") }&.last
    expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, delivery['body'])}"
    abort "a delivery's signature doesn't match its body: is the secret the webhook's?" unless given == expected
  end

  # The values to replace, longest first, so a number is never left half replaced.
  def filters(deliveries, env)
    lids = deliveries.flat_map { |each| each["body"].scan(/(\d+)@lid/).flatten }.uniq
    number = env.fetch("OPENWA_TEST_NUMBER").delete("^0-9")
    numbers = [ number, (number[0, 4] + number[5..] if number.start_with?("55") && number.size == 13) ].compact
    pairs = { env.fetch("OPENWA_SESSION_ID") => SESSION }
    lids.each { |lid| pairs[lid] = LID }
    numbers.each { |each| pairs[each] = NUMBER }
    pairs.sort_by { |value, _| -value.size }
  end

  def filtered(delivery, filters)
    body = filters.reduce(delivery["body"]) { |text, (value, placeholder)| text.gsub(value, placeholder) }
    headers = KEPT_HEADERS.to_h do |name|
      value = delivery["headers"].find { |key, _| key.casecmp?(name) }&.last
      [ name, filters.reduce(value.to_s) { |text, (real, placeholder)| text.gsub(real, placeholder) } ]
    end
    { "note" => RECORDED, "headers" => headers, "body" => body }
  end

  def name(fixture)
    body = JSON.parse(fixture["body"])
    [ body["event"].tr(".", "_"), body.dig("data", "status") ].compact.join("_")
  end

  # OpenWA's ack for each status differs only by the status, the ack level and the idempotency key's status;
  # `message.failed` is the failed ack under its own event and key.
  def made_from_read(read)
    body = JSON.parse(read["body"])
    acks = ACKS.to_h do |status, ack|
      made = body.merge("idempotencyKey" => body["idempotencyKey"].sub("_read_", "_#{status}_"),
                        "data" => body["data"].merge("status" => status, "ack" => ack))
      [ "message_ack_#{status}", made_fixture(read, made) ]
    end
    failed = JSON.parse(acks.fetch("message_ack_failed")["body"])
    failed = failed.merge("event" => "message.failed",
                          "idempotencyKey" => failed["idempotencyKey"].sub(/\Aack_/, "failed_"))
    acks.merge("message_failed" => made_fixture(read, failed))
  end

  def made_fixture(read, body)
    headers = read["headers"].merge("X-OpenWA-Event" => body["event"],
                                    "X-OpenWA-Idempotency-Key" => body["idempotencyKey"])
    { "note" => MADE, "headers" => headers, "body" => JSON.generate(body) }
  end

  def write(name, fixture)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', FIXTURE_SECRET, fixture['body'])}"
    fixture = fixture.merge("headers" => fixture["headers"].merge("X-OpenWA-Signature" => signature))
    File.write(File.join(DIRECTORY, "#{name}.json"), "#{JSON.pretty_generate(fixture)}\n")
  end
end

WebhookFixtures.run(*ARGV) if $PROGRAM_NAME == __FILE__
