#!/usr/bin/env bash
set -Eeuo pipefail

readonly artifact_dir="${ARTIFACT_DIR:?ARTIFACT_DIR must be set}"
readonly repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
readonly run_tag="${RUN_TAG:?RUN_TAG must be set}"
readonly registry="${REGISTRY:-ghcr.io}"
readonly engine_name="${ENGINE:-podman}"
readonly engine_command=("${engine_name}")
readonly platforms=(amd64 arm64)
readonly nfcapd_source=localhost/utility-containers/nfcapd:debian
readonly samba_source=localhost/utility-containers/samba:debian

load_platform_images() {
    local platform archive
    for platform in "${platforms[@]}"; do
        archive="${artifact_dir}/utility-nfcapd-${platform}.tar"
        if [[ ! -s "${archive}" ]]; then
            printf 'missing nfcapd image archive for %s\n' "${platform}" >&2
            exit 1
        fi
        "${engine_command[@]}" load --input "${archive}" >/dev/null
        "${engine_command[@]}" tag "${nfcapd_source}" \
            "localhost/utility-nfcapd:${platform}"

        archive="${artifact_dir}/utility-samba-${platform}.tar"
        if [[ ! -s "${archive}" ]]; then
            printf 'missing Samba image archive for %s\n' "${platform}" >&2
            exit 1
        fi
        "${engine_command[@]}" load --input "${archive}" >/dev/null
        "${engine_command[@]}" tag "${samba_source}" \
            "localhost/utility-samba:${platform}"
    done
}

push_staging_images() {
    local platform image staging
    for platform in "${platforms[@]}"; do
        image="localhost/utility-nfcapd:${platform}"
        staging="${registry}/${repository}/nfcapd:staging-${run_tag}-${platform}"
        "${engine_command[@]}" tag "${image}" "${staging}"
        "${engine_command[@]}" push "${staging}" "docker://${staging}"

        image="localhost/utility-samba:${platform}"
        staging="${registry}/${repository}/samba:staging-${run_tag}-${platform}"
        "${engine_command[@]}" tag "${image}" "${staging}"
        "${engine_command[@]}" push "${staging}" "docker://${staging}"
    done
}

push_manifests() {
    local name source versioned_tag tag
    name="$1"
    source="$2"
    versioned_tag="$3"
    "${engine_command[@]}" manifest create "${name}"
    for platform in "${platforms[@]}"; do
        "${engine_command[@]}" manifest add "${name}" \
            "localhost/${source}:${platform}"
    done
    for tag in "${versioned_tag}" latest; do
        "${engine_command[@]}" manifest push --all "${name}" \
            "docker://${registry}/${repository}/${source}:${tag}"
    done
}

load_platform_images
push_staging_images
push_manifests "localhost/utility-nfcapd-manifest:${run_tag}" nfcapd debian
push_manifests "localhost/utility-samba-manifest:${run_tag}" samba debian
