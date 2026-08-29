# Implementation backlog

The original behavior is implemented. The Debian stable migration described in
[DESIGN.md](DESIGN.md) remains to be implemented.

## Debian stable migration

- [x] Move both images to `debian:stable-slim`, install their packages with APT,
  and preserve the existing runtime interfaces and Samba account defaults.
- [ ] Update local builds, integration-test clients, content-key resolution, and
  CI image references from the Alpine and Ubuntu bases to Debian stable.
- [ ] Publish both images as `debian` and `latest`; stop updating
  `nfcapd:alpine` and `samba:24.04` without repointing those legacy tags.
- [ ] Build and integration-test the Debian images on native amd64 and arm64,
  including content-key changes across upstream base and package updates.
- [ ] Update README usage examples and published-tag documentation after the
  migrated images are implemented and verified.

## Repository tooling

- [x] Add a Makefile with discoverable build, test, lint, and help targets. Use
  Podman by default and allow engine and image overrides.
- [x] Configure prek for Markdown, YAML, shell, Containerfile, and GitHub Actions
  checks, and enable the repository hooks.
- [x] Add a brief README after the images are usable, including pull and run
  examples, volume permissions, Samba secret handling, and published tags.

## nfcapd

- [x] Add the Alpine-based image with the entrypoint, defaults, volume, UDP port,
  and OCI content-key label described in the design.
- [x] Add a small NetFlow fixture and a rootless integration test that verifies
  persistent output and cleanup.

## Samba

- [x] Add the Ubuntu 24.04 image, Samba configuration, and startup entrypoint.
- [x] Implement validated runtime account creation for `SAMBA_USER`, `SAMBA_UID`,
  and `SAMBA_GID`, including explicit conflict errors.
- [x] Implement password-file precedence, environment fallback, password rotation,
  and fail-fast handling without exposing credentials.
- [x] Add authenticated, guest, ownership, validation, shutdown, and secret-leak
  integration tests.

## Publishing

- [x] Add pull-request, main-branch, daily, and manual GitHub Actions triggers.
- [x] Resolve per-platform base digests and package versions, hash local inputs,
  and store the resulting content key as OCI metadata.
- [x] Cache images by content key while still testing every candidate image.
- [x] Build and test on native amd64 and arm64 runners, then publish run-specific
  staging tags and atomically update the multi-platform public tags.
- [x] Distinguish an absent GHCR image from registry failures when checking whether
  publication is required.
- [x] Upload sanitized diagnostics when an integration test fails.
