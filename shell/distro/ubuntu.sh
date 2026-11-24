#!/usr/bin/env bash
# shell/distro/ubuntu.sh — workbench-distro (distro tier, ID ubuntu; core D126)
# Relies on shell/distro.sh for the shared helpers and on debian.sh (the
# family file, listed first) for apt-update.

# Overridable for tests only.
_DISTRO_UBUNTU_RELEASE_UPGRADES="${_DISTRO_UBUNTU_RELEASE_UPGRADES:-/etc/update-manager/release-upgrades}"

_ubuntu_release_upgrade_usage() {
    printf '%s\n' \
        "Usage: ubuntu-release-upgrade [<version>]    e.g. ubuntu-release-upgrade 26.04" \
        "" \
        "Brings Ubuntu fully up to date, then runs do-release-upgrade interactively." \
        "Ubuntu can only upgrade to the release it offers; a <version> that isn't that" \
        "release is refused."
}

ubuntu-release-upgrade() {
    local want="" arg elev check_output offered prompt_mode
    for arg in "$@"; do
        case "${arg}" in
            -h|--help) _ubuntu_release_upgrade_usage; return 0 ;;
            -*)        log_error "ubuntu-release-upgrade: unknown option '${arg}'"; return 2 ;;
            *)
                if [[ -n "${want}" ]]; then
                    log_error "ubuntu-release-upgrade: give one version"
                    return 2
                fi
                want="${arg}"
                ;;
        esac
    done

    if _distro_in_container; then
        log_error "ubuntu-release-upgrade: this is a container. Recreate it from a newer Ubuntu image instead."
        return 1
    fi
    if ! _distro_have_tty; then
        log_error "ubuntu-release-upgrade: needs a terminal, because do-release-upgrade asks questions."
        return 1
    fi
    elev="$(_distro_elev)" || return 1

    log_info "Step 1/3: bring this release fully up to date"
    # shellcheck disable=SC2086
    ${elev} apt-get update || { log_error "apt-get update failed. Nothing was changed."; return 1; }
    # shellcheck disable=SC2086
    ${elev} apt-get full-upgrade -y || { log_error "apt-get full-upgrade failed. Nothing was changed."; return 1; }
    # shellcheck disable=SC2119
    if distro-reboot-required >/dev/null 2>&1; then
        log_error "These updates need a reboot first: $(_distro_reboot_word), then run 'ubuntu-release-upgrade' again."
        return 1
    fi

    if ! command -v do-release-upgrade >/dev/null 2>&1; then
        log_info "Installing update-manager-core, which provides do-release-upgrade"
        # shellcheck disable=SC2086
        ${elev} apt-get install -y update-manager-core || return 1
    fi

    log_info "Step 2/3: ask which release is offered"
    check_output="$(do-release-upgrade -c 2>&1)"
    offered="$(printf '%s\n' "${check_output}" | sed -n "s/.*New release '\\([^']*\\)' available.*/\\1/p" | head -n 1)"
    if [[ -z "${offered}" ]]; then
        prompt_mode=""
        if [[ -r "${_DISTRO_UBUNTU_RELEASE_UPGRADES}" ]]; then
            prompt_mode="$(sed -n 's/^[[:space:]]*Prompt[[:space:]]*=[[:space:]]*\([A-Za-z]*\).*/\1/p' "${_DISTRO_UBUNTU_RELEASE_UPGRADES}" | head -n 1)"
        fi
        log_info "No new release is offered."
        log_info "Prompt=${prompt_mode:-<not set>} in ${_DISTRO_UBUNTU_RELEASE_UPGRADES}. 'lts' only offers the next LTS, and only once its first point release is out; 'never' offers nothing."
        return 0
    fi
    if [[ -n "${want}" ]]; then
        case "${offered}" in
            "${want}"*) ;;
            *)
                log_error "ubuntu-release-upgrade: Ubuntu offers ${offered}, not ${want}. Ubuntu can only upgrade to the release it offers."
                return 1
                ;;
        esac
    fi

    log_info "Step 3/3: upgrade to Ubuntu ${offered}"
    if [[ "${WORKBENCH_WSL:-false}" == "true" ]]; then
        log_info "On WSL, if the upgrade ends by asking to reboot, $(_distro_reboot_word)."
    fi
    if ! _distro_confirm_word "upgrade" "Upgrade to Ubuntu ${offered}?"; then
        log_info "Nothing was changed."
        return 0
    fi
    # Interactive on purpose: dpkg asks about changed config files.
    # shellcheck disable=SC2086
    ${elev} do-release-upgrade
}
