#!/usr/bin/env bash
# shell/distro/rhel.sh — workbench-distro (distro tier, rhel family)
# Fedora, RHEL, Rocky, AlmaLinux, CentOS Stream and their relatives.

# _distro_dnf_is_5 — Fedora 41+ ships /usr/bin/dnf as a link to dnf5.
_distro_dnf_is_5() {
    local dnf_path
    dnf_path="$(command -v dnf 2>/dev/null)" || return 1
    case "$(readlink -f "${dnf_path}" 2>/dev/null)" in
        */dnf5) return 0 ;;
    esac
    command -v dnf5 >/dev/null 2>&1 && [[ "$(readlink -f "${dnf_path}")" == "$(readlink -f "$(command -v dnf5)")" ]]
}

_wb_declare_availability dnf dnf-update

dnf-update() {
    local assume="-y" clean="false" arg elev
    for arg in "$@"; do
        case "${arg}" in
            --ask)   assume="" ;;
            --clean) clean="true" ;;
            -h|--help)
                printf '%s\n' "Usage: dnf-update [--ask] [--clean]" \
                    "dnf upgrade --refresh, then dnf autoremove. --ask confirms each step; --clean also runs 'dnf clean packages'."
                return 0
                ;;
            *) log_error "dnf-update: unknown option '${arg}'"; return 2 ;;
        esac
    done
    if _distro_is_ostree; then
        log_error "dnf-update: this is an rpm-ostree system. Use 'rpm-ostree upgrade' instead."
        return 1
    fi
    elev="$(_distro_elev)" || return 1

    log_info "dnf-update: upgrading packages"
    # shellcheck disable=SC2086
    ${elev} dnf upgrade --refresh ${assume} || { log_error "dnf-update: upgrade failed; autoremove skipped"; return 1; }
    log_info "dnf-update: removing packages nothing needs any more"
    # shellcheck disable=SC2086
    ${elev} dnf autoremove ${assume} || return 1
    if [[ "${clean}" == "true" ]]; then
        # shellcheck disable=SC2086
        ${elev} dnf clean packages || return 1
    fi
    return 0
}
