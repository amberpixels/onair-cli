# Changelog

## [Unreleased]

- Heroku: Deployed is the release Heroku is serving, not the newest one. A
  newer release still in its release phase shows as `Releasing`, a failed one
  as `Failed`, and neither counts as on air, triggers `pinned`, or shows
  `★ current`. `--json` gains a `release` object.

## [0.1.0]

- Initial release: Heroku adapter with netrc auth, full behavior parity with
  the reference bash script, TTY renderer with ANSI colors and OSC 8 links.
