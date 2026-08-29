#!/usr/bin/env bash
set -Eeuo pipefail

readonly engine_name="${ENGINE:-podman}"
readonly image_name="${IMAGE:?IMAGE must be set}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
workspace_dir="$(cd -- "${script_dir}/.." && pwd)"
readonly workspace_dir
readonly fixture_path="${FIXTURE:-${script_dir}/testdata/netflow-v5.hex}"
readonly container_name="utility-nfcapd-test-$$"
readonly diagnostic_dir="${ITEST_DIAG_DIR:-}"
readonly netflow_port=9995
readonly container_udp_port="${netflow_port}/udp"
readonly flow_mount_path=/flows
readonly wait_attempts=40
readonly wait_interval_sec=0.25
readonly stop_timeout_sec=10

engine_command=("${engine_name}")
temp_dir=""
flow_dir=""
packet_path=""

write_diagnostics() {
    local diagnostic_path=""
    if [[ -z "${diagnostic_dir}" ]]; then
        return
    fi
    if ! mkdir -p "${diagnostic_dir}"; then
        printf 'failed to create diagnostics directory %s\n' \
            "${diagnostic_dir}" >&2
        return
    fi
    diagnostic_path="${diagnostic_dir}/nfcapd.log"
    if "${engine_command[@]}" inspect "${container_name}" \
        >/dev/null 2>&1; then
        if ! "${engine_command[@]}" logs "${container_name}" \
            >"${diagnostic_path}" 2>&1; then
            printf 'failed to capture nfcapd logs for %s\n' \
                "${container_name}" >&2
        fi
    else
        printf 'nfcapd container was not available for diagnostics\n' \
            >"${diagnostic_path}"
    fi
}

container_state() {
    "${engine_command[@]}" inspect --format '{{.State.Status}}' \
        "${container_name}" 2>/dev/null
}

flow_file() {
    find "${flow_dir}" -type f -size +0c -print -quit
}

cleanup() {
    local exit_status=$?
    trap - EXIT

    if ((exit_status != 0)); then
        write_diagnostics
        if "${engine_command[@]}" inspect "${container_name}" \
            >/dev/null 2>&1; then
            printf 'nfcapd container logs:\n' >&2
            "${engine_command[@]}" logs "${container_name}" >&2 || true
        fi
    fi

    if "${engine_command[@]}" inspect "${container_name}" \
        >/dev/null 2>&1; then
        if ! "${engine_command[@]}" rm --force "${container_name}" \
            >/dev/null 2>&1; then
            printf 'failed to remove container %s\n' "${container_name}" >&2
            exit_status=1
        fi
    fi

    if [[ -n "${temp_dir}" ]] && ! rm -rf "${temp_dir}"; then
        printf 'failed to remove temporary directory %s\n' "${temp_dir}" >&2
        exit_status=1
    fi
    if [[ -n "${temp_dir}" && -e "${temp_dir}" ]]; then
        printf 'temporary directory was not removed: %s\n' "${temp_dir}" >&2
        exit_status=1
    fi

    exit "${exit_status}"
}

if [[ "$(id -u)" == 0 ]]; then
    printf 'nfcapd integration test must run as a non-root user\n' >&2
    exit 64
fi

if [[ "${engine_command[0]##*/}" == podman ]]; then
    rootless="$("${engine_command[@]}" info --format '{{.Host.Security.Rootless}}')"
    if [[ "${rootless}" != true ]]; then
        printf 'Podman must use a rootless connection\n' >&2
        exit 64
    fi
fi

if [[ ! -r "${fixture_path}" ]]; then
    printf 'NetFlow fixture is not readable: %s\n' "${fixture_path}" >&2
    exit 1
fi
if ! command -v nc >/dev/null 2>&1; then
    printf 'nc is required to send the NetFlow fixture\n' >&2
    exit 64
fi
if ! command -v xxd >/dev/null 2>&1; then
    printf 'xxd is required to decode the NetFlow fixture\n' >&2
    exit 64
fi

temp_dir="$(mktemp -d "${workspace_dir}/.utility-nfcapd-test.XXXXXX")"
trap cleanup EXIT
flow_dir="${temp_dir}/flows"
packet_path="${temp_dir}/netflow-v5.packet"
mkdir "${flow_dir}"
xxd -r -p "${fixture_path}" "${packet_path}"

"${engine_command[@]}" run --detach \
    --name "${container_name}" \
    --publish "127.0.0.1::${container_udp_port}" \
    --volume "${flow_dir}:${flow_mount_path}" \
    "${image_name}" >/dev/null

state=""
for _ in $(seq "${wait_attempts}"); do
    state="$(container_state || true)"
    if [[ "${state}" == running ]]; then
        break
    fi
    sleep "${wait_interval_sec}"
done
if [[ "${state}" != running ]]; then
    printf 'nfcapd container did not remain running (state: %s)\n' \
        "${state:-unknown}" >&2
    exit 1
fi

mapped_port="$("${engine_command[@]}" port "${container_name}" \
    "${container_udp_port}")"
host_port="${mapped_port##*:}"
if ! [[ "${host_port}" =~ ^[0-9]+$ ]]; then
    printf 'could not determine mapped UDP port from %s\n' "${mapped_port}" >&2
    exit 1
fi

nc -u -w 1 127.0.0.1 "${host_port}" <"${packet_path}"

flow_path=""
for _ in $(seq "${wait_attempts}"); do
    state="$(container_state || true)"
    flow_path="$(flow_file)"
    if [[ "${state}" == running && -n "${flow_path}" ]]; then
        break
    fi
    sleep "${wait_interval_sec}"
done
if [[ "${state}" != running ]]; then
    printf 'nfcapd stopped after receiving the fixture (state: %s)\n' \
        "${state:-unknown}" >&2
    exit 1
fi
if [[ -z "${flow_path}" ]]; then
    printf 'nfcapd did not write flow data below %s\n' "${flow_mount_path}" >&2
    exit 1
fi

"${engine_command[@]}" stop --time "${stop_timeout_sec}" \
    "${container_name}" >/dev/null
if [[ "$(container_state || true)" == running ]]; then
    printf 'nfcapd container did not stop cleanly\n' >&2
    exit 1
fi
flow_path="$(flow_file)"
if [[ -z "${flow_path}" ]]; then
    printf 'flow output did not persist after container shutdown: %s\n' \
        "${flow_mount_path}" >&2
    exit 1
fi

printf 'nfcapd integration passed: %s\n' "${flow_path}"
