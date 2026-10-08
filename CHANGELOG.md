# Changelog

## [Unreleased]

- Heroku: a rollout line under Deployed counts the dynos of each process type
  running the deployed release (`web 1/3, 2 starting`) and says when every
  dyno is up on it. With preboot on, the handoff from the previous web dynos
  shows as an estimate. `--json` gains a `rollout` object.

## [0.2.0] - 2026-10-07

- Heroku: Deployed is the release Heroku is serving, not the newest one. A
  newer release still in its release phase shows as `Releasing`, a failed one
  as `Failed`, and neither counts as on air. While such a release carries a
  different commit, `pinned` and `★ current` stay quiet. `--json` gains a
  `release` object.

## [0.1.0]

- Initial release: Heroku adapter with netrc auth, full behavior parity with
  the reference bash script, TTY renderer with ANSI colors and OSC 8 links.
