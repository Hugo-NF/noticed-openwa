# noticed-openwa

[![Gem](https://img.shields.io/gem/v/noticed-openwa)](https://rubygems.org/gems/noticed-openwa)
[![Downloads](https://img.shields.io/gem/dt/noticed-openwa)](https://rubygems.org/gems/noticed-openwa)
[![CI](https://github.com/Hugo-NF/noticed-openwa/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Hugo-NF/noticed-openwa/actions/workflows/ci.yml?query=branch%3Amain)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-%E2%89%A5%203.3-red)](#installation)
[![noticed](https://img.shields.io/badge/noticed-2%20%7C%203-blue)](https://github.com/excid3/noticed)
[![OpenWA](https://img.shields.io/badge/OpenWA-0.30-green)](#openwa-versions)
[![Code style](https://img.shields.io/badge/code%20style-rubocop-brightgreen)](https://github.com/rails/rubocop-rails-omakase)

WhatsApp delivery for [noticed](https://github.com/excid3/noticed) through [OpenWA](https://github.com/rmyndharis/openwa),
a self-hosted WhatsApp gateway. Supports OpenWA 0.30 (see "OpenWA versions").

It implements only what a delivery needs: sending a text, an image or a document to a number, checking a number is on
WhatsApp, reading the session's status, registering (or unregistering) the session's webhook, and verifying and
parsing its deliveries. Managing sessions, groups, contacts and the rest of OpenWA's webhook administration are left
to OpenWA itself.

## Installation

```ruby
gem "noticed-openwa"
```

Requires Ruby 3.3 or newer and noticed 2 or 3. noticed is a Rails engine, so the gem needs Rails too, the client
included.

### OpenWA versions

| OpenWA | |
|---|---|
| 0.30.3 | Tested |
| 0.30.2 | Unchecked |
| 0.30.1 | Unchecked |
| 0.30.0 | Tested |

Tested: the cassettes and webhook fixtures were recorded against a real session of that version. Unchecked: not run
against a session, though its API (`openapi.json`) is the same for every call the gem makes.

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
| `idempotency_key` | Defaults to `noticed-<notification id>`; an ephemeral notifier has none: pass one so a retried job doesn't send twice |
| `ca_file` | A CA bundle to trust, for an OpenWA behind a private CA's certificate |
| `after_send` | Called once every message was sent, with OpenWA's answers (`[{ "messageId" =>, "timestamp" => }, ...]`, in order): a lambda run on the notification with the answers, or a notifier method's name, called with the notification and the answers. Not called when a send fails |
| `not_on_whatsapp` | Called instead of failing the job when WhatsApp can't resolve the recipient (`NotOnWhatsappError`; retrying right away gets the same answer), with the chat id and the error: a lambda run on the notification, or a notifier method's name, called with the notification, the chat id and the error. Without it, the error is raised |

Each option is a value, a lambda evaluated on the notification, or the name of a notifier method, as in noticed's own
delivery methods (`after_send` also gets the answers).

Without files it sends the text. With files it sends one message per file, the text as the last one's caption, so the
chat shows it under the files without scrolling back: images (`image/*`) as images, the rest as documents. OpenWA
has no album: several images arrive as separate messages. Files are sent as base64, never by URL.

Every message carries an `Idempotency-Key` (the option's key, suffixed `-1`, `-2`, ... per file): a retried job gets
OpenWA's first answer replayed instead of sending again.

`not_on_whatsapp` lets the app flag a recipient's number instead of failing the job every time. The error means
WhatsApp can't resolve the recipient *for this session*, not always that the number has no WhatsApp: WhatsApp Web
sometimes won't give a number's id (its LID) to a session that never had a chat with it, and OpenWA answers the two
cases alike (a known whatsapp-web.js limitation). Once the recipient messages the session, sends to them work. So don't
drop the number: flag it, offer another channel (an OTP by SMS, say), or check it (`Client#check_number`, which can
still find it):

```ruby
deliver_by :openwa, # ...
           not_on_whatsapp: ->(chat_id, error) { recipient.update!(whatsapp_unreachable_at: Time.current) }
```

`after_send` lets the app match the webhook's receipts (`Event#message_id`, "Webhook deliveries") to the notification
that sent the message, keeping the ids in a column of its own (here a JSON array, on Postgres):

```ruby
deliver_by :openwa, # ...
           after_send: ->(answers) { update!(openwa_message_ids: answers.pluck("messageId")) }

# On a message.ack delivery:
notification = Noticed::Notification.find_by("openwa_message_ids @> ?", [ event.message_id ].to_json)
notification&.mark_as_read! if event.status == "read"
```

### noticed's options

noticed handles these for every delivery method, `:openwa` included
([noticed's README](https://github.com/excid3/noticed#readme)):

| Option | |
|---|---|
| `if`, `unless` | Skip the delivery when falsey (`if`) or truthy (`unless`), checked by the job when it runs |
| `wait`, `wait_until`, `queue`, `priority` | The job's delay, time, queue and priority |
| `before_enqueue` | `throw :abort` to not enqueue the job at all |
| `class` | The name of a class to deliver with instead, such as a subclass of `Noticed::DeliveryMethods::Openwa` |

Lambdas are evaluated on the notification (`after_send`'s with the answers). A notification has noticed's `t`, so a key
starting with a period is looked up under `notifiers.<notifier>.notification`:

```ruby
class BookingConfirmedNotifier < Noticed::Event
  deliver_by :openwa,
             # url:, api_key:, session_id: and to: as above
             text: -> { t(".message") }, # notifiers.booking_confirmed_notifier.notification.message
             if: -> { recipient.whatsapp_opt_in? },
             wait: 5.minutes,
             queue: :notifications
end
```

Ephemeral notifiers (`Noticed::Ephemeral`) deliver the same way, without saving anything: see `idempotency_key`. Their
notification isn't saved either, so `after_send` keeps the answers elsewhere (on the `record`, for example).

## Bulk delivery method

`deliver_by :openwa` sends a message to each recipient. `bulk_deliver_by :openwa` sends **once per event**, whatever
its recipients, to chats of the app's choosing: a team's group, or a few numbers. It's noticed's bulk delivery, as its
Slack or Discord ones post once to a channel:

```ruby
class BookingConfirmedNotifier < Noticed::Event
  bulk_deliver_by :openwa,
                  url: -> { ENV["OPENWA_URL"] },
                  api_key: -> { ENV["OPENWA_API_KEY"] },
                  session_id: -> { ENV["OPENWA_SESSION_ID"] },
                  to: -> { ENV["OPERATIONS_WHATSAPP_GROUP"] }, # "120363012345678901@g.us"
                  text: -> { "New booking: #{record.reference}" }
end
```

Its options are `deliver_by :openwa`'s, evaluated on the event instead of a notification (there's none), and so are
noticed's (`if`, `unless`, `wait`, `queue`, ...). The differences:

| Option | |
|---|---|
| `to` | Required: a phone number or a chat id, a group's included (`<digits>@g.us`), or a list of them: one message each, in order, in the same job. An empty list sends nothing |
| `idempotency_key` | Defaults to `noticed-event-<event id>` (apart from a notification's `noticed-<id>`, which can share the number); with a list, each chat's is suffixed `-chat1`, `-chat2`, ..., so a job retried after a failure halfway replays the chats already sent. An ephemeral notifier's event has none: pass one |
| `after_send` | Called once every message was sent, with OpenWA's answers for every chat, in order: a lambda run on the event with the answers, or a notifier method's name, called with the event and the answers |
| `not_on_whatsapp` | Called for each chat WhatsApp can't resolve, with the chat id and the error: a lambda run on the event, or a notifier method's name, called with the event, the chat id and the error. The other chats of a list are still sent; without it, the error is raised and the chats after it aren't |

A group's chat id is what WhatsApp holds for it: the session must be in the group, and the client sends to it as to any
other chat. The delivery method's retries go on its own load hook:

```ruby
ActiveSupport.on_load(:noticed_bulk_delivery_methods_openwa) do
  retry_on Noticed::Openwa::RetryableError, wait: :polynomially_longer, attempts: 5
end
```

## The client

```ruby
client = Noticed::Openwa::Client.new(url:, api_key:, session_id:)

client.check_number("+55 61 90000-0001")   # => { exists: true, whatsapp_id: "556100000001@c.us" }
client.send_text(chat_id, "Hello", idempotency_key: "welcome-42")
client.send_image(chat_id, content: png_bytes, mimetype: "image/png", caption: "...")
client.send_document(chat_id, content: pdf_bytes, mimetype: "application/pdf", filename: "ticket.pdf", caption: "...")
client.send_message(chat_id, text: "...", files: [...], idempotency_key: "...")
Noticed::Openwa::Client.chat_id("+55 61 90000-0001") # => "5561900000001@c.us"
```

The chat id WhatsApp holds can differ from a number's digits (Brazilian mobiles may be held without their ninth digit):
send to the `whatsapp_id` the check returns. A number the check finds can still fail to send with `NotOnWhatsappError`,
when WhatsApp Web won't resolve it for the session ("Errors").

`send_text` and `send_message` take `link_preview:` (`true` or `false`) for a URL in the text. Left out, it isn't
sent, and the session's own `linkPreview` config decides (OpenWA's default otherwise: a preview on whatsapp-web.js,
none on Baileys). The delivery method leaves it out.

### The session's status

```ruby
client.session_status
# => { state: "ready", reason: nil, restriction: nil, raw: { "id" => "...", "status" => "ready", ... } }
```

- `state` is OpenWA's status, the same values as the `session.status` webhook events: `"created"`, `"initializing"`,
  `"qr_ready"`, `"authenticating"`, `"ready"`, `"disconnected"`, `"action_required"` or `"failed"`. After a logout it
  passes `"disconnected"` and settles on `"qr_ready"`, waiting to be paired again.
- `reason` is OpenWA's `lastError`, while the session is `failed`, `action_required` or reconnecting.
- `restriction` is the restriction WhatsApp placed on the account (`{ kind:, code:, expires_at: }`), nil without one.
  A restricted session can still be `ready`.
- `raw` is OpenWA's answer. It holds the account's phone and name too, so keep it out of logs.

A webhook delivery can be lost (OpenWA down, or unable to reach the app): poll it, for example from a scheduled job,
to notice a logged-out session. An unknown session raises `RequestError`.

### The session's webhook

OpenWA reports what happens to a sent message (`message.ack`) and to the session (`session.status`,
`session.disconnected`, ...) through a webhook registered on the session. The client registers it:

```ruby
client.register_webhook(url: "https://app.example.com/openwa/events", secret: ENV["OPENWA_WEBHOOK_SECRET"],
                        events: %w[message.ack session.status session.disconnected session.reconnect_loop
                                   session.restriction],
                        retry_count: 3)   # => { "id" => "...", "url" => "...", "events" => [...], "active" => true, ... }
client.webhooks                           # => the session's webhooks, without their secrets and headers
client.unregister_webhook(url: "https://app.example.com/openwa/events")   # => 1, the webhooks deleted
```

It's idempotent: the session's first webhook with the same URL is updated (its events, secret and retries, and it's
activated again), otherwise one is created. Call it on every deploy, or whenever a session is created or replaced:
a new session has no webhook. `headers:` (a hash) is optional: when given, it replaces the webhook's custom headers;
left out, an update keeps them.

The secret (16 to 255 characters) signs every delivery: OpenWA sends `X-OpenWA-Signature: sha256=<hex>`, the HMAC-SHA256
of the body. It's never returned, so keep it where the app that receives the deliveries can verify them.

`unregister_webhook` deletes every webhook of the session with that URL, and returns how many (0 when there was none,
without an error). Other webhooks of the session, and testing or redriving webhooks, are left to OpenWA's dashboard.

## Webhook deliveries

`Noticed::Openwa::Webhook` verifies a delivery and turns its body into an event; the route, the controller, the jobs
and what each event means stay in the app. It holds no state and needs no configuration:

```ruby
class OpenwaEventsController < ActionController::API
  def create
    body = request.raw_post
    Noticed::Openwa::Webhook.verify!(body, request.headers, ENV["OPENWA_WEBHOOK_SECRET"])
    event = Noticed::Openwa::Webhook.parse(body, request.headers)
    OpenwaEventJob.perform_later(event.payload) if event   # or act on the event's fields here
    head :ok
  rescue Noticed::Openwa::InvalidSignatureError
    head :unauthorized
  end
end
```

- **`verify!(raw_body, headers, secret)`** checks `X-OpenWA-Signature` (`sha256=<hex>`, the HMAC-SHA256 of the raw
  body with the webhook's secret) in constant time. It raises `Noticed::Openwa::InvalidSignatureError` when the
  header is missing, malformed or not the body's. Pass the body exactly as received, before any parsing. `headers` is
  Rails' `request.headers`, a Rack env or a hash in any case. OpenWA signs no timestamp, and its retries and redrives
  keep the first one, so there's no time window: dedupe on the event's `idempotency_key` instead.
- **`parse(raw_body, headers)`** returns a `Noticed::Openwa::Webhook::Event`, or `nil` for an event it doesn't handle
  (so the webhook can subscribe to more). A body that isn't OpenWA's raises `Noticed::Openwa::Error`.

Every event has `type` (`:message_status` or `:session_state`), `event` (OpenWA's, such as `"message.ack"`),
`idempotency_key` (the same across OpenWA's retries and redrives of a delivery), `occurred_at` (a `Time`),
`session_id` and `payload` (the parsed body):

| OpenWA's event | `type` | Fields |
|---|---|---|
| `message.ack` | `:message_status` | `status`: `"sent"`, `"delivered"`, `"read"` or `"failed"`; `message_id`; `chat_id` |
| `session.status` | `:session_state` | `state`: OpenWA's status (`"created"`, `"initializing"`, `"qr_ready"`, `"authenticating"`, `"ready"`, `"disconnected"`, `"action_required"`, `"failed"`) |
| `session.disconnected` | `:session_state` | `state: "disconnected"`; `reason` (`"LOGOUT"`, ...) |
| `session.reconnect_loop` | `:session_state` | `state: "reconnecting"`; `details`: `{ attempts:, next_delay_ms: }` |
| `session.restriction` | `:session_state` | `state: "restricted"`, or `"unrestricted"` when lifted; `details`: `{ kind:, code:, expires_at: }` |

- **`message_id`** is the `messageId` the `send_*` call returned. **`chat_id`** is the chat as WhatsApp holds it,
  often a LID (`<digits>@lid`) rather than the number the message was sent to: match on `message_id`.
- A message's status only moves forward, and a status the phone skipped isn't sent: a message read at once has no
  `delivered`. OpenWA gives no reason for a failure.
- Subscribe to `message.ack`, not `message.failed`: OpenWA sends `message.failed` as well as the `failed` ack, under
  another idempotency key, so the parser skips it, along with `message.sent`.

## Errors

All are `Noticed::Openwa::Error`, with the HTTP `status`, OpenWA's `code` and, for a rate limit, `retry_after` (seconds).
Their messages name the call, the status and OpenWA's reason, with any phone number filtered out.

| Error | When | Retry? |
|---|---|---|
| `AuthenticationError` | `401`, `403`: the key is missing, unknown, revoked or out of its scope | No |
| `NotOnWhatsappError` | WhatsApp can't resolve the recipient for this session: the number isn't on WhatsApp, or WhatsApp Web won't give its id to this session (it can happen with a number the session never had a chat with) | Not right away: it works once the recipient messages the session. The delivery methods hand it to `not_on_whatsapp` when given |
| `RetryableError` | Nothing was sent: the session isn't started or ready, `IDEMPOTENCY_KEY_IN_PROGRESS`, a rate limit (`429`), a timeout, `5xx`, OpenWA unreachable | Yes, with the same key |
| `UnknownOutcomeError` | `IDEMPOTENCY_OUTCOME_UNKNOWN`: the message may have been sent | No: a new key may send it twice |
| `RequestError` | OpenWA refused the request itself | No |
| `InvalidSignatureError` | A webhook delivery's `X-OpenWA-Signature` is missing, malformed or not the body's (`Webhook.verify!`) | No: refuse the delivery |

Retrying is the app's choice, for example on the delivery method's load hook (the bulk one's is
`:noticed_bulk_delivery_methods_openwa`):

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

SimpleCov (`.simplecov`) measures the specs' coverage of `lib/` and writes `coverage/index.html`. In CI, octocov
(`.octocov.yml`) reports the Ruby 4.0 run's coverage and the specs' execution time: on a pull request, as a comment
with the diff against `main`; below 97% the `coverage` job fails.

### A local OpenWA

`docker-compose.yml` runs OpenWA (the version above) with its own Postgres, nothing else:

```
docker compose up -d
docker compose exec openwa cat /app/data/.api-key    # its API key, generated on the first start
```

Open `http://localhost:2785`, sign in with the key, create a session and pair it with a phone's WhatsApp (Linked
devices: scan the QR code); its status turns `ready`. `docker compose down` stops it and keeps the session (its volumes);
`docker compose down -v` forgets it. After a restart (`down` and `up`, or a new image) the session stays paired but
`disconnected`, as `AUTO_START_SESSIONS` is off: start it from the dashboard, or with
`POST /api/sessions/<id>/start`.

### Recording the cassettes

Copy `.env.test.example` to the git-ignored `.env.test.local` and fill in the session's values (each is explained
there), then delete the cassette (or set `VCR_RECORD_MODE=all`) and run its spec with `OPENWA_RECORD=true`, which reads
that file (without it, the specs always replay with the placeholders):

```
cp .env.test.example .env.test.local
OPENWA_RECORD=true VCR_RECORD_MODE=all bundle exec rspec spec/noticed/openwa/client_spec.rb
```

| Variable | |
|---|---|
| `OPENWA_URL`, `OPENWA_API_KEY`, `OPENWA_SESSION_ID` | The local OpenWA above, its key and a paired session |
| `OPENWA_CA_FILE` | A private CA's bundle, if OpenWA's certificate needs one |
| `OPENWA_TEST_NUMBER` | Your own number: it receives the test messages |
| `OPENWA_TEST_NUMBER_NOT_ON_WHATSAPP` | A number with no WhatsApp account |
| `OPENWA_TEST_WEBHOOK_URL` | A public URL you control: the webhook specs register it |
| `OPENWA_SESSION_PHONE`, `OPENWA_SESSION_PUSH_NAME` | The session account's own number and WhatsApp name, kept out of the cassettes |
| `OPENWA_TEST_GROUP` | A WhatsApp group of yours, with your number and the session in it, as its chat id (`<digits>@g.us`): it receives the bulk delivery method's test messages |
| `OPENWA_WEBHOOK_SECRET` | Optional: the webhook specs' secret (16 characters or more) |

A value is the rest of its line (no inline comments; quotes around it are dropped), and an empty one is the same
as leaving it out.

The URL (scheme, host and port), the key, the session, the webhook's URL and secret, the session account's number and
name, the test group's id, and both numbers (with and without the ninth digit) are replaced by placeholders in the
cassettes, the `Host` header isn't kept, and replayed with the placeholders of `spec/spec_helper.rb`. The "not on
WhatsApp" spec checks the number first and stops before sending if it is on WhatsApp: a real account would receive the
message. Check a new cassette for those values before committing it.

The webhook specs register `OPENWA_TEST_WEBHOOK_URL` on the session (OpenWA refuses a URL that doesn't resolve to a
public address): the session's events are delivered there while it exists. Each spec unregisters it before it ends,
so none is left on the session.

`spec/fixtures/vcr_cassettes/templates/send_text.yml` is an ERB template of a recorded send, for the answers a real
session can't be made to give (`409`, `429`, `503`); use it with `record: :none`.

### Recording the webhook fixtures

`spec/fixtures/webhooks/` holds real deliveries, filtered. To record them again, for a new OpenWA version:

1. Register `OPENWA_TEST_WEBHOOK_URL` on the session with a new secret, kept in a file
   outside the repository, and subscribe it to `message.ack`, `message.failed`, `message.sent` and the session's
   events.
2. Send a text to your `OPENWA_TEST_NUMBER` and open it on the phone, then log the session out (Linked devices) and
   pair it again.
3. Save the requests that URL received, oldest first, as
   `{ "data": [{ "headers": { ... }, "content": "<raw body>" }] }`, and run
   `ruby script/webhook_fixtures.rb <requests>.json <secret file>`. It checks each delivery's real signature, replaces
   the session, the WhatsApp ids and your number with placeholders, and signs the bodies again with the specs'
   secret. The acks a recording can't trigger on demand (`sent`, `delivered`, `failed`) and `message.failed` are made
   from the `read` ack, and their `note` says so.
4. Unregister the webhook, and check the fixtures for real values before committing them.

`session.reconnect_loop` and `session.restriction` can't be triggered: their specs build the body as OpenWA's code
does.

## Releases

Published by `.github/workflows/release.yml`; versions come from the tags (`script/release_version.rb`), and
`lib/noticed/openwa/version.rb` is a placeholder the workflow fills when it builds.

- **Release candidates.** Every push to `main` that passes CI (docs-only changes aside) publishes the next candidate,
  `X.Y.Z.rcN`, to RubyGems and as a GitHub pre-release tagged `vX.Y.Z.rcN`, with the changes since the previous tag as its
  notes. The series continues (`0.1.0.rc12` → `0.1.0.rc13`) until it's released; after `0.1.0`, the next is `0.1.1.rc1`.
  A PR labeled `release:minor` or `release:major` starts the next minor or major series from the open one instead,
  released or not (`0.1.0.rc2` → `0.2.0.rc1` or `1.0.0.rc1`), unless the open series already is one (`0.2.0.rc1` and
  a minor label → `0.2.0.rc2`); a series left behind is never released. The first ever is `0.1.0.rc1`.
- **Releases.** Untick "Set as a pre-release" on the latest candidate's GitHub release: the workflow publishes `X.Y.Z`
  from that candidate's commit to RubyGems, tags it `vX.Y.Z` with a release whose notes hold every change since the
  previous release (all its candidates'), and ticks the candidate back as a pre-release. The first release has no
  previous one: its notes list every pull request merged since the beginning. A candidate that can't be released (not
  the latest of its series, or its version already released) is ticked back, and the run fails with why.

Candidates are pre-releases on RubyGems: `gem install noticed-openwa --pre`, or name one in a Gemfile
(`gem "noticed-openwa", "0.1.0.rc1"`). A version can't be replaced: a mistake ships as the next candidate.

## License

MIT.
