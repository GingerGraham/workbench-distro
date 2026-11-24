#!/usr/bin/env bash
# shell/distro/opensuse-leap.sh — workbench-distro (distro tier, ID opensuse-leap; core D126)
# Untested on a real host: the update path is exercised in a container only.

_opensuse_release_upgrade_usage() {
    printf '%s\n' \
        "Usage: opensuse-release-upgrade [--dry-run]" \
        "" \
        "Brings Leap up to date, installs opensuse-migration-tool and runs it." \
        "The tool lists the supported targets and you pick one. --dry-run is passed" \
        "to the tool, which then shows what it would do without changing anything."
}

opensuse-release-upgrade() {
    local dry_run="" arg elev
    for arg in "$@"; do
        case "${arg}" in
            --dry-run) dry_run="--dry-run" ;;
            -h|--help) _opensuse_release_upgrade_usage; return 0 ;;
            *) log_error "opensuse-release-upgrade: unknown option '${arg}'"; return 2 ;;
        esac
    done

    if _distro_in_container; then
        log_error "opensuse-release-upgrade: this is a container. Recreate it from a newer Leap image instead."
        return 1
    fi
    if ! _distro_have_tty; then
        log_error "opensuse-release-upgrade: needs a terminal, because the migration tool asks which release to go to."
        return 1
    fi
    elev="$(_distro_elev)" || return 1

    log_info "Step 1/3: bring this release fully up to date"
    # shellcheck disable=SC2086
    ${elev} zypper --non-interactive refresh || { log_error "zypper refresh failed. Nothing was changed."; return 1; }
    # shellcheck disable=SC2086
    ${elev} zypper --non-interactive update || { log_error "zypper update failed. Nothing was changed."; return 1; }
    # shellcheck disable=SC2119
    if distro-reboot-required >/dev/null 2>&1; then
        log_error "These updates need a reboot first: $(_distro_reboot_word), then run 'opensuse-release-upgrade' again."
        return 1
    fi

    log_info "Step 2/3: install opensuse-migration-tool"
    # shellcheck disable=SC2086
    ${elev} zypper --non-interactive install opensuse-migration-tool || return 1

    if [[ -z "${dry_run}" ]]; then
        if ! _distro_confirm_word "upgrade" "Start the openSUSE release migration?"; then
            log_info "Nothing was changed beyond the updates."
            return 0
        fi
    fi
    log_info "Step 3/3: run opensuse-migration-tool"
    # shellcheck disable=SC2086
    ${elev} opensuse-migration-tool ${dry_run}
}
