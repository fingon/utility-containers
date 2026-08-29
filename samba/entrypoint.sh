#!/usr/bin/env bash
set -Eeuo pipefail

readonly default_user=ubuntu
readonly default_uid=1000
readonly default_gid=1000
readonly max_numeric_id=2147483647

samba_user="${SAMBA_USER-${default_user}}"
samba_uid_input="${SAMBA_UID-${default_uid}}"
samba_gid_input="${SAMBA_GID-${default_gid}}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 64
}

validate_user() {
    if [[ ! "${samba_user}" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,30}\$?$ ]]; then
        fail "SAMBA_USER must be a valid Unix login name"
    fi
}

normalize_id() {
    local normalized="$1"
    while [[ "${normalized}" == 0* && "${normalized}" != 0 ]]; do
        normalized="${normalized#0}"
    done
    printf '%s' "${normalized}"
}

validate_id() {
    local setting_name="$1"
    local value="$2"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        fail "${setting_name} must be a positive numeric ID"
    fi

    local normalized
    normalized="$(normalize_id "${value}")"
    if [[ "${normalized}" == 0 ]]; then
        fail "${setting_name} must be a positive numeric ID"
    fi
    if [[ ${#normalized} -gt ${#max_numeric_id} ]] || {
        [[ ${#normalized} -eq ${#max_numeric_id} ]] &&
            ((normalized > max_numeric_id))
    }; then
        fail "${setting_name} is outside the supported numeric ID range"
    fi
    printf '%s' "${normalized}"
}

ensure_group() {
    local group_by_name=""
    if group_by_name="$(getent group "${samba_user}")"; then
        local existing_group_gid
        IFS=: read -r _ _ existing_group_gid _ <<<"${group_by_name}"
        if [[ "${existing_group_gid}" != "${samba_gid}" ]]; then
            fail "account conflict: group ${samba_user} has GID=${existing_group_gid}, requested GID=${samba_gid}"
        fi
    fi

    local group_by_id=""
    if group_by_id="$(getent group "${samba_gid}")"; then
        local group_name_by_id
        IFS=: read -r group_name_by_id _ _ _ <<<"${group_by_id}"
        if [[ "${group_name_by_id}" != "${samba_user}" ]]; then
            fail "account conflict: GID=${samba_gid} belongs to group ${group_name_by_id}"
        fi
        return
    fi

    if ! groupadd --gid "${samba_gid}" "${samba_user}"; then
        fail "could not create group ${samba_user} with GID=${samba_gid}"
    fi
}

ensure_user() {
    local user_by_name=""
    if user_by_name="$(getent passwd "${samba_user}")"; then
        local existing_user_uid
        local existing_user_gid
        IFS=: read -r _ _ existing_user_uid existing_user_gid _ <<<"${user_by_name}"
        if [[ "${existing_user_uid}" != "${samba_uid}" ||
            "${existing_user_gid}" != "${samba_gid}" ]]; then
            fail "account conflict: user ${samba_user} has UID=${existing_user_uid} GID=${existing_user_gid}, requested UID=${samba_uid} GID=${samba_gid}"
        fi
        return
    fi

    local user_by_id=""
    if user_by_id="$(getent passwd "${samba_uid}")"; then
        local user_name_by_id
        IFS=: read -r user_name_by_id _ _ _ _ <<<"${user_by_id}"
        fail "account conflict: UID=${samba_uid} belongs to user ${user_name_by_id}"
    fi

    if ! useradd \
        --uid "${samba_uid}" \
        --gid "${samba_gid}" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        "${samba_user}"; then
        fail "could not create user ${samba_user} with UID=${samba_uid} GID=${samba_gid}"
    fi
}

validate_user
samba_uid="$(validate_id SAMBA_UID "${samba_uid_input}")"
samba_gid="$(validate_id SAMBA_GID "${samba_gid_input}")"
ensure_group
ensure_user

exec /usr/sbin/smbd --no-process-group --foreground --debug-stdout
