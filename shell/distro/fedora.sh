#!/usr/bin/env bash
# shell/distro/fedora.sh — workbench-distro (distro tier, ID fedora; core D126)
# Relies on rhel.sh (the family file, listed before this one) for
# _distro_dnf_is_5, and on shell/distro.sh for the shared helpers.

# ── Overridable for tests only ────────────────────────────────────────────────
_FEDORA_UPGRADE_STATE_FILE="${_FEDORA_UPGRADE_STATE_FILE:-}"

_fedora_upgrade_state_file() {
    if [[ -n "${_FEDORA_UPGRADE_STATE_FILE}" ]]; then
        printf '%s\n' "${_FEDORA_UPGRADE_STATE_FILE}"
        return 0
    fi
    printf '%s/workbench-distro/fedora-upgrade\n' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

_fedora_upgrade_record() {
    local file
    file="$(_fedora_upgrade_state_file)"
    mkdir -p "$(dirname "${file}")" || return 1
    printf 'FROM=%s\nTO=%s\n' "$1" "$2" > "${file}"
}

# _fedora_offline_verb — the dnf command that stages, cleans and logs an
# offline upgrade. Fedora's upgrade guide uses "dnf offline" on DNF 5;
# DNF 4 only has "dnf system-upgrade". The download step is
# "system-upgrade download" on both.
_fedora_offline_verb() {
    if _distro_dnf_is_5; then
        printf 'offline\n'
    else
        printf 'system-upgrade\n'
    fi
}

_fedora_release_upgrade_usage() {
    printf '%s\n' \
        "Usage: fedora-release-upgrade <release>        e.g. fedora-release-upgrade 45" \
        "       fedora-release-upgrade --post [--from <release>]" \
        "" \
        "Upgrades Fedora by one or two releases with 'dnf system-upgrade'." \
        "Run --post after the upgrade to review config files and remove retired packages."
}

fedora-release-upgrade() {
    local target="" post="false" from=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    _fedora_release_upgrade_usage; return 0 ;;
            --post)       post="true"; shift ;;
            --from)       [[ $# -ge 2 ]] || { log_error "fedora-release-upgrade: --from needs a release number"; return 2; }
                          from="$2"; shift 2 ;;
            -v|--version) [[ $# -ge 2 ]] || { log_error "fedora-release-upgrade: $1 needs a release number"; return 2; }
                          target="$2"; shift 2 ;;
            -*)           log_error "fedora-release-upgrade: unknown option '$1'"; return 2 ;;
            *)            target="$1"; shift ;;
        esac
    done
    if [[ "${post}" == "true" ]]; then
        _fedora_release_upgrade_post "${from}"
        return $?
    fi
    _fedora_release_upgrade_run "${target}"
}

_fedora_release_upgrade_run() {
    local target="$1" current elev dnf5="false" verb

    current="$(rpm -E %fedora 2>/dev/null)"
    case "${current}" in
        ''|*[!0-9]*) log_error "fedora-release-upgrade: couldn't read the current Fedora release (rpm -E %fedora)"; return 1 ;;
    esac
    case "${target}" in
        ''|*[!0-9]*)
            log_error "fedora-release-upgrade: give the release to upgrade to, e.g. 'fedora-release-upgrade $((current + 1))'"
            return 2
            ;;
    esac
    if (( target <= current )); then
        log_error "fedora-release-upgrade: this system is already on Fedora ${current}. Downgrades aren't supported."
        return 2
    fi
    if (( target > current + 2 )); then
        log_error "fedora-release-upgrade: Fedora supports upgrading at most two releases at a time (${current} → $((current + 2)))."
        return 2
    fi
    if _distro_is_ostree; then
        log_error "fedora-release-upgrade: this is a Fedora Atomic (rpm-ostree) system. Use 'rpm-ostree rebase' as your variant's documentation describes."
        return 1
    fi
    if _distro_in_container; then
        log_error "fedora-release-upgrade: this is a container. Recreate it from a Fedora ${target} image instead."
        return 1
    fi
    if ! _distro_have_tty; then
        log_error "fedora-release-upgrade: needs a terminal, to confirm before the upgrade is applied."
        return 1
    fi
    _distro_dnf_is_5 && dnf5="true"
    verb="$(_fedora_offline_verb)"
    if [[ "${WORKBENCH_WSL:-false}" == "true" ]]; then
        if [[ "${dnf5}" != "true" ]]; then
            log_error "fedora-release-upgrade: on WSL this needs DNF 5 (Fedora 41 or later)."
            return 1
        fi
        if ! _distro_systemd_running; then
            log_error "fedora-release-upgrade: on WSL the upgrade runs as a systemd service, and systemd isn't running here. Add '[boot]' and 'systemd=true' to /etc/wsl.conf, run 'wsl --terminate ${WSL_DISTRO_NAME:-<distro>}' from Windows, start the distro again and re-run this."
            return 1
        fi
    fi
    elev="$(_distro_elev)" || return 1

    log_info "fedora-release-upgrade: Fedora ${current} → ${target}"

    log_info "Step 1/4: bring Fedora ${current} fully up to date"
    # shellcheck disable=SC2086
    ${elev} dnf upgrade --refresh -y || { log_error "Update failed. Nothing else was changed."; return 1; }

    # shellcheck disable=SC2119
    if distro-reboot-required >/dev/null 2>&1; then
        log_error "These updates need a reboot first: $(_distro_reboot_word), then run 'fedora-release-upgrade ${target}' again."
        return 1
    fi

    if [[ "${dnf5}" == "true" ]]; then
        log_info "Step 2/4: system-upgrade is built into DNF 5, nothing to install"
    else
        log_info "Step 2/4: install the DNF 4 system-upgrade plugin"
        # shellcheck disable=SC2086
        ${elev} dnf install -y dnf-plugin-system-upgrade || return 1
    fi

    log_info "Step 3/4: download Fedora ${target} packages (the running system isn't changed)"
    # shellcheck disable=SC2086
    if ! ${elev} dnf system-upgrade download --releasever="${target}" -y; then
        log_error "Download failed. The running system wasn't changed. Delete what was downloaded with: ${elev:+${elev} }dnf ${verb} clean"
        return 1
    fi
    _fedora_upgrade_record "${current}" "${target}" \
        || log_warn "Couldn't record the upgrade; after it, run: fedora-release-upgrade --post --from ${current}"

    log_info "Step 4/4: apply the upgrade"
    if [[ "${WORKBENCH_WSL:-false}" == "true" ]]; then
        _fedora_release_upgrade_wsl "${current}" "${target}" "${elev}" "${verb}"
        return $?
    fi

    log_warn "The machine reboots now, installs Fedora ${target} (often 20–60 minutes), then reboots again. Save your work first."
    if ! _distro_confirm_word "reboot" "Reboot into the upgrade now?"; then
        log_info "Left ready. Reboot into it later with: ${elev:+${elev} }dnf ${verb} reboot"
        log_info "Or cancel and delete the download with: ${elev:+${elev} }dnf ${verb} clean"
        return 0
    fi
    # shellcheck disable=SC2086
    ${elev} dnf ${verb} reboot
}

# _fedora_release_upgrade_wsl <current> <target> <elev> <verb>
#
# WSL doesn't restart when the offline transaction is staged. The upgrade
# runs as the dnf5-offline-transaction service the next time the distro
# starts, and WSL stops an idle distro about 15 seconds after the last
# session closes (a running systemd job doesn't count). An unattended start
# is therefore interrupted part-way. A journal-following session from
# Windows keeps the distro alive. "dnf distro-sync --releasever=N" isn't a
# supported way to upgrade and failed in testing, so it isn't offered.
_fedora_release_upgrade_wsl() {
    local current="$1" target="$2" elev="$3" verb="$4" name="${WSL_DISTRO_NAME:-<distro>}"

    log_info "On WSL the upgrade can't run by rebooting. It is staged now and runs the next time this distro starts."
    log_info "WSL stops an idle distro about 15 seconds after the last session closes, which would interrupt the upgrade part-way."
    log_info "A window following the journal from Windows keeps it alive until the upgrade finishes."
    log_warn "Back up before staging. The download is kept, so you can stop here, back up, then re-run 'fedora-release-upgrade ${target}'."
    log_warn "Backing up after staging would put the staged upgrade into the backup, and a restore would start it again."
    printf '%s\n' \
        "From PowerShell on Windows:" \
        "  wsl --terminate ${name}" \
        "  wsl --export ${name} C:\\wsl\\${name}-fedora-${current}.tar"

    if ! _distro_confirm_word "stage" "Stage the upgrade now?"; then
        log_info "Not staged. Delete the download with: ${elev:+${elev} }dnf ${verb} clean"
        return 0
    fi
    # shellcheck disable=SC2086
    ${elev} dnf ${verb} reboot || return 1

    printf '%s\n' \
        "Staged. From PowerShell on Windows:" \
        "  1. wsl --terminate ${name}" \
        "  2. wsl -d ${name} -u root -- journalctl -f -o cat -u dnf5-offline-transaction" \
        "Keep window 2 open and don't let Windows sleep. It returns when the upgrade" \
        "finishes and the distro restarts itself. If the next start times out, run" \
        "'wsl --terminate ${name}' and start it again. Then, inside the distro:" \
        "  fedora-release-upgrade --post"
    return 0
}

# _fedora_release_upgrade_post <from>
_fedora_release_upgrade_post() {
    local from="$1" to="" key value state_file elev verb current_now versions_count
    local duplicates extras

    state_file="$(_fedora_upgrade_state_file)"
    if [[ -z "${from}" || -r "${state_file}" ]]; then
        if [[ -r "${state_file}" ]]; then
            # Parsed, never sourced: the file is only ever FROM= and TO= lines.
            while IFS='=' read -r key value; do
                case "${key}" in
                    FROM) [[ -n "${from}" ]] || from="${value}" ;;
                    TO)   to="${value}" ;;
                esac
            done < "${state_file}"
        fi
    fi
    case "${from}" in
        ''|*[!0-9]*)
            log_error "fedora-release-upgrade --post: no record of the earlier release. Run: fedora-release-upgrade --post --from <release you upgraded from>"
            return 2
            ;;
    esac
    case "${to}" in
        *[!0-9]*) to="" ;;
    esac
    if _distro_is_ostree; then
        log_error "fedora-release-upgrade --post: this is a Fedora Atomic (rpm-ostree) system."
        return 1
    fi
    verb="$(_fedora_offline_verb)"

    current_now="$(rpm -E %fedora 2>/dev/null)"
    if [[ -n "${to}" && "${current_now}" != "${to}" ]]; then
        log_error "This system is on Fedora ${current_now}, not ${to}: the upgrade didn't apply. See why with: dnf ${verb} log --number=-1"
        return 1
    fi

    versions_count="$(rpm -q fedora-release-common 2>/dev/null | grep -c '^fedora-release-common' || true)"
    case "${versions_count}" in
        ''|0|1) ;;
        *)
            log_error "More than one fedora-release-common version is installed. That is the signature of an interrupted upgrade."
            log_error "Restore your backup, or run 'fedora-release-upgrade <release>' again."
            return 1
            ;;
    esac

    elev="$(_distro_elev)" || return 1
    log_info "Post-upgrade 1/5: install rpmconf and remove-retired-packages"
    # shellcheck disable=SC2086
    ${elev} dnf install -y rpmconf remove-retired-packages || return 1

    log_info "Post-upgrade 2/5: review changed config files (rpmconf, interactive)"
    # shellcheck disable=SC2086
    ${elev} rpmconf -a || log_warn "rpmconf didn't finish cleanly; run '${elev:+${elev} }rpmconf -a' again later"

    log_info "Post-upgrade 3/5: remove packages Fedora has retired since release ${from}"
    # Fedora's upgrade guide runs this unprivileged and passes the old
    # release, which is right after skipping a release and harmless after one.
    remove-retired-packages "${from}" || log_warn "remove-retired-packages failed; try '${elev:+${elev} }remove-retired-packages ${from}'"

    log_info "Post-upgrade 4/5: report duplicates and packages no repository provides"
    duplicates="$(dnf repoquery --duplicates 2>/dev/null)"
    if [[ -n "${duplicates}" ]]; then
        log_warn "Packages installed in more than one version:"
        printf '%s\n' "${duplicates}"
        if _distro_dnf_is_5; then
            log_info "DNF 5 can't remove duplicates for you ('dnf remove --duplicates' isn't supported there). Remove the older version of each by name."
        else
            log_info "To remove the older versions: ${elev:+${elev} }dnf remove --duplicates"
        fi
    fi
    extras="$(dnf repoquery --extras --exclude='kernel,kernel-*,kmod-*' 2>/dev/null)"
    if [[ -n "${extras}" ]]; then
        log_warn "Packages installed that no enabled repository provides (not removed; check each):"
        printf '%s\n' "${extras}"
    fi

    log_info "Post-upgrade 5/5: remove packages nothing needs any more (interactive)"
    # shellcheck disable=SC2086
    ${elev} dnf autoremove || log_warn "autoremove didn't finish; run it again later"

    rm -f "${state_file}"
    log_info "Fedora ${current_now:-${to}} post-upgrade steps done"
    return 0
}
