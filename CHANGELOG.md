# Changelog

## [Unreleased]

- GitHub Deployments: `platform: github_deployments` reads one environment's
  deployments (`environment:`, default `production`) through the GitHub API
  with the `gh` token, so anyone who can read the repo sees what is deployed
  without host access. The newest successful deployment is Deployed, a newer
  in-flight one is Pending with its commit, and a newer failed one is Failed.
  It reports what CI recorded, not what the host runs.
- `app:` is required only by the platforms that use it. `--json` gains an
  `environment` field, and `deployed` is `null` when nothing successful is deployed yet.

## [0.4.0] - 2026-11-02

- Dokku: `platform: dokku` with a `host:` reads the running commit from the
  last `git push` over SSH. A running build shows as `Pending` and a build
  that failed after the last success as `Failed`, both without a commit. The
  rollout line counts containers per process type, and the window in which
  the previous containers keep serving shows as an estimate.
- Rows drop `v<version>` when the platform numbers no releases. `--json`
  carries `null` versions and shas there, and `pending` gains `build_id`.

## [0.3.0] - 2026-10-08

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
