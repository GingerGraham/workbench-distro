#!/usr/bin/env bash
# shell/distro.sh — workbench-distro (tools tier)
# Shared helpers and the cross-distro entry points. The per-distro commands
# these dispatch to live in shell/distro/*.sh (distro tier; family files
# and exact-ID files, workbench-core D126).

# ── Overridable for tests only ────────────────────────────────────────────────
_DISTRO_OS_RELEASE="${_DISTRO_OS_RELEASE:-/etc/os-release}"
_DISTRO_OSTREE_MARKER="${_DISTRO_OSTREE_MARKER:-/run/ostree-booted}"
_DISTRO_REBOOT_REQUIRED_FILE="${_DISTRO_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
_DISTRO_MODULES_DIR="${_DISTRO_MODULES_DIR:-/usr/lib/modules}"

# ── Helpers (private) ─────────────────────────────────────────────────────────

# _distro_os_release <KEY> — one os-release value, empty when absent.
_distro_os_release() {
    local key="$1"
    case "${key}" in ''|*[!A-Z_]*) return 2 ;; esac
    [[ -r "${_DISTRO_OS_RELEASE}" ]] || return 1
    # shellcheck disable=SC1090
    ( . "${_DISTRO_OS_RELEASE}" 2>/dev/null && eval "printf '%s\n' \"\${${key}:-}\"" )
}

# _distro_elev — prints the elevation prefix: nothing as root, else sudo/run0.
_distro_elev() {
    local elev
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi
    elev="$(get-elevation-command)" || return 1
    if [[ "${elev}" == "run0" ]]; then
        log_warn "Using run0: you may be asked for your password at every step (run0 doesn't cache credentials)."
    fi
    printf '%s\n' "${elev}"
}

_distro_is_ostree() {
    [[ -e "${_DISTRO_OSTREE_MARKER}" ]]
}

# WSL is checked first: systemd-detect-virt reports WSL itself as a
# container ("wsl"), which would wrongly block release upgrades there.
_distro_in_container() {
    [[ "${WORKBENCH_WSL:-false}" == "true" ]] && return 1
    [[ -e /run/.containerenv || -e /.dockerenv ]] && return 0
    command -v systemd-detect-virt >/dev/null 2>&1 \
        && systemd-detect-virt --container --quiet 2>/dev/null
}

_distro_systemd_running() {
    [[ -d /run/systemd/system ]]
}

_distro_have_tty() {
    { : </dev/tty; } 2>/dev/null
}

# _distro_confirm_word <word> <question> — 0 only when the user types <word>.
_distro_confirm_word() {
    local word="$1" question="$2" answer=""
    _distro_have_tty || return 1
    _read_prompt "${question} Type '${word}' to continue, anything else to stop: " answer
    [[ "${answer}" == "${word}" ]]
}

# _distro_reboot_word — how to "reboot" here, for messages.
_distro_reboot_word() {
    if [[ "${WORKBENCH_WSL:-false}" == "true" ]]; then
        printf "run 'wsl --terminate %s' from Windows and start the distro again" "${WSL_DISTRO_NAME:-<distro>}"
    else
        printf 'reboot'
    fi
}

_distro_supported() {
    [[ "${WORKBENCH_OS:-}" == "Linux" && "${WORKBENCH_DISTRO:-unknown}" != "unknown" ]]
}

_wb_alias_availability --needs "a supported Linux distribution (Fedora/RHEL, Debian/Ubuntu, Arch or SUSE family)" \
    _distro_supported distro-update distro-upgrade distro-reboot-required distro-info

# ── Commands ──────────────────────────────────────────────────────────────────

distro-update() {
    local skip_flatpak="false" arg updater=""
    for arg in "$@"; do
        case "${arg}" in
            --no-flatpak) skip_flatpak="true" ;;
            -h|--help)
                printf '%s\n' "Usage: distro-update [--no-flatpak]" \
                    "Updates this system's packages with its own package manager, then Flatpak apps."
                return 0
                ;;
            *) log_error "distro-update: unknown option '${arg}'"; return 2 ;;
        esac
    done

    case "${WORKBENCH_DISTRO:-unknown}" in
        rhel)   updater="dnf-update" ;;
        debian) updater="apt-update" ;;
        suse)   updater="zypper-update" ;;
        arch)   updater="pacman-update" ;;
    esac
    if [[ -z "${updater}" ]] || ! command -v "${updater}" >/dev/null 2>&1; then
        log_error "distro-update: no updater for this system (family '${WORKBENCH_DISTRO:-unknown}', ID '${WORKBENCH_DISTRO_ID:-unknown}')"
        return 1
    fi

    "${updater}" || return $?

    if [[ "${skip_flatpak}" != "true" ]] && command -v flatpak >/dev/null 2>&1; then
        log_info "distro-update: updating Flatpak apps"
        flatpak update -y --noninteractive || log_warn "distro-update: flatpak update failed (packages were updated)"
    fi

    # shellcheck disable=SC2119
    if distro-reboot-required >/dev/null 2>&1; then
        log_warn "distro-update: a reboot is recommended — $(_distro_reboot_word)"
    fi
    return 0
}

distro-upgrade() {
    local target_fn=""
    case "${WORKBENCH_DISTRO_ID:-unknown}" in
        fedora)        target_fn="fedora-release-upgrade" ;;
        debian)        target_fn="debian-release-upgrade" ;;
        ubuntu)        target_fn="ubuntu-release-upgrade" ;;
        pop)           target_fn="pop-release-upgrade" ;;
        opensuse-leap) target_fn="opensuse-release-upgrade" ;;
        arch|manjaro|endeavouros|garuda|opensuse-tumbleweed|opensuse-slowroll)
            log_info "distro-upgrade: ${WORKBENCH_DISTRO_ID} is a rolling release, so there's no release to upgrade to. 'distro-update' keeps it current."
            return 0
            ;;
        rhel|centos|rocky|almalinux|sles)
            log_error "distro-upgrade: major-version upgrades of ${WORKBENCH_DISTRO_ID} aren't handled by workbench. Follow the vendor's in-place upgrade documentation."
            return 1
            ;;
        *)
            log_error "distro-upgrade: release upgrades aren't supported on '${WORKBENCH_DISTRO_ID:-unknown}'."
            return 1
            ;;
    esac
    if ! command -v "${target_fn}" >/dev/null 2>&1; then
        log_error "distro-upgrade: ${target_fn} isn't loaded in this shell. Start a new shell, then try again."
        return 1
    fi
    "${target_fn}" "$@"
}

# ── distro-reboot-required ────────────────────────────────────────────────────
# Exit 0 = a reboot is recommended (prints "yes" and the reason), 1 = not
# (prints "no"), 2 = can't tell (prints why). Never elevates.
#
# Fedora doesn't create /var/run/reboot-required; that is a Debian and Ubuntu
# convention. On Fedora and the rest of the rhel family the answer comes from
# dnf needs-restarting instead.

# _distro_reboot_check_rhel
_distro_reboot_check_rhel() {
    local rc=0
    if ! command -v dnf >/dev/null 2>&1; then
        printf 'unknown: dnf is not installed\n'
        return 2
    fi
    if _distro_is_ostree; then
        printf "unknown: this is an rpm-ostree system; 'rpm-ostree status' shows a pending deployment\n"
        return 2
    fi
    # Run unprivileged: 'sudo dnf needs-restarting' is unreliable on DNF 5
    # (Fedora bug 2428601).
    if _distro_dnf_is_5; then
        dnf needs-restarting >/dev/null 2>&1 || rc=$?
    else
        dnf needs-restarting -r >/dev/null 2>&1 || rc=$?
    fi
    case "${rc}" in
        0) printf 'no\n'; return 1 ;;
        1) printf 'yes: dnf needs-restarting reports that a reboot is needed\n'; return 0 ;;
    esac
    if _distro_dnf_is_5; then
        printf "unknown: 'dnf needs-restarting' failed (exit %s); install the dnf5-plugins package\n" "${rc}"
    else
        printf "unknown: 'dnf needs-restarting -r' failed (exit %s); install the dnf-plugins-core package\n" "${rc}"
    fi
    return 2
}

# _distro_reboot_check_debian
_distro_reboot_check_debian() {
    local pkgs_file="${_DISTRO_REBOOT_REQUIRED_FILE}.pkgs"
    if [[ ! -e "${_DISTRO_REBOOT_REQUIRED_FILE}" ]]; then
        printf 'no\n'
        return 1
    fi
    printf 'yes: %s exists\n' "${_DISTRO_REBOOT_REQUIRED_FILE}"
    if [[ -r "${pkgs_file}" ]]; then
        printf 'packages that asked for it:\n'
        sed 's/^/  /' "${pkgs_file}"
    fi
    return 0
}

# _distro_reboot_check_arch — a replaced kernel removes the running kernel's
# module directory.
_distro_reboot_check_arch() {
    if [[ "${WORKBENCH_WSL:-false}" == "true" ]]; then
        printf 'no\n'
        return 1
    fi
    if [[ -d "${_DISTRO_MODULES_DIR}/$(uname -r)" ]]; then
        printf 'no\n'
        return 1
    fi
    printf 'yes: the running kernel (%s) has been replaced\n' "$(uname -r)"
    return 0
}

# _distro_reboot_check_suse
_distro_reboot_check_suse() {
    local rc=0
    if ! command -v zypper >/dev/null 2>&1; then
        printf 'unknown: zypper is not installed\n'
        return 2
    fi
    zypper needs-rebooting >/dev/null 2>&1 || rc=$?
    case "${rc}" in
        0)   printf 'no\n'; return 1 ;;
        102) printf "yes: 'zypper needs-rebooting' reports that a reboot is needed\n"; return 0 ;;
    esac
    printf "unknown: 'zypper needs-rebooting' exited %s\n" "${rc}"
    return 2
}

# distro-reboot-required takes no arguments but --help; it is also called
# bare from other commands.
# shellcheck disable=SC2120
distro-reboot-required() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            -h|--help)
                printf '%s\n' "Usage: distro-reboot-required" \
                    "Exit 0 when a reboot is recommended, 1 when not, 2 when it can't tell." \
                    "Prints yes, no, or why it can't tell."
                return 0
                ;;
            *) log_error "distro-reboot-required: unknown option '${arg}'"; return 2 ;;
        esac
    done
    if ! _distro_supported; then
        printf "unknown: not a supported Linux distribution\n"
        return 2
    fi
    case "${WORKBENCH_DISTRO}" in
        rhel)   _distro_reboot_check_rhel ;;
        debian) _distro_reboot_check_debian ;;
        arch)   _distro_reboot_check_arch ;;
        suse)   _distro_reboot_check_suse ;;
        *)      printf "unknown: no reboot check for family '%s'\n" "${WORKBENCH_DISTRO}"; return 2 ;;
    esac
}

# ── distro-info ───────────────────────────────────────────────────────────────
# What this module sees, for bug reports. No elevation, no network.

# _distro_yes_no <command...> — prints yes or no.
_distro_yes_no() {
    if "$@"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

distro-info() {
    local value wsl_name
    case "${1:-}" in
        '') ;;
        -h|--help)
            printf '%s\n' "Usage: distro-info" "Prints what workbench-distro detected about this system, for bug reports."
            return 0
            ;;
        *) log_error "distro-info: unknown option '$1'"; return 2 ;;
    esac

    printf 'family: %s\n' "${WORKBENCH_DISTRO:-unknown}"
    printf 'id: %s\n' "${WORKBENCH_DISTRO_ID:-unknown}"
    value="$(_distro_os_release VERSION_ID)"
    printf 'version_id: %s\n' "${value:-unset}"
    value="$(_distro_os_release VERSION_CODENAME)"
    if [[ -n "${value}" ]]; then
        printf 'version_codename: %s\n' "${value}"
    fi
    value="$(_distro_os_release VARIANT_ID)"
    if [[ -n "${value}" ]]; then
        printf 'variant_id: %s\n' "${value}"
    fi
    printf 'wsl: %s\n' "$([[ "${WORKBENCH_WSL:-false}" == "true" ]] && printf yes || printf no)"
    wsl_name="${WSL_DISTRO_NAME:-}"
    if [[ "${WORKBENCH_WSL:-false}" == "true" && -n "${wsl_name}" ]]; then
        printf 'wsl_distro_name: %s\n' "${wsl_name}"
    fi
    printf 'container: %s\n' "$(_distro_yes_no _distro_in_container)"
    printf 'rpm-ostree: %s\n' "$(_distro_yes_no _distro_is_ostree)"
    printf 'systemd running: %s\n' "$(_distro_yes_no _distro_systemd_running)"
    if [[ "${WORKBENCH_DISTRO:-unknown}" == "rhel" ]] && command -v _distro_dnf_is_5 >/dev/null 2>&1; then
        if _distro_dnf_is_5; then
            printf 'dnf: 5\n'
        elif command -v dnf >/dev/null 2>&1; then
            printf 'dnf: 4\n'
        else
            printf 'dnf: not installed\n'
        fi
    fi
    return 0
}
