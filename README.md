# Utility containers

Small OCI images for NetFlow collection and a standalone Samba share. They are
published for Linux on amd64 and arm64.

## nfcapd

The Alpine image listens for NetFlow v5/v7/v9 on UDP port `9995` and stores
the result below `/flows`.

```console
podman pull ghcr.io/fingon/utility-containers/nfcapd:alpine
mkdir -p flows
podman run --detach --name nfcapd \
  --publish 9995:9995/udp \
  --volume "$PWD/flows:/flows" \
  ghcr.io/fingon/utility-containers/nfcapd:alpine
```

The bind-mounted flow directory must be writable by the container. Rootless
Podman normally maps the container's root user to the invoking host user, so a
directory created by that user is sufficient.

## Samba

The Ubuntu 24.04 image publishes the `share` share on TCP ports `445` and
`139`.

```console
podman pull ghcr.io/fingon/utility-containers/samba:24.04
mkdir -p share
printf '%s\n' 'change-this-password' > samba-password
chmod 600 samba-password
podman run --detach --name samba \
  --publish 445:445 --publish 139:139 \
  --volume "$PWD/share:/share" \
  --volume "$PWD/samba-password:/run/secrets/samba-password:ro" \
  --env SAMBA_PASSWORD_FILE=/run/secrets/samba-password \
  ghcr.io/fingon/utility-containers/samba:24.04
```

The default authenticated account is `ubuntu` with UID and GID `1000`. The
`/share` bind mount must be accessible to the configured `SAMBA_UID` and
`SAMBA_GID`; the entrypoint does not recursively change ownership of existing
data. `SAMBA_PASSWORD_FILE` takes precedence over `SAMBA_PASSWORD`, and the
password is rotated when the container starts. A mounted secret file is safer
than the environment fallback, which may be visible in container metadata.

## Published tags

| Image | Versioned tag | Moving tag |
| --- | --- | --- |
| `ghcr.io/fingon/utility-containers/nfcapd` | `alpine` | `latest` |
| `ghcr.io/fingon/utility-containers/samba` | `24.04` | `latest` |
