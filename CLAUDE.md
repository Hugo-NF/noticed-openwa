# noticed-openwa

A Ruby gem: WhatsApp delivery for noticed through OpenWA's REST API (written against OpenWA 0.30.0). It knows
nothing of the apps that use it.

## Commands

```bash
bundle exec rake                      # RuboCop and the specs
bundle exec rspec                     # the specs (replaying cassettes)
bundle exec rspec spec/noticed/openwa/client_spec.rb
bundle exec rubocop                   # lint; -A to auto-fix
VCR_RECORD_MODE=all bundle exec rspec <spec>   # re-record (needs a real session, see "Testing")
git tag --list 'v*' | ruby script/release_version.rb next_rc   # the version the next push to main publishes
```

## Scope

- Only what a delivery needs: sending a text, an image and a document to a chat, checking a number is on WhatsApp, and
  their errors. No sessions, groups, chats, contacts, OpenWA webhooks' administration or anything else of OpenWA's API.
- No reference to an app: no models, `Rails.application`, routes or templates. The app passes values or lambdas as the
  delivery method's options.
- Runtime dependencies: noticed and Ruby's standard library (`net/http`, `json`, `base64`, `openssl`). The client
  doesn't use ActiveSupport, so it can be used outside Rails.

## Layout

- `lib/noticed/openwa/client.rb`: `Noticed::Openwa::Client`, the HTTP calls (`X-API-Key`, `Idempotency-Key` on every
  send, files as base64, never by URL).
- `lib/noticed/openwa/error.rb`: the errors. The base `Error` (status, OpenWA's `code`, `retry_after`) has a body; the
  one-line subclasses stay beside it. A new error with a body goes in its own file.
- `lib/noticed/delivery_methods/openwa.rb`: `Noticed::DeliveryMethods::Openwa` (`deliver_by :openwa`), loaded on first
  use (an autoload in `lib/noticed/openwa.rb`): it's an Active Job and needs the app's jobs.
- `spec/support/dummy_app.rb`: the minimal Rails app noticed needs in the specs.
- `script/release_version.rb`: the release versions, from the tags; `.github/workflows/release.yml` publishes them.

## Errors

| Error | When |
|---|---|
| `AuthenticationError` | `401`, `403` |
| `NotOnWhatsappError` | A `400` whose message says WhatsApp can't resolve the recipient |
| `RetryableError` | Nothing was sent: a session not started (`400`) or not ready (`409`), `IDEMPOTENCY_KEY_IN_PROGRESS`, `408`, `429`, `5xx`, a network error |
| `UnknownOutcomeError` | `409 IDEMPOTENCY_OUTCOME_UNKNOWN`: the message may have been sent |
| `RequestError` | Any other refusal |

- Error messages name the call, the status, OpenWA's code and reason, with phone numbers filtered out (`NUMBER`).
  Never put a request's body, a number, a text or a key in a message or a log: apps send errors to their trackers.
- Map a new OpenWA status or code here and in the README's table, with a spec.

## Testing

- RSpec with VCR (`spec/fixtures/vcr_cassettes/`, `vcr:` metadata, `record: :once`): an existing cassette is only
  replayed, and a request missing from it raises. CI replays with `VCR_RECORD_MODE=none`.
- Record every interaction with OpenWA in a cassette, against a real, paired session. Never mock it with WebMock's
  `stub_request`; assert on requests with `a_request(...)` and `have_been_made`.
- Ask the maintainer before recording a call that has no cassette yet: they record new cassettes themselves, with their
  own session (`.env.test.local`, git-ignored; the README's "Recording the cassettes").
- Never send to a number that isn't the maintainer's: `OPENWA_TEST_NUMBER` is theirs. A spec about a number not on
  WhatsApp checks it first and stops before sending if it is (a real account would receive the message).
- `spec/spec_helper.rb` replaces the URL's host, the key, the session and both numbers (with and without the ninth
  digit) with placeholders, valid in a URI and none a prefix of another, and replays them with its defaults. Check a new
  cassette for real values before committing it.
- For answers a real session can't give (`409`, `429`, `503`), use the ERB template of a real cassette
  (`templates/send_text.yml`, its placeholders at the top) with `erb:` and `record: :none`. Never edit a recorded
  interaction by hand.
- The action under test is the `subject`; `aggregate_failures` for several expectations; one action per example.

## Code style

- RuboCop (`rubocop-rails-omakase`, `rubocop-rspec`), 120 characters per line.
- Guard clauses with a blank line after. `&.` over explicit nil checks.
- Comments say why, not what; no issue references (`#123`) in comments.
- Supported Rubies: 3.3 and up (`required_ruby_version`, CI's matrix).

## Releases

- Automated (the README's "Releases", `.github/workflows/release.yml`): every push to `main` that passes CI publishes a
  release candidate (`X.Y.Z.rcN`) to RubyGems and as a GitHub pre-release; the maintainer unticking "Set as a
  pre-release" on the latest candidate publishes `X.Y.Z` from its commit. A PR's `release:minor` / `release:major` label
  starts the next minor or major series; otherwise a release is followed by the next patch's candidates.
- Versions come from the tags (`script/release_version.rb`, with its specs). Never bump
  `lib/noticed/openwa/version.rb` (a placeholder the workflow fills), create a `v*` tag or release, or `gem push` by
  hand. There's no CHANGELOG: each release's notes are GitHub's, generated from the PRs, and a release's hold all its
  candidates'.
- RubyGems trusts the release workflow (trusted publishing, no API key): renaming `release.yml` breaks publishing until
  the trusted publisher on rubygems.org is updated.

## Commits and pull requests

- Present tense, the subject at most 50 characters, a blank line, the body wrapped at 72.
- A PR that should start a minor or major version gets the `release:minor` or `release:major` label before it's merged.
- Run RuboCop and the specs before committing. Commit and push only when the maintainer asks; never force-push.
- Don't co-author commits, and add no AI note to commits or pull requests.
