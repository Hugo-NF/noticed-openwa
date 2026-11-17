# noticed-openwa

WhatsApp delivery for [noticed](https://github.com/excid3/noticed) through [OpenWA](https://github.com/rmyndharis/openwa),
a self-hosted WhatsApp gateway. Written against OpenWA 0.30.0.

It implements only what a delivery needs: sending a text, an image or a document to a number, and checking a number is
on WhatsApp. Sessions, groups, contacts and OpenWA's webhooks are left to OpenWA itself.

## Installation

```ruby
gem "noticed-openwa"
```

## The delivery method

```ruby
class BookingConfirmedNotifier < Noticed::Event
  deliver_by :openwa,
             url: -> { ENV["OPENWA_URL"] },
             api_key: -> { ENV["OPENWA_API_KEY"] },
             session_id: -> { ENV["OPENWA_SESSION_ID"] },
             to: -> { recipient.phone_number },
             text: -> { "*Booking confirmed!* See you on board." },
             files: -> { [ { filename: "ticket.pdf", mimetype: "application/pdf", content: -> { record.ticket_pdf } } ] }
end
```

| Option | |
|---|---|
| `url`, `api_key`, `session_id` | Required: OpenWA's API, its key (sent as `X-API-Key`) and the session that sends |
| `to` | Required: a phone number (punctuation and `+` are dropped) or a chat id (`<digits>@c.us`) |
| `text` | Required: the message, WhatsApp's markup included |
| `files` | `[{ filename:, mimetype:, content: }]`; `content` is the bytes or a lambda returning them, called only when that file is sent |
| `idempotency_key` | Defaults to `noticed-<notification id>` |
| `ca_file` | A CA bundle to trust, for an OpenWA behind a private CA's certificate |

Each option is a value, a lambda evaluated on the notification, or the name of a notifier method, as in noticed's own
delivery methods.

Without files it sends the text. With files it sends one message per file, the text as the first one's caption: images
(`image/*`) as images, the rest as documents. Files are sent as base64, never by URL.

Every message carries an `Idempotency-Key` (the option's key, suffixed `-1`, `-2`, ... per file): a retried job gets
OpenWA's first answer replayed instead of sending again.

## The client

```ruby
client = Noticed::Openwa::Client.new(url:, api_key:, session_id:)

client.check_number("+55 61 99110-1515")   # => { exists: true, whatsapp_id: "556191101515@c.us" }
client.send_text(chat_id, "Hello", idempotency_key: "welcome-42")
client.send_image(chat_id, content: png_bytes, mimetype: "image/png", caption: "...")
client.send_document(chat_id, content: pdf_bytes, mimetype: "application/pdf", filename: "ticket.pdf", caption: "...")
client.send_message(chat_id, text: "...", files: [...], idempotency_key: "...")
Noticed::Openwa::Client.chat_id("+55 61 99110-1515") # => "5561991101515@c.us"
```

The chat id WhatsApp holds can differ from a number's digits (Brazilian mobiles may be held without their ninth digit):
send to the `whatsapp_id` the check returns.

## Errors

All are `Noticed::Openwa::Error`, with the HTTP `status`, OpenWA's `code` and, for a rate limit, `retry_after` (seconds).
Their messages name the call, the status and OpenWA's reason, with any phone number filtered out.

| Error | When | Retry? |
|---|---|---|
| `AuthenticationError` | `401`, `403`: the key is missing, unknown, revoked or out of its scope | No |
| `NotOnWhatsappError` | WhatsApp can't resolve the recipient | No |
| `RetryableError` | Nothing was sent: the session isn't started or ready, `IDEMPOTENCY_KEY_IN_PROGRESS`, a rate limit (`429`), a timeout, `5xx`, OpenWA unreachable | Yes, with the same key |
| `UnknownOutcomeError` | `IDEMPOTENCY_OUTCOME_UNKNOWN`: the message may have been sent | No: a new key may send it twice |
| `RequestError` | OpenWA refused the request itself | No |

Retrying is the app's choice, for example on the delivery method's load hook:

```ruby
ActiveSupport.on_load(:noticed_delivery_methods_openwa) do
  retry_on Noticed::Openwa::RetryableError, wait: :polynomially_longer, attempts: 5
end
```

## Development

```
bundle install
bundle exec rake          # RuboCop and the specs
```

The specs replay VCR cassettes (`spec/fixtures/vcr_cassettes/`) recorded against a real, paired OpenWA session; noticed
runs in a minimal Rails app (`spec/support/dummy_app.rb`). No request reaches OpenWA unless a cassette is missing.

### Recording the cassettes

Put a real session's values in the git-ignored `.env.test.local`, then delete the cassette (or run with
`VCR_RECORD_MODE=all`) and run its spec:

```
OPENWA_URL=https://openwa.example
OPENWA_API_KEY=...
OPENWA_SESSION_ID=...
OPENWA_CA_FILE=                           # a private CA's bundle, if OpenWA's certificate needs one
OPENWA_TEST_NUMBER=+55...                 # your own number: it receives the test messages
OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP=+55... # a number with no WhatsApp account
```

The URL's host, the key, the session and both numbers (with and without the ninth digit) are replaced by placeholders
in the cassettes, and replayed with the placeholders of `spec/spec_helper.rb`. The "not on WhatsApp" spec checks the
number first and stops before sending if it is on WhatsApp: a real account would receive the message. Check a new
cassette for those values before committing it.

`spec/fixtures/vcr_cassettes/templates/send_text.yml` is an ERB template of a recorded send, for the answers a real
session can't be made to give (`409`, `429`, `503`); use it with `record: :none`.

## Releases

Published by `.github/workflows/release.yml`; versions come from the tags (`script/release_version.rb`), and
`lib/noticed/openwa/version.rb` is a placeholder the workflow fills when it builds.

- **Release candidates.** Every push to `main` that passes CI (docs-only changes aside) publishes the next candidate,
  `X.Y.Z.rcN`, to RubyGems and as a GitHub pre-release tagged `vX.Y.Z.rcN`, with the changes since the previous tag as its
  notes. The series continues (`0.1.0.rc12` → `0.1.0.rc13`) until it's released; after `0.1.0`, the next is `0.1.1.rc1`.
  A PR labeled `release:minor` or `release:major` starts the next minor or major series instead (`0.2.0.rc1`,
  `1.0.0.rc1`); the first ever is `0.1.0.rc1`.
- **Releases.** Untick "Set as a pre-release" on the latest candidate's GitHub release: the workflow publishes `X.Y.Z`
  from that candidate's commit to RubyGems, tags it `vX.Y.Z` with a release whose notes hold every change since the
  previous release (all its candidates'), and ticks the candidate back as a pre-release. A candidate that can't be
  released (not the latest of its series, or its version already released) is ticked back, and the run fails with why.

Candidates are pre-releases on RubyGems: `gem install noticed-openwa --pre`, or name one in a Gemfile
(`gem "noticed-openwa", "0.1.0.rc1"`). A version can't be replaced: a mistake ships as the next candidate.

## License

MIT.
