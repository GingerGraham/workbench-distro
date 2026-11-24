#!/usr/bin/env bash
# shell/distro/arch.sh — workbench-distro (distro tier, arch family)
# Arch, Manjaro, EndeavourOS, Garuda and Omarchy.
#
# yay-update and paru-update update AUR packages the user installed
# themselves, so they don't check WORKBENCH_ALLOW_AUR (workbench-core D100
# governs installers that add AUR packages).

_wb_declare_availability pacman pacman-update
_wb_declare_availability yay yay-update
_wb_declare_availability paru paru-update

# _distro_omarchy_updater — prints Omarchy's update command, or nothing when
# this isn't an Omarchy system. Omarchy's manual says a plain pacman -Syu can
# skip the configuration migrations its own updater runs.
_distro_omarchy_updater() {
    if command -v omarchy-update >/dev/null 2>&1; then
        printf 'omarchy-update\n'
    elif command -v omarchy >/dev/null 2>&1; then
        printf 'omarchy update\n'
    fi
}

# _distro_defer_to_omarchy <calling command> — 0 when it handed over (and
# set _DISTRO_OMARCHY_RC), 1 when this isn't Omarchy.
_distro_defer_to_omarchy() {
    local updater
    updater="$(_distro_omarchy_updater)"
    [[ -n "${updater}" ]] || return 1
    log_info "$1: this is Omarchy, so handing over to '${updater}', which also runs Omarchy's configuration migrations."
    case "${updater}" in
        "omarchy update") omarchy update ;;
        *)                "${updater}" ;;
    esac
    _DISTRO_OMARCHY_RC=$?
    return 0
}

# _arch_parse_ask <command> <args...> — sets _ARCH_NOCONFIRM from --ask.
# Returns 0 to carry on, 2 for a bad option, 3 after printing --help.
_arch_parse_ask() {
    local command_name="$1" arg
    shift
    _ARCH_NOCONFIRM="--noconfirm"
    for arg in "$@"; do
        case "${arg}" in
            --ask) _ARCH_NOCONFIRM="" ;;
            -h|--help)
                printf '%s\n' "Usage: ${command_name} [--ask]" \
                    "Updates installed packages. --ask confirms the transaction instead of answering yes."
                return 3
                ;;
            *) log_error "${command_name}: unknown option '${arg}'"; return 2 ;;
        esac
    done
    return 0
}

pacman-update() {
    local rc elev
    _arch_parse_ask pacman-update "$@"
    rc=$?
    [[ "${rc}" -eq 3 ]] && return 0
    [[ "${rc}" -eq 0 ]] || return "${rc}"
    if _distro_defer_to_omarchy pacman-update; then
        return "${_DISTRO_OMARCHY_RC}"
    fi
    elev="$(_distro_elev)" || return 1

    log_info "pacman-update: upgrading packages"
    # shellcheck disable=SC2086
    ${elev} pacman -Syu ${_ARCH_NOCONFIRM} || { log_error "pacman-update: upgrade failed"; return 1; }
    if command -v paccache >/dev/null 2>&1; then
        log_info "pacman-update: trimming the package cache (paccache keeps three versions)"
        # shellcheck disable=SC2086
        ${elev} paccache -r || log_warn "pacman-update: paccache failed (packages were updated)"
    fi
    return 0
}

yay-update() {
    local rc
    _arch_parse_ask yay-update "$@"
    rc=$?
    [[ "${rc}" -eq 3 ]] && return 0
    [[ "${rc}" -eq 0 ]] || return "${rc}"
    if _distro_defer_to_omarchy yay-update; then
        return "${_DISTRO_OMARCHY_RC}"
    fi
    # yay elevates itself when it needs to.
    # shellcheck disable=SC2086
    yay -Syu ${_ARCH_NOCONFIRM}
}

paru-update() {
    local rc
    _arch_parse_ask paru-update "$@"
    rc=$?
    [[ "${rc}" -eq 3 ]] && return 0
    [[ "${rc}" -eq 0 ]] || return "${rc}"
    if _distro_defer_to_omarchy paru-update; then
        return "${_DISTRO_OMARCHY_RC}"
    fi
    # paru elevates itself when it needs to.
    # shellcheck disable=SC2086
    paru -Syu ${_ARCH_NOCONFIRM}
}
