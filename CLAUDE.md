# noticed-openwa

A Ruby gem: WhatsApp delivery for noticed through OpenWA's REST API (the versions it supports: the README's "OpenWA
versions"). It knows nothing of the apps that use it.

## Commands

```bash
docker compose up -d                  # a local OpenWA on http://localhost:2785 (README, "A local OpenWA")
bundle exec rake                      # RuboCop and the specs
bundle exec rspec                     # the specs (replaying cassettes)
bundle exec rspec spec/noticed/openwa/client_spec.rb
bundle exec rubocop                   # lint; -A to auto-fix
OPENWA_RECORD=true VCR_RECORD_MODE=all bundle exec rspec <spec>   # re-record (a real session, see "Testing")
git tag --list 'v*' | ruby script/release_version.rb next_rc   # the version the next push to main publishes
```

## Scope

- Only what a delivery needs: sending a text, an image and a document to a chat, checking a number is on WhatsApp,
  reading the session's status, registering, listing and unregistering the session's own webhook (by its URL),
  verifying and parsing its deliveries into events (no state: the app keeps routes, jobs and persistence), and their
  errors. No session administration (starting, stopping, pairing), groups, chats, contacts, the rest of OpenWA's
  webhook administration (deleting others' webhooks, testing, delivery failures, redrives) or anything else of
  OpenWA's API.
- No reference to an app: no models, `Rails.application`, routes or templates. The app passes values or lambdas as the
  delivery method's options.
- Runtime dependencies: noticed and Ruby's standard library (`net/http`, `json`, `base64`, `openssl`). noticed is a
  Rails engine, so the gem needs Rails, the client included; still, the client itself uses only the standard library.

## Layout

- `lib/noticed/openwa/client.rb`: `Noticed::Openwa::Client`, the HTTP calls (`X-API-Key`, `Idempotency-Key` on every
  send, files as base64, never by URL, the session's webhook registered and unregistered by its URL).
- `lib/noticed/openwa/webhook.rb`: `Noticed::Openwa::Webhook`, verifying (`X-OpenWA-Signature`) and parsing a
  delivery into an `Event` (`Data`), or nil for an event it doesn't handle.
- `lib/noticed/openwa/error.rb`: the errors. The base `Error` (status, OpenWA's `code`, `retry_after`) has a body; the
  one-line subclasses stay beside it. A new error with a body goes in its own file.
- `lib/noticed/delivery_methods/openwa.rb`: `Noticed::DeliveryMethods::Openwa` (`deliver_by :openwa`), loaded on first
  use (an autoload in `lib/noticed/openwa.rb`): it's an Active Job and needs the app's jobs.
- `lib/noticed/bulk_delivery_methods/openwa.rb`: `Noticed::BulkDeliveryMethods::Openwa` (`bulk_deliver_by :openwa`),
  once per event to one chat or a list, autoloaded the same way. Both delivery methods send through
  `lib/noticed/openwa/delivery.rb` (`Noticed::Openwa::Delivery`): a change to sending goes there, for both.
- `spec/support/dummy_app.rb`: the minimal Rails app noticed needs in the specs.
- `script/release_version.rb`: the release versions, from the tags; `.github/workflows/release.yml` publishes them.
- `script/webhook_fixtures.rb`: turns real deliveries (the requests the webhook's URL received) into
  `spec/fixtures/webhooks/`.

## Errors

| Error | When |
|---|---|
| `AuthenticationError` | `401`, `403` |
| `NotOnWhatsappError` | A `400` whose message says WhatsApp can't resolve the recipient |
| `RetryableError` | Nothing was sent: a session not started (`400`) or not ready (`409`), `IDEMPOTENCY_KEY_IN_PROGRESS`, `408`, `429`, `5xx`, a network error |
| `UnknownOutcomeError` | `409 IDEMPOTENCY_OUTCOME_UNKNOWN`: the message may have been sent |
| `MessageNotFoundError` | A `404` whose message says a message isn't found, outside a send |
| `QuotedMessageNotFoundError` | The same `404` from a send (a `MessageNotFoundError`): the sends retry once without the quote |
| `RequestError` | Any other refusal |
| `InvalidSignatureError` | A webhook delivery whose `X-OpenWA-Signature` is missing, malformed or not the body's |

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
- Every variable the specs read (`OPENWA_*`) is listed in the README's recording table and in `.env.test.example`
  (never with a real value), and has a placeholder in `spec/spec_helper.rb` (its default, and its filter when it's a
  value to keep out of cassettes).
- Never send to a number or a group that isn't the maintainer's: `OPENWA_TEST_NUMBER` and `OPENWA_TEST_GROUP` are
  theirs. A spec about a number not on WhatsApp checks it first and stops before sending if it is (a real account
  would receive the message).
- `spec/spec_helper.rb` replaces the URL (scheme, host and port), the key, the session, the webhook's URL and secret,
  the session account's number and name, the test group's id, and both numbers (with and without the ninth digit) with
  placeholders, valid in a URI and none a prefix of another, drops the `Host` header, and replays them with its
  defaults. It reads `.env.test.local` only with `OPENWA_RECORD=true`. Check a new cassette for real values before
  committing it.
- Record against the local OpenWA (`docker-compose.yml`, `http://localhost:2785`, the README's "A local OpenWA"): VCR
  records `localhost`; only `127.0.0.1` passes through.
- For answers a real session can't give (`409`, `429`, `503`), use the ERB template of a real cassette
  (`templates/send_text.yml`, its placeholders at the top) with `erb:` and `record: :none`. Never edit a recorded
  interaction by hand.
- Webhook deliveries are fixtures in `spec/fixtures/webhooks/` (JSON: `note`, `headers`, `body`), made by
  `script/webhook_fixtures.rb` from real deliveries (the README's "Recording the webhook fixtures"): filtered, and
  signed again with the specs' secret. Never write or edit one by hand; a delivery a recording can't trigger is built
  in its spec, from OpenWA's code, and says so.
- The action under test is the `subject`; `aggregate_failures` for several expectations; one action per example.

## Code style

- RuboCop (`rubocop-rails-omakase`, `rubocop-rspec`), 120 characters per line.
- Everything the gem returns is a Ruby hash with snake_case symbol keys: OpenWA's answers go through
  `Noticed::Openwa::Keys.symbolize` (the client converts every successful answer; the webhook parser, its payload). Only
  keys change, never values; the gem reads OpenWA's string keys only internally, before converting.
- Guard clauses with a blank line after. `&.` over explicit nil checks.
- Comments say why, not what; no issue references (`#123`) in comments.
- Supported Rubies: 3.3 and up. A change to them changes, together: the gemspec's `required_ruby_version`, the
  `specs` matrix in `ci.yml` (its oldest entry is the gemspec's minimum), `.rubocop.yml`'s `TargetRubyVersion` (the
  minimum), and the newest Ruby the other jobs use (`lint`, `audit`, `release.yml`'s); the README states the minimum.
- The README's badges: the gem's version and downloads and CI's status update by themselves; the license, Ruby, noticed
  and OpenWA badges are static text, changed with what they state (the gemspec's license, `required_ruby_version`, the
  noticed range, the "OpenWA versions" table).
- The delivery method's options are evaluated on each delivery (a value, a lambda or a method name, through
  `evaluate_option`). A new option or default stays that way: never a value computed when the class loads (a time, an
  `ENV` read, a locale), which would keep the moment the class was loaded.

## Releases

- Automated (the README's "Releases", `.github/workflows/release.yml`): every push to `main` that passes CI publishes a
  release candidate (`X.Y.Z.rcN`) to RubyGems and as a GitHub pre-release; the maintainer unticking "Set as a
  pre-release" on the latest candidate publishes `X.Y.Z` from its commit. A PR's `release:minor` / `release:major` label
  starts the next minor or major series from the open one, released or not, unless the open series already is one;
  otherwise a release is followed by the next patch's candidates.
- Versions come from the tags (`script/release_version.rb`, with its specs). Never bump
  `lib/noticed/openwa/version.rb` (a placeholder the workflow fills), create a `v*` tag or release, or `gem push` by
  hand. There's no CHANGELOG: each release's notes are GitHub's, generated from the PRs, and a release's hold all its
  candidates'. The first release has no previous one to start from: `script/release_version.rb first_notes` lists
  every PR merged since the beginning.
- Tags are never moved or recreated, and a version on RubyGems can't be replaced: a wrong candidate or release ships as
  the next one (`gem yank` only hides a version).
- RubyGems trusts the release workflow (trusted publishing, no API key): renaming `release.yml` breaks publishing until
  the trusted publisher on rubygems.org is updated. `.github/actions/rubygems-credentials` exchanges its OIDC token,
  naming the owning account (`RUBYGEMS_OWNER`, its immutable ID), which a pending trusted publisher requires.

## Local OpenWA

- `docker-compose.yml` runs the latest OpenWA in the README's "OpenWA versions" table, with its own Postgres, on
  `http://localhost:2785`. Every image is pinned to a version and every service has a memory limit; a new service gets
  both, and every secret is a local-only default.
- A new OpenWA version (Dependabot's PR, or by hand) changes, together: the compose file's image, a new row at the
  top of the README's "OpenWA versions" table (`Tested`, or `Unchecked` for one only compared by its `openapi.json`),
  and the cassettes and webhook fixtures whose request or answer changed (re-recorded by the maintainer). Record them
  all again and compare each with the committed one (statuses, headers, body shapes; not ids or times): an unchanged
  one stays as it was. The specs replaying the old cassettes passing doesn't prove the new version answers the same.
  A version is dropped from the table only when the gem stops working with it, with a spec.

## CI and dependencies

- `ci.yml` runs on pull requests, on pushes to `main` (docs, the issue templates and `docker-compose.yml` aside) and
  weekly (Mondays, 09:00 UTC): `lint` (RuboCop), `specs` (each supported Ruby, replaying the cassettes), `audit`
  (bundler-audit on `Gemfile.lock`) and `actionlint` (the workflows, shellcheck on each `run:` included). A push to
  `main` that passes it publishes a release candidate; a scheduled run publishes nothing.
- `coverage` (octocov, `.octocov.yml`, not on the weekly run) reports the Ruby 4.0 run's SimpleCov coverage of `lib/`
  (`.simplecov`) and the specs' execution time: a comment on pull requests with the diff against `main`, and `main`'s
  report as an artifact. Below the threshold (`acceptable`, 97%: the lowest coverage measured when it was introduced,
  rounded down) it fails; never lower it to let a PR pass.
- Actions are on major tags (a version where an action has none), kept current by Dependabot
  (`.github/dependabot.yml`): weekly, Mondays 07:00 `America/Sao_Paulo`, the bundle's and the actions' minor and patch
  updates grouped, each major in its own PR, and the compose file's images. Security updates open at once.
- `main`'s ruleset requires CI's jobs as status checks (`specs` once per Ruby): a change to CI's jobs or to the
  supported Rubies changes the ruleset's checks too (GitHub's settings, Rules).
- The gemspec's dependency range (`noticed`) is changed by hand, with the specs run against the range's ends when it
  widens.

## Commits and pull requests

- Present tense, the subject at most 50 characters, a blank line, the body wrapped at 72. On an issue's branch, prefix
  the subject with its scope and number, taken from the branch name (`feature/1: Register the session's webhook`).
- A PR that should start a minor or major version gets the `release:minor` or `release:major` label before it's merged.
- Run RuboCop and the specs before committing (`bundle exec rake`). Commit and push only when the maintainer asks;
  never force-push.
- Don't co-author commits, and add no AI note to commits or pull requests.
- A push to `main` that changes the gem publishes a release candidate (see "Releases"). A commit that only changes
  docs, the issue templates or `docker-compose.yml` publishes none; one that also touches other files without changing
  the gem (a spec helper, CI) carries `[skip ci]` in its subject, when the maintainer agrees.

## AI-assisted workflow

### Issues

- Use the templates in `.github/ISSUE_TEMPLATE/`. AI-written issues get the `ai-generated` label; add others as
  appropriate (`enhancement`, `bug`, `documentation`, `question`).
- Set every issue's type (Bug, Feature or Task; the templates pre-fill Bug or Feature): `gh issue create` can't, so
  set it after creating the issue, `gh api -X PATCH repos/Hugo-NF/noticed-openwa/issues/<n> -f type=<type>`.
- Link "blocked by" / "blocks" relationships: `gh api repos/Hugo-NF/noticed-openwa/issues/<n>/dependencies/blocked_by
  -F issue_id=<id>`, where `<id>` is the blocking issue's `id` (`gh api repos/<owner>/<repo>/issues/<number> --jq
  .id`), not its number. Issues of other repositories can be linked the same way.
- Issues, PRs and commits name no app that uses the gem: they're about OpenWA and noticed (the repository is
  public). An app's issue may reference this repository's; not the other way around.
- Before implementing, list the open decisions and confirm them with the maintainer. Record the confirmed decisions
  as a comment on the issue.

### Implementing an issue

Work on one issue at a time.

1. Assign the issue to the maintainer (`@me`) if it isn't already.
2. Branch from `origin/main`, named after the issue (for example `feature/1_register_webhook`, `bugfix/4_...`).
3. Commit and push only when the maintainer asks: they often review the working tree first. Never force-push. If a
   push is blocked by a permission check, stop and tell the maintainer; don't work around it.
4. A new OpenWA interaction needs a cassette: ask the maintainer, who records it against the local OpenWA (see
   "Testing").
5. Open the PR against `main` following `.github/pull_request_template.md`:
   - title `[<issue number>] Description`, body with `Closes #<issue number>`
   - the `ai-generated` label and **no other AI note anywhere** (no "Generated with Claude Code" footer, no session
     links)
   - other labels as appropriate, and `release:minor` / `release:major` when it starts a minor or major version
   - assigned to the maintainer (`--assignee @me`)
6. Don't merge: merging publishes a release candidate. The maintainer reviews and merges, or asks for corrections.

### GitHub CLI

- `gh issue view` and `gh pr edit` can fail on the Projects (classic) deprecation: use `--json` with `gh issue view`
  and `gh api` REST calls for edits.

### Answering questions

- When the maintainer asks a clarifying question, answer it and stop. Don't propose new work or issues; the maintainer
  asks to register an issue when needed.
