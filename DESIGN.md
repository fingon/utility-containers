# Utility containers design

## Status

The repository tooling is implemented. The containers and their publishing
workflow are still under construction; the remaining work is tracked in
[TODO.md](TODO.md).

## Goals

This repository will provide small, reusable versions of the locally built
`nfcapd` and Samba containers in `example/`. The images will be published to
GHCR for Linux on both amd64 and arm64:

| Container | Image | Tags |
| --- | --- | --- |
| nfcapd | `ghcr.io/fingon/utility-containers/nfcapd` | `alpine`, `latest` |
| Samba | `ghcr.io/fingon/utility-containers/samba` | `24.04`, `latest` |

The versioned tag names identify the tracked distribution release. `latest`
will point to the same manifest as the corresponding versioned tag.

Host-specific paths, pyinfra orchestration, and credentials from the examples
are not part of the images. Each image will instead expose a stable container
interface suitable for Podman, Docker, Compose, and other OCI runtimes.

## Local development

The root `Makefile` provides `build`, `test`, `lint`, and `help` targets. It
uses Podman by default and builds both image contexts. The engine, image prefix,
and individual image names can be overridden on the command line, for example:

```console
make ENGINE=docker IMAGE_PREFIX=registry.example/utility-containers build
```

The integration targets pass the selected engine and image name to each test
script through `ENGINE` and `IMAGE` environment variables.

Install the repository hook with `prek install`. `make lint` runs the same
checks against all tracked files, including Markdown, YAML, shell scripts,
Containerfiles, and GitHub Actions workflows.

## nfcapd image

The nfcapd image tracks Alpine and installs the distribution's `nfdump` and
`shadow` packages. It preserves the behavior of `example/nfcapd.py`:

- `nfcapd` is the entrypoint;
- the default arguments are `-S 2 -w /flows/ -p 9995`;
- `/flows` contains persistent flow data; and
- port `9995/udp` receives NetFlow traffic; and
- `org.opencontainers.image.content-key` stores the build content key.

The image will be usable by a rootless container runtime. The caller is
responsible for creating a writable flow directory and mounting it at
`/flows`. Supplying container arguments will replace the defaults while
retaining the `nfcapd` entrypoint.

## Samba image

The Samba image tracks Ubuntu 24.04 and installs Samba from the distribution
repository. It exposes TCP ports 445 and 139 and uses `/share` for persistent
data.

The image's Samba configuration preserves the example's behavior:

- standalone server in the `WORKGROUP` workgroup;
- SMB2 as the minimum protocol;
- one browseable, writable share named `share` backed by `/share`;
- guest access and `Bad User` guest mapping;
- file and directory creation masks of `0700`;
- `smbd` in foreground mode with debug output written to standard output; and
- `org.opencontainers.image.content-key` stores the build content key.

The image will start as root because Samba must initialize its local account
and drop privileges for client sessions. Binding host ports below 1024 may also
require a rootful runtime or host-specific unprivileged-port configuration.

### Runtime account and credentials

The entrypoint ensures that the Unix account used by Samba matches these
settings. It creates the requested group and account when their IDs are
unclaimed, and reports an explicit conflict for existing unrelated users or
groups:

| Setting | Default | Meaning |
| --- | --- | --- |
| `SAMBA_USER` | `ubuntu` | Unix and Samba login name |
| `SAMBA_UID` | `1000` | Numeric owner ID for authenticated access |
| `SAMBA_GID` | `1000` | Numeric group ID for authenticated access |
| `SAMBA_PASSWORD_FILE` | unset | File containing the password |
| `SAMBA_PASSWORD` | unset | Password fallback when no file is configured |

`SAMBA_PASSWORD_FILE` takes precedence over `SAMBA_PASSWORD`. The entrypoint
fails before starting `smbd` if the configured file cannot be read, the password
is empty, either numeric ID is invalid, or the requested account conflicts with
an unrelated existing account. It updates the Samba password on every start so
credential rotation only requires recreating or restarting the container.

The password is passed to `smbpasswd` through standard input without being
written to an image layer or printed to logs. A runtime secret file is the
recommended input; the environment variable exists for simple deployments but
may be visible in container metadata.

The mounted `/share` must be accessible to the configured UID and GID. The
entrypoint will not recursively change ownership of existing data.

## Build and publication

### Triggers

Pull requests will build and test both images without publishing. Pushes to
`main` and manual workflow dispatches will build, test, and publish when the
result differs from GHCR. A daily scheduled run will poll for upstream changes.
Manual dispatch will include an option to disable publication.

The workflow will have read-only repository access except for the publishing
job, which also receives package write access. Concurrent runs for the same Git
reference will cancel older in-progress runs.

### Change detection

Change detection will be independent for each image and platform. A content key
will contain:

- the platform-specific digest of the base image;
- the resolved versions of packages installed from the distribution repository;
  and
- a hash of the image's local build inputs.

Including package versions is required because Alpine and Ubuntu package
repositories can change without a simultaneous base-image digest change. A
failure to resolve an input will fail the workflow rather than treating the
image as unchanged.

Each platform image will carry its content key in the
`org.opencontainers.image.content-key` OCI label. Before publishing, the
workflow will compare the desired keys with every platform image in the current
GHCR manifest. A confirmed missing image means publication is needed; other
registry inspection failures are errors.

Built images will be cached by content key. A cache hit may skip the build, but
never the integration test. The workflow will use native `ubuntu-24.04` amd64
and `ubuntu-24.04-arm` arm64 GitHub-hosted runners rather than emulation.

### Atomic multi-platform publication

Each architecture will be built and tested independently. After both tests
succeed, the publishing job will push run-specific staging tags and assemble a
multi-platform manifest. Only then will it update the distribution tag and
`latest`. A failed or incomplete platform build must not replace a public
manifest.

The workflow will skip all pushes when both published platform content keys
already match. GHCR authentication will use the workflow's short-lived
`GITHUB_TOKEN`; no persistent registry credential is required.

## Verification

Local Make targets and CI will use Podman by default while allowing the engine
and image names to be overridden.

The nfcapd integration test:

1. build the image and start it rootlessly with a temporary flow directory;
2. send a known NetFlow fixture to the published UDP port;
3. verify that `nfcapd` remains healthy and writes flow data below `/flows`; and
4. stop the container and remove all temporary resources.

The Samba integration tests will:

1. start the image with a temporary share and a password secret file;
2. authenticate with `smbclient`, then write and read a file;
3. verify the documented guest access behavior;
4. repeat authentication through the environment-variable fallback;
5. verify ownership produced by the default UID and GID;
6. verify that a missing or empty password fails with a useful error;
7. confirm that the password is absent from image history and logs; and
8. stop the container and remove all temporary resources.

Publishing is gated on linting, per-platform builds, and these integration
tests. Failures will retain concise container diagnostics as workflow artifacts
without including credential values.
