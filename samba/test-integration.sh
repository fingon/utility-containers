#!/usr/bin/env bash
set -Eeuo pipefail

readonly engine_name="${ENGINE:-podman}"
readonly image_name="${IMAGE:?IMAGE must be set}"
readonly client_image="${CLIENT_IMAGE:-debian:stable-slim}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
workspace_dir="$(cd -- "${script_dir}/.." && pwd)"
readonly workspace_dir
readonly file_server_name="utility-samba-test-file-$$"
readonly file_client_name="utility-samba-test-file-client-$$"
readonly env_server_name="utility-samba-test-env-$$"
readonly env_client_name="utility-samba-test-env-client-$$"
readonly diagnostic_dir="${ITEST_DIAG_DIR:-}"
readonly file_password_value=file-password
readonly environment_password_value=environment-password
readonly wait_attempts=40
readonly wait_interval_sec=0.25
readonly stop_timeout_sec=5

engine_command=("${engine_name}")
temp_dir=""

sanitize_log() {
    local log="$1"
    local secret
    for secret in "${file_password_value}" "${environment_password_value}"; do
        log="${log//"${secret}"/<redacted>}"
    done
    printf '%s' "${log}"
}

write_diagnostics() {
    local name
    local logs
    local diagnostic_path
    local diagnostics_available=false
    if [[ -n "${diagnostic_dir}" ]]; then
        if mkdir -p "${diagnostic_dir}"; then
            diagnostics_available=true
        else
            printf 'failed to create diagnostics directory %s\n' \
                "${diagnostic_dir}" >&2
        fi
    fi
    for name in "${file_server_name}" "${env_server_name}"; do
        diagnostic_path="${diagnostic_dir}/${name}.log"
        if "${engine_command[@]}" inspect "${name}" >/dev/null 2>&1; then
            logs="$("${engine_command[@]}" logs "${name}" 2>&1 || true)"
            logs="$(sanitize_log "${logs}")"
            printf '%s container logs:\n%s\n' "${name}" "${logs}" >&2
            if [[ "${diagnostics_available}" == true ]]; then
                printf '%s\n' "${logs}" >"${diagnostic_path}"
            fi
        elif [[ "${diagnostics_available}" == true ]]; then
            printf '%s container was not available for diagnostics\n' \
                "${name}" >"${diagnostic_path}"
        fi
    done
}

container_state() {
    "${engine_command[@]}" inspect --format '{{.State.Status}}' "$1" 2>/dev/null
}

cleanup_container() {
    local name="$1"
    if "${engine_command[@]}" inspect "${name}" >/dev/null 2>&1; then
        "${engine_command[@]}" rm --force "${name}" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    local exit_status=$?
    trap - EXIT

    if ((exit_status != 0)); then
        write_diagnostics
    fi

    cleanup_container "${file_client_name}"
    cleanup_container "${file_server_name}"
    cleanup_container "${env_client_name}"
    cleanup_container "${env_server_name}"

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

wait_for_running() {
    local name="$1"
    local state=""
    for _ in $(seq "${wait_attempts}"); do
        state="$(container_state "${name}" || true)"
        if [[ "${state}" == running ]]; then
            return
        fi
        sleep "${wait_interval_sec}"
    done
    printf 'container %s did not start (state: %s)\n' "${name}" \
        "${state:-unknown}" >&2
    return 1
}

start_client() {
    local client_name="$1"
    local server_name="$2"
    local credentials_file="$3"
    "${engine_command[@]}" run --detach \
        --name "${client_name}" \
        --network "container:${server_name}" \
        --volume "${credentials_file}:/run/secrets/credentials:ro" \
        "${client_image}" sleep infinity >/dev/null
    "${engine_command[@]}" exec "${client_name}" bash -c \
        'apt-get update >/dev/null && apt-get install --no-install-recommends --yes smbclient >/dev/null && rm -rf /var/lib/apt/lists/*'
}

authenticated_client() {
    local client_name="$1"
    shift
    "${engine_command[@]}" exec "${client_name}" smbclient \
        //127.0.0.1/share \
        -A /run/secrets/credentials \
        -m SMB3 \
        "$@"
}

guest_client() {
    local client_name="$1"
    shift
    "${engine_command[@]}" exec "${client_name}" smbclient \
        //127.0.0.1/share \
        -N \
        -m SMB3 \
        "$@"
}

wait_for_authenticated_share() {
    local client_name="$1"
    for _ in $(seq "${wait_attempts}"); do
        if authenticated_client "${client_name}" -c 'ls' >/dev/null 2>&1; then
            return
        fi
        sleep "${wait_interval_sec}"
    done
    printf 'authenticated SMB connection did not become ready\n' >&2
    return 1
}

stop_container() {
    local name="$1"
    "${engine_command[@]}" stop --time "${stop_timeout_sec}" "${name}" >/dev/null
    local state
    state="$(container_state "${name}" || true)"
    if [[ "${state}" == running ]]; then
        printf 'container %s did not stop (state: %s)\n' "${name}" "${state}" >&2
        return 1
    fi
}

expect_failure() {
    local description="$1"
    shift
    local output_path
    output_path="$(mktemp "${temp_dir}/failure.XXXXXX")"
    local status=0
    "$@" >"${output_path}" 2>&1 || status=$?
    if [[ "${status}" -eq 0 ]]; then
        printf '%s unexpectedly succeeded\n' "${description}" >&2
        sed -n '1,40p' "${output_path}" >&2
        unlink "${output_path}"
        return 1
    fi
    if rg -q "${file_password_value}|${environment_password_value}" \
        "${output_path}"; then
        printf '%s exposed a credential\n' "${description}" >&2
        sed -n '1,40p' "${output_path}" >&2
        unlink "${output_path}"
        return 1
    fi
    printf '%s failed without credential output\n' "${description}"
    unlink "${output_path}"
}

if [[ "$(id -u)" == 0 ]]; then
    printf 'Samba integration test must run as a non-root user\n' >&2
    exit 64
fi
if [[ "${engine_command[0]##*/}" == podman ]]; then
    rootless="$("${engine_command[@]}" info --format '{{.Host.Security.Rootless}}')"
    if [[ "${rootless}" != true ]]; then
        printf 'Podman must use a rootless connection\n' >&2
        exit 64
    fi
fi

temp_dir="$(mktemp -d "${workspace_dir}/.utility-samba-test.XXXXXX")"
trap cleanup EXIT
file_share_dir="${temp_dir}/file-share"
file_password_path="${temp_dir}/${file_password_value}"
file_credentials="${temp_dir}/file-credentials"
mkdir "${file_share_dir}"
chmod 0777 "${file_share_dir}"
printf 'guest-visible\n' >"${file_share_dir}/guest-source.txt"
chmod 0644 "${file_share_dir}/guest-source.txt"
printf '%s\n' "${file_password_value}" >"${file_password_path}"
printf 'username = ubuntu\npassword = %s\ndomain = WORKGROUP\n' \
    "${file_password_value}" \
    >"${file_credentials}"
chmod 0600 "${file_credentials}"

"${engine_command[@]}" run --detach \
    --name "${file_server_name}" \
    --volume "${file_share_dir}:/share" \
    --env SAMBA_PASSWORD_FILE=/run/secrets/password \
    --volume "${file_password_path}:/run/secrets/password:ro" \
    "${image_name}" >/dev/null
wait_for_running "${file_server_name}"
start_client "${file_client_name}" "${file_server_name}" "${file_credentials}"
wait_for_authenticated_share "${file_client_name}"

"${engine_command[@]}" exec "${file_client_name}" sh -c \
    'printf "authenticated-content\\n" >/tmp/authenticated-input'
authenticated_client "${file_client_name}" \
    -c 'put /tmp/authenticated-input authenticated.txt'
authenticated_client "${file_client_name}" \
    -c 'get authenticated.txt /tmp/authenticated-output'
"${engine_command[@]}" exec "${file_client_name}" cmp -s \
    /tmp/authenticated-input /tmp/authenticated-output
guest_client "${file_client_name}" -c 'ls guest-source.txt'
guest_client "${file_client_name}" -c 'get guest-source.txt /tmp/guest-output'
"${engine_command[@]}" exec "${file_client_name}" sh -c \
    'printf "guest-visible\\n" >/tmp/guest-expected'
"${engine_command[@]}" exec "${file_client_name}" cmp -s \
    /tmp/guest-expected /tmp/guest-output

file_owner="$("${engine_command[@]}" exec "${file_server_name}" \
    stat -c '%u:%g' /share/authenticated.txt)"
if [[ "${file_owner}" != 1000:1000 ]]; then
    printf 'authenticated file owner is %s, expected 1000:1000\n' \
        "${file_owner}" >&2
    exit 1
fi
file_mode="$("${engine_command[@]}" exec "${file_server_name}" \
    stat -c '%a' /share/authenticated.txt)"
if [[ "${file_mode}" != 700 ]]; then
    printf 'authenticated file mode is %s, expected 700\n' "${file_mode}" >&2
    exit 1
fi

file_server_logs="$("${engine_command[@]}" logs "${file_server_name}")"
if [[ "${file_server_logs}" == *"${file_password_value}"* ]]; then
    printf 'file password appeared in Samba logs\n' >&2
    exit 1
fi
image_history="$("${engine_command[@]}" history --no-trunc "${image_name}")"
if [[ "${image_history}" == *"${file_password_value}"* ||
    "${image_history}" == *"${environment_password_value}"* ]]; then
    printf 'a password appeared in image history\n' >&2
    exit 1
fi
stop_container "${file_server_name}"
if [[ ! -f "${file_share_dir}/authenticated.txt" ]]; then
    printf 'authenticated output disappeared during shutdown\n' >&2
    exit 1
fi
cleanup_container "${file_client_name}"
cleanup_container "${file_server_name}"

env_share_dir="${temp_dir}/env-share"
env_credentials="${temp_dir}/env-credentials"
mkdir "${env_share_dir}"
chmod 0777 "${env_share_dir}"
printf 'username = ubuntu\npassword = %s\ndomain = WORKGROUP\n' \
    "${environment_password_value}" \
    >"${env_credentials}"
chmod 0600 "${env_credentials}"
"${engine_command[@]}" run --detach \
    --name "${env_server_name}" \
    --volume "${env_share_dir}:/share" \
    --env "SAMBA_PASSWORD=${environment_password_value}" \
    "${image_name}" >/dev/null
wait_for_running "${env_server_name}"
start_client "${env_client_name}" "${env_server_name}" "${env_credentials}"
wait_for_authenticated_share "${env_client_name}"
authenticated_client "${env_client_name}" \
    -c 'mkdir environment-directory'
environment_owner="$("${engine_command[@]}" exec "${env_server_name}" \
    stat -c '%u:%g' /share/environment-directory)"
if [[ "${environment_owner}" != 1000:1000 ]]; then
    printf 'environment-authenticated owner is %s, expected 1000:1000\n' \
        "${environment_owner}" >&2
    exit 1
fi
stop_container "${env_server_name}"
cleanup_container "${env_client_name}"
cleanup_container "${env_server_name}"

empty_file="${temp_dir}/empty-password"
: >"${empty_file}"
expect_failure invalid_user "${engine_command[@]}" run --rm \
    --env SAMBA_USER=bad/name \
    --env "SAMBA_PASSWORD=${file_password_value}" \
    "${image_name}"
expect_failure invalid_uid "${engine_command[@]}" run --rm \
    --env SAMBA_UID=not-a-number \
    --env "SAMBA_PASSWORD=${file_password_value}" \
    "${image_name}"
expect_failure missing_password_file "${engine_command[@]}" run --rm \
    --env "SAMBA_PASSWORD=${environment_password_value}" \
    --env SAMBA_PASSWORD_FILE=/run/secrets/missing \
    "${image_name}"
expect_failure empty_password_file "${engine_command[@]}" run --rm \
    --env "SAMBA_PASSWORD=${environment_password_value}" \
    --env SAMBA_PASSWORD_FILE=/run/secrets/password \
    --volume "${empty_file}:/run/secrets/password:ro" \
    "${image_name}"
expect_failure empty_environment_password "${engine_command[@]}" run --rm \
    --env SAMBA_PASSWORD= \
    "${image_name}"

printf 'Samba integration passed: authentication, guest access, ownership, validation, shutdown, and secret handling\n'
