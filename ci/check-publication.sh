#!/usr/bin/env bash
set -Eeuo pipefail

readonly artifact_dir="${ARTIFACT_DIR:?ARTIFACT_DIR must be set}"
readonly repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
readonly registry="${REGISTRY:-ghcr.io}"
readonly skopeo_command="${SKOPEO:-skopeo}"
readonly jq_command="${JQ:-jq}"
readonly platforms=(amd64 arm64)

publication_needed=false
inspection_output=""

is_missing_error() {
    local message="$1"
    [[ "${message}" == *"manifest unknown"* ||
        "${message}" == *"name unknown"* ]]
}

inspect_raw() {
    local reference="$1"
    local status=0
    if inspection_output="$("${skopeo_command}" inspect --raw \
        "docker://${reference}" 2>&1)"; then
        return
    else
        status=$?
    fi
    if is_missing_error "${inspection_output}"; then
        printf 'publication required: %s is absent\n' "${reference}" >&2
        publication_needed=true
        inspection_output=""
        return
    fi
    printf 'registry inspection failed for %s: %s\n' "${reference}" \
        "${inspection_output}" >&2
    return "${status}"
}

metadata_value() {
    local platform="$1"
    local key="$2"
    local metadata_path="${artifact_dir}/metadata-${platform}"
    if [[ ! -r "${metadata_path}" ]]; then
        printf 'missing publication metadata: %s\n' "${metadata_path}" >&2
        return 1
    fi
    awk -F= -v key="${key}" '$1 == key {
        print substr($0, index($0, "=") + 1)
        exit
    }' "${metadata_path}"
}

check_platform_labels() {
    local reference="$1"
    local image_name="$2"
    local platform="$3"
    local desired_key="$4"
    local -a override_args=(--override-os linux --override-arch "${platform}")
    local output
    local status=0

    if [[ "${platform}" == arm64 ]]; then
        override_args+=(--override-variant v8)
    fi
    if output="$("${skopeo_command}" inspect "${override_args[@]}" \
        --format '{{ index .Labels "org.opencontainers.image.content-key" }}' \
        "docker://${reference}" 2>&1)"; then
        :
    else
        status=$?
        if is_missing_error "${output}"; then
            printf 'publication required: %s platform %s is absent\n' \
                "${reference}" "${platform}" >&2
            publication_needed=true
            return
        fi
        printf 'registry inspection failed for %s platform %s: %s\n' \
            "${reference}" "${platform}" "${output}" >&2
        return "${status}"
    fi

    if [[ -z "${output}" || "${output}" == '<no value>' ]]; then
        printf 'publication required: %s platform %s has no content key\n' \
            "${reference}" "${platform}" >&2
        publication_needed=true
    elif [[ "${output}" != "${desired_key}" ]]; then
        printf 'publication required: %s platform %s content key differs\n' \
            "${reference}" "${platform}" >&2
        publication_needed=true
    fi
}

check_tag() {
    local image_name="$1"
    local tag="$2"
    local reference="${registry}/${repository}/${image_name}:${tag}"
    local raw_manifest
    local has_platform
    local desired_key

    if ! inspect_raw "${reference}"; then
        return 1
    fi
    raw_manifest="${inspection_output}"
    if [[ -z "${raw_manifest}" ]]; then
        return
    fi
    # shellcheck disable=SC2016
    if ! has_platform="$(printf '%s' "${raw_manifest}" | "${jq_command}" -r \
        --argjson platforms '["amd64", "arm64"]' '
        if (.manifests | type) == "array" then
            [ $platforms[] as $arch
              | any(.manifests[];
                    .platform.os == "linux" and
                    .platform.architecture == $arch) ]
            | all
        else
            false
        end')"; then
        printf 'registry returned an invalid manifest for %s\n' "${reference}" >&2
        return 1
    fi
    if [[ "${has_platform}" != true ]]; then
        printf 'publication required: %s is not a complete Linux multi-platform manifest\n' \
            "${reference}" >&2
        publication_needed=true
        return
    fi

    for platform in "${platforms[@]}"; do
        desired_key="$(metadata_value "${platform}" "${image_name}")"
        if [[ -z "${desired_key}" ]]; then
            printf 'empty desired content key for %s/%s\n' "${image_name}" \
                "${platform}" >&2
            return 1
        fi
        check_platform_labels "${reference}" "${image_name}" \
            "${platform}" "${desired_key}"
    done
}

check_tag nfcapd alpine
check_tag nfcapd latest
check_tag samba 24.04
check_tag samba latest

printf 'needed=%s\n' "${publication_needed}"
