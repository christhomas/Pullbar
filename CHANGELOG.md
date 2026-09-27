# Changelog

Notable changes to pullbar, newest first. Versions follow
[Semantic Versioning](https://semver.org/).

Each [GitHub release](https://github.com/lucaspal/Pullbar/releases) has the
full notes: the title, author, and description of every pull request merged
since the previous release. This file is the short summary.

When you cut a release, move the **Unreleased** entries under a new heading
for the version, for example `## [1.0.0] - 2026-10-01`, merge that change to
`main`, then tag the merge commit. `scripts/release-notes.sh <tag>` prints the
full notes if you want to check them first.

## Unreleased

### Added

- GitHub Actions workflow that builds and signature-checks the app on every
  push to `main` and every pull request, and publishes a GitHub release with
  the app zip when a `vX.Y.Z` tag is pushed on `main`.
- `make app VERSION=X.Y.Z` stamps the version into the app bundle.
- This changelog.
- MIT license ([#3](https://github.com/lucaspal/Pullbar/pull/3)).

### Changed

- Renamed the project from "PR Inbox" to "pullbar": package, bundle
  identifier, sources, Keychain item, and docs
  ([#1](https://github.com/lucaspal/Pullbar/pull/1),
  [#2](https://github.com/lucaspal/Pullbar/pull/2)).
