---
name: Feature / task spec
about: New feature, improvement or a well-scoped task ready to hand off
title: ""
labels: enhancement
type: Feature
---
<!---
    Fill out the sections below. Remove any section that doesn't apply.
    Write it so someone (or an AI agent) with no prior context can implement it.
    If you're an AI:
      - add the ai-generated label
      - set the issue type (Feature for new functionality, Task for a scoped piece of work):
        gh api -X PATCH repos/Hugo-NF/noticed-openwa/issues/<n> -f type=<type>
      - add release:minor or release:major when it should start a minor or major version (the README's "Releases")
      - link "blocked by" / "blocks" relationships to other issues
-->

> <!-- Optional: "Part N of M of <epic>. Blocked by #x. Blocks #y. Branch off `main` once #x is merged." -->

### Context

<!-- Why this is needed and the rules behind it. Include decisions already taken. Keep it about OpenWA and noticed: the gem references no app. -->

### Current state

<!-- What already exists and should be kept (files, commits). What's missing or broken. -->

### Tasks

#### 1.

- [ ]

### Out of scope

<!-- What this issue deliberately doesn't cover, and where it goes (issue number or "future ticket"). -->

### Acceptance criteria

- [ ]
- [ ] New OpenWA interactions have cassettes (recorded by the maintainer, CLAUDE.md "Testing")
- [ ] The README documents the new behavior
- [ ] Tests cover the new behavior
- [ ] RuboCop and the specs pass (`bundle exec rake`)

### Dependencies

- Blocked by: <!-- #123 -->
- Blocks: <!-- #123 -->

### References

<!-- Related issues, PRs, OpenWA's API (openapi.json, its version), diagrams. -->
