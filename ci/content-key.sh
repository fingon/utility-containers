#!/usr/bin/env bash
set -Eeuo pipefail

readonly image_name="${1:?image name is required}"
readonly target_arch="${2:?target architecture is required}"
readonly engine_name="${ENGINE:-podman}"
readonly engine_command=("${engine_name}")
readonly skopeo_command="${SKOPEO:-skopeo}"
readonly jq_command="${JQ:-jq}"

context=""
base_reference=""
package_manager=""
packages=()

case "${image_name}" in
nfcapd)
    context=nfcapd
    package_manager=apk
    packages=(nfdump shadow)
    ;;
samba)
    context=samba
    package_manager=apt
    packages=(samba)
    ;;
*)
    printf 'unsupported image name: %s\n' "${image_name}" >&2
    exit 64
    ;;
esac

base_reference="$(awk '$1 == "ARG" && $2 ~ /^BASE_IMAGE=/ {
    sub(/^BASE_IMAGE=/, "", $2)
    print $2
    exit
}' "${context}/Containerfile")"
if [[ -z "${base_reference}" ]]; then
    printf 'BASE_IMAGE is missing from %s/Containerfile\n' "${context}" >&2
    exit 1
fi

case "${base_reference}" in
*/*) registry_reference="${base_reference}" ;;
*) registry_reference="docker.io/library/${base_reference}" ;;
esac

raw_manifest="$("${skopeo_command}" inspect --raw \
    "docker://${registry_reference}")"
# shellcheck disable=SC2016
base_digest="$(printf '%s' "${raw_manifest}" | "${jq_command}" -er \
    --arg arch "${target_arch}" '
    if (.manifests | type) == "array" then
        [
            .manifests[]
            | select(.platform.os == "linux")
            | select(.platform.architecture == $arch)
            | select($arch != "arm64" or (.platform.variant // "v8") == "v8")
            | .digest
        ] | first // error("target platform is missing")
    else
        error("base image is not a multi-platform manifest")
    end')"
base_image="${registry_reference}@${base_digest}"

case "${package_manager}" in
apk)
    package_versions="$("${engine_command[@]}" run --rm \
        --platform "linux/${target_arch}" \
        --entrypoint /bin/sh "${base_image}" \
        -c '
                set -eu
                apk update >/dev/null
                apk add --no-cache "$@" >/dev/null
                apk info -v | sort
            ' sh "${packages[@]}")"
    ;;
apt)
    # shellcheck disable=SC2016
    package_versions="$("${engine_command[@]}" run --rm \
        --platform "linux/${target_arch}" \
        --entrypoint /bin/bash "${base_image}" \
        -c '
                set -eu -o pipefail
                export DEBIAN_FRONTEND=noninteractive
                apt-get update >/dev/null
                apt-get -s install --no-install-recommends --yes "$@" |
                    awk '\''$1 == "Inst" {
                        version = $3
                        sub(/^[[(]/, "", version)
                        sub(/[)]]$/, "", version)
                        print $2 "=" version
                    }'\'' |
                    sort
            ' bash "${packages[@]}")"
    ;;
*)
    printf 'unsupported package manager: %s\n' "${package_manager}" >&2
    exit 1
    ;;
esac
if [[ -z "${package_versions}" ]]; then
    printf 'no package versions resolved for %s\n' "${image_name}" >&2
    exit 1
fi

inputs_hash="$(
    while IFS= read -r -d '' input_path; do
        sha256sum "${input_path}"
    done < <(git ls-files -z -- "${context}") | sha256sum | awk '{print $1}'
)"
package_hash="$(printf '%s\n' "${package_versions}" | sha256sum | awk '{print $1}')"

printf 'base_image=%s\n' "${base_image}"
printf 'key=base-%s-packages-%s-inputs-%s\n' \
    "${base_digest#sha256:}" "${package_hash}" "${inputs_hash}"
