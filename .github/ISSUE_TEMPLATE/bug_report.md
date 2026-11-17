---
name: Bug report
about: Something isn't working as expected
title: "[FIX] "
labels: bug
---
<!---
    Fill out the sections below. Remove any section that doesn't apply.
    If you're an AI:
      - add the ai-generated label
      - link "blocked by" / "blocks" relationships to other issues
      - keep the agent note below and fill in the branch and commit
-->

> [!IMPORTANT]
> **Note for the AI agent picking this up:** this issue was written against `<branch>` at commit `<sha>` (<date>). Before implementing anything, re-read the referenced code, confirm the bug is **still present**, and check whether it was already fixed or superseded (merged PRs, `git log`, related issues). If the behaviour changed, update this issue instead of applying the fix as written.

## Summary

<!-- One or two sentences: what's broken and why it matters. -->

## Current behavior

<!-- What happens today. Point to files, methods and lines (e.g. `lib/noticed/openwa/client.rb:42`). Include error messages, and OpenWA's answer when it's involved (never a real number, key or session). -->

## Expected behavior

<!-- What should happen instead. -->

## Steps to reproduce

1.

## Proposed direction

<!-- Root cause if known, and the suggested fix. Mark decisions that still need the maintainer. -->

## Out of scope

<!-- What this issue deliberately doesn't cover, and where it goes (issue number or "future ticket"). -->

## Acceptance criteria

- [ ] The bug no longer reproduces
- [ ] A test fails without the fix and passes with it (a new OpenWA interaction is a cassette the maintainer records)
- [ ] RuboCop and the specs pass (`bundle exec rake`)

## Dependencies

- Blocked by: <!-- #123 -->
- Blocks: <!-- #123 -->

## References

<!-- Related issues, PRs, OpenWA's API (openapi.json, its version), diagrams. -->
