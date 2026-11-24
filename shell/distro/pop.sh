#!/usr/bin/env bash
# shell/distro/pop.sh — workbench-distro (distro tier, ID pop; core D126)
# Relies on shell/distro.sh for the shared helpers.

_pop_release_upgrade_usage() {
    printf '%s\n' \
        "Usage: pop-release-upgrade" \
        "" \
        "Brings Pop!_OS fully up to date, refreshes the recovery partition, then" \
        "runs pop-upgrade. Pop!_OS offers one next release, so there is no target."
}

pop-release-upgrade() {
    local elev
    case "${1:-}" in
        '') ;;
        -h|--help) _pop_release_upgrade_usage; return 0 ;;
        *) log_error "pop-release-upgrade: unknown option '$1'"; return 2 ;;
    esac

    if _distro_in_container; then
        log_error "pop-release-upgrade: this is a container. Recreate it from a newer Pop!_OS image instead."
        return 1
    fi
    if ! _distro_have_tty; then
        log_error "pop-release-upgrade: needs a terminal, to confirm before the upgrade starts."
        return 1
    fi
    if ! command -v pop-upgrade >/dev/null 2>&1; then
        log_error "pop-release-upgrade: pop-upgrade isn't installed."
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
        log_error "These updates need a reboot first: $(_distro_reboot_word), then run 'pop-release-upgrade' again."
        return 1
    fi

    log_info "Step 2/3: refresh the recovery partition"
    if ! pop-upgrade recovery upgrade from-release; then
        log_warn "The recovery refresh failed. A host with no recovery partition fails here and can go on; a full or broken partition can't, so read the message above."
        if ! _distro_confirm_word "continue" "Continue without refreshing the recovery partition?"; then
            log_info "Nothing was changed."
            return 1
        fi
    fi

    log_info "Step 3/3: upgrade Pop!_OS"
    if ! _distro_confirm_word "upgrade" "Start the Pop!_OS release upgrade?"; then
        log_info "Nothing was changed."
        return 0
    fi
    pop-upgrade release upgrade
}
