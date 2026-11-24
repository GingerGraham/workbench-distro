#!/usr/bin/env bash
# shell/distro/suse.sh — workbench-distro (distro tier, suse family)
# openSUSE Leap, Tumbleweed, Slowroll and SLES. Release upgrades are in
# opensuse-leap.sh.

_wb_declare_availability zypper zypper-update

zypper-update() {
    local interactive="--non-interactive" clean="false" arg elev verb="update"
    for arg in "$@"; do
        case "${arg}" in
            --ask)   interactive="" ;;
            --clean) clean="true" ;;
            -h|--help)
                printf '%s\n' "Usage: zypper-update [--ask] [--clean]" \
                    "zypper refresh, then 'zypper dup' on Tumbleweed and Slowroll or 'zypper update' on Leap." \
                    "--ask confirms each step; --clean also runs 'zypper clean -a'."
                return 0
                ;;
            *) log_error "zypper-update: unknown option '${arg}'"; return 2 ;;
        esac
    done
    case "${WORKBENCH_DISTRO_ID:-}" in
        opensuse-tumbleweed|opensuse-slowroll) verb="dup" ;;
    esac
    elev="$(_distro_elev)" || return 1

    log_info "zypper-update: refreshing repositories"
    # shellcheck disable=SC2086
    ${elev} zypper ${interactive} refresh || { log_error "zypper-update: refresh failed; nothing was upgraded"; return 1; }
    log_info "zypper-update: zypper ${verb}"
    # shellcheck disable=SC2086
    ${elev} zypper ${interactive} ${verb} || { log_error "zypper-update: ${verb} failed"; return 1; }
    if [[ "${clean}" == "true" ]]; then
        # shellcheck disable=SC2086
        ${elev} zypper clean -a || return 1
    fi
    return 0
}
