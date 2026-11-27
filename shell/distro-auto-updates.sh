#!/usr/bin/env bash
# shell/distro-auto-updates.sh — workbench-distro (tools tier)
# distro-auto-updates [status|off]: show, or turn off, the unattended updates
# that `wb tools install auto-updates` turned on (workbench-core D133).
# Installer files aren't loaded into the shell, so the paths and backend
# choice are repeated from shell/installers-auto-updates.sh, under the same
# names; tests/check-auto-updates.sh fails if they drift.
#
# Loaded by bash and zsh: no unquoted word splitting, no arrays, and no
# variable called status (read-only in zsh).

# ── Overridable for tests only (keep identical to the installer file) ─────────
_AUTO_UPDATES_DNF5_CONF="${_AUTO_UPDATES_DNF5_CONF:-/etc/dnf/automatic.conf}"
_AUTO_UPDATES_DNF4_CONF="${_AUTO_UPDATES_DNF4_CONF:-/etc/dnf/automatic-workbench.conf}"
_AUTO_UPDATES_DNF4_DROPIN="${_AUTO_UPDATES_DNF4_DROPIN:-/etc/systemd/system/dnf-automatic.service.d/50-workbench.conf}"
_AUTO_UPDATES_APT_CONF="${_AUTO_UPDATES_APT_CONF:-/etc/apt/apt.conf.d/52workbench-auto-updates}"
_AUTO_UPDATES_SUSE_CONF="${_AUTO_UPDATES_SUSE_CONF:-/etc/os-update.conf}"
_AUTO_UPDATES_MARKER="Written by workbench-distro (wb tools install auto-updates)."

_wb_alias_availability --needs "a supported Linux distribution (Fedora/RHEL, Debian/Ubuntu or SUSE family)" \
    _distro_supported distro-auto-updates

# ── Backend facts (same logic as the installer's _auto_updates_* versions) ────

_distro_au_dnf_is_5() {
    local dnf_path
    dnf_path="$(command -v dnf 2>/dev/null)" || return 1
    case "$(readlink -f "${dnf_path}" 2>/dev/null)" in
        */dnf5) return 0 ;;
    esac
    return 1
}

# dnf5, dnf4, apt or os-update; exit 1 when this host has none.
_distro_au_backend() {
    case "${WORKBENCH_DISTRO:-unknown}" in
        rhel)
            command -v dnf >/dev/null 2>&1 || return 1
            if _distro_au_dnf_is_5; then
                echo dnf5
            else
                echo dnf4
            fi
            ;;
        debian)
            case "${WORKBENCH_DISTRO_ID:-unknown}" in
                debian|ubuntu|pop) echo apt ;;
                *) return 1 ;;
            esac
            ;;
        suse) echo os-update ;;
        *) return 1 ;;
    esac
}

_distro_au_conf_path() {
    case "$1" in
        dnf5)      printf '%s\n' "${_AUTO_UPDATES_DNF5_CONF}" ;;
        dnf4)      printf '%s\n' "${_AUTO_UPDATES_DNF4_CONF}" ;;
        apt)       printf '%s\n' "${_AUTO_UPDATES_APT_CONF}" ;;
        os-update) printf '%s\n' "${_AUTO_UPDATES_SUSE_CONF}" ;;
    esac
}

_distro_au_is_ours() {
    [[ -f "$1" ]] && grep -qF "${_AUTO_UPDATES_MARKER}" "$1" 2>/dev/null
}

# _distro_au_recorded <file> <key>
_distro_au_recorded() {
    local file="$1" key="$2"
    _distro_au_is_ours "${file}" || return 0
    sed -n "s/^.*workbench-auto-updates:.* ${key}=\([^ ]*\).*\$/\1/p" "${file}" | head -n 1
}

# ── Facts only this file needs ────────────────────────────────────────────────

_distro_au_main_timer() {
    case "$1" in
        dnf5)      echo dnf5-automatic.timer ;;
        dnf4)      echo dnf-automatic.timer ;;
        apt)       echo apt-daily-upgrade.timer ;;
        os-update) echo os-update.timer ;;
    esac
}

# Every timer the backend uses, one per line.
_distro_au_timers() {
    case "$1" in
        dnf5)      printf '%s\n' dnf5-automatic.timer ;;
        dnf4)      printf '%s\n' dnf-automatic.timer ;;
        apt)       printf '%s\n' apt-daily.timer apt-daily-upgrade.timer ;;
        os-update) printf '%s\n' os-update.timer ;;
    esac
}

# The service name a unit's .timer starts: same name, .service.
_distro_au_service_of() {
    printf '%s\n' "${1%.timer}.service"
}

_distro_au_service_name() {
    case "$1" in
        dnf5)      echo dnf5-automatic ;;
        dnf4)      echo dnf-automatic ;;
        apt)       echo unattended-upgrades ;;
        os-update) echo os-update ;;
    esac
}

_distro_au_package() {
    case "$1" in
        dnf5)      echo dnf5-plugin-automatic ;;
        dnf4)      echo dnf-automatic ;;
        apt)       echo unattended-upgrades ;;
        os-update) echo os-update ;;
    esac
}

_distro_au_package_manager() {
    case "$1" in
        dnf5|dnf4) echo dnf ;;
        apt)       echo apt ;;
        os-update) echo zypper ;;
    esac
}

_distro_au_package_installed() {
    case "$1" in
        apt)
            # shellcheck disable=SC2016
            dpkg-query -W -f='${Status}' "$(_distro_au_package "$1")" 2>/dev/null | grep -q 'install ok installed'
            ;;
        *)
            rpm -q "$(_distro_au_package "$1")" >/dev/null 2>&1
            ;;
    esac
}

# _distro_au_timer_state <timer> — prints on, off or unknown. Reads systemctl's
# own words, because "disabled" and "systemctl failed" both exit non-zero.
_distro_au_timer_state() {
    local words
    words="$(systemctl is-enabled "$1" 2>/dev/null)"
    case "${words}" in
        enabled|enabled-runtime|static|alias|generated|indirect) echo on ;;
        disabled|masked|masked-runtime|linked|linked-runtime|not-found) echo off ;;
        *) echo unknown ;;
    esac
}

# _distro_au_value <empty-text> <value> — the value, or "unknown".
_distro_au_value() {
    case "$1" in
        ''|n/a|0) echo "unknown" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# _distro_au_apt_periodic — the effective APT::Periodic::Unattended-Upgrade,
# without its quotes; empty when apt-config can't say.
_distro_au_apt_periodic() {
    command -v apt-config >/dev/null 2>&1 || return 0
    apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null \
        | sed -n 's/^APT::Periodic::Unattended-Upgrade[[:space:]]*"\([^"]*\)".*$/\1/p' \
        | head -n 1
}

# Succeeds when apt would run unattended upgrades: any value but empty or 0.
_distro_au_apt_periodic_on() {
    local value
    value="$(_distro_au_apt_periodic)"
    case "${value}" in
        ''|0) return 1 ;;
    esac
    return 0
}

# ── Status ────────────────────────────────────────────────────────────────────

_distro_au_unsupported() {
    printf '%s\n' "unsupported: run 'wb tools install auto-updates' to see why"
}

_distro_au_status() {
    local backend conf package_text conf_text scope_text reboot_text
    local main_timer service timer_state state_text next_text last_text last_when last_result
    local ours="false" installed_text="not installed"

    backend="$(_distro_au_backend)" || { _distro_au_unsupported; return 2; }
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "distro-auto-updates: systemctl isn't on the PATH, so the timers can't be read"
        return 2
    fi

    conf="$(_distro_au_conf_path "${backend}")"
    main_timer="$(_distro_au_main_timer "${backend}")"
    service="$(_distro_au_service_of "${main_timer}")"

    _distro_au_package_installed "${backend}" && installed_text="installed"
    package_text="$(_distro_au_service_name "${backend}") ($(_distro_au_package "${backend}") ${installed_text})"

    timer_state="$(_distro_au_timer_state "${main_timer}")"
    if [[ "${timer_state}" == "unknown" ]]; then
        log_error "distro-auto-updates: couldn't read the state of ${main_timer}"
        return 2
    fi

    _distro_au_is_ours "${conf}" && ours="true"
    if [[ "${ours}" == "true" ]]; then
        conf_text="${conf}, written by workbench"
        scope_text="$(_distro_au_recorded "${conf}" scope)"
        reboot_text="$(_distro_au_recorded "${conf}" reboot)"
    elif [[ -e "${conf}" ]]; then
        conf_text="${conf}, written outside workbench"
    elif [[ "${backend}" == "apt" ]] && _distro_au_apt_periodic_on; then
        conf_text="distribution default (20auto-upgrades)"
    elif [[ "${backend}" == "dnf5" && "${timer_state}" == "on" ]]; then
        conf_text="none: downloads only (dnf5 automatic's default)"
    else
        conf_text="none"
    fi

    # on/off: apt also needs the periodic setting, whoever set it.
    state_text="${timer_state}"
    if [[ "${backend}" == "apt" && "${timer_state}" == "on" ]] && ! _distro_au_apt_periodic_on; then
        state_text="off"
    fi

    if [[ "${timer_state}" == "on" ]]; then
        next_text="$(_distro_au_value "$(systemctl show "${main_timer}" -p NextElapseUSecRealtime --value 2>/dev/null)")"
        next_text="${main_timer} enabled, next run ${next_text}"
    else
        next_text="${main_timer} disabled"
    fi

    last_when="$(systemctl show "${service}" -p ExecMainExitTimestamp --value 2>/dev/null)"
    last_result="$(systemctl show "${service}" -p Result --value 2>/dev/null)"
    case "${last_when}" in
        ''|n/a|0) last_text="not run yet" ;;
        *) last_text="${last_when}, $(_distro_au_value "${last_result}")" ;;
    esac

    printf '%-10s %s\n' "backend:" "${package_text}"
    printf '%-10s %s\n' "config:" "${conf_text}"
    if [[ "${ours}" == "true" ]]; then
        printf '%-10s %s\n' "scope:" "${scope_text:-unknown}"
        printf '%-10s %s\n' "reboot:" "${reboot_text:-unknown}"
    fi
    printf '%-10s %s\n' "timer:" "${next_text}"
    printf '%-10s %s\n' "last run:" "${last_text}"
    printf '%-10s %s\n' "state:" "${state_text}"

    [[ "${state_text}" == "on" ]] && return 0
    return 1
}

# ── Off ───────────────────────────────────────────────────────────────────────

_distro_au_off() {
    local backend conf elev enabled_timers timer_lines timer failed="false"
    local has_file="false" disabled_list="" left_list="" apt_default_still="false"
    local package manager

    backend="$(_distro_au_backend)" || { _distro_au_unsupported; return 2; }
    conf="$(_distro_au_conf_path "${backend}")"
    package="$(_distro_au_package "${backend}")"
    manager="$(_distro_au_package_manager "${backend}")"

    _distro_au_is_ours "${conf}" && has_file="true"
    if [[ "${backend}" == "dnf4" ]] && _distro_au_is_ours "${_AUTO_UPDATES_DNF4_DROPIN}"; then
        has_file="true"
    fi

    if [[ "${has_file}" != "true" ]]; then
        printf '%s\n' "workbench hasn't configured unattended updates here; nothing to undo."
        if [[ "${backend}" == "apt" ]] && _distro_au_apt_periodic_on; then
            printf '%s\n' "The distribution's own settings turn them on. To turn those off: sudo dpkg-reconfigure -plow unattended-upgrades"
        fi
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "distro-auto-updates: systemctl isn't on the PATH, so the timers can't be changed"
        return 1
    fi
    elev="$(_distro_elev)" || return 1

    enabled_timers="$(_distro_au_recorded "${conf}" enabled-timers)"
    timer_lines="$(printf '%s\n' "${enabled_timers}" | tr ',' '\n')"
    while IFS= read -r timer; do
        [[ -n "${timer}" && "${timer}" != "none" ]] || continue
        # shellcheck disable=SC2086
        if ${elev} systemctl disable --now "${timer}"; then
            disabled_list="${disabled_list:+${disabled_list}, }${timer}"
        else
            failed="true"
            log_error "distro-auto-updates: couldn't disable ${timer}; it is still enabled"
        fi
    done <<EOF
${timer_lines}
EOF

    # Only files that carry the marker.
    if _distro_au_is_ours "${conf}"; then
        # shellcheck disable=SC2086
        ${elev} rm -f "${conf}" || { failed="true"; log_error "distro-auto-updates: couldn't remove ${conf}"; }
    fi
    if [[ "${backend}" == "dnf4" ]] && _distro_au_is_ours "${_AUTO_UPDATES_DNF4_DROPIN}"; then
        # shellcheck disable=SC2086
        ${elev} rm -f "${_AUTO_UPDATES_DNF4_DROPIN}" \
            || { failed="true"; log_error "distro-auto-updates: couldn't remove ${_AUTO_UPDATES_DNF4_DROPIN}"; }
        # shellcheck disable=SC2086
        ${elev} systemctl daemon-reload || { failed="true"; log_error "distro-auto-updates: systemctl daemon-reload failed"; }
    fi

    # Timers of this backend that are still enabled: they were on before
    # workbench, so they keep running with the package's own settings.
    timer_lines="$(_distro_au_timers "${backend}")"
    while IFS= read -r timer; do
        [[ -n "${timer}" ]] || continue
        if [[ "$(_distro_au_timer_state "${timer}")" == "on" ]]; then
            left_list="${left_list:+${left_list}, }${timer}"
        fi
    done <<EOF
${timer_lines}
EOF

    if [[ "${backend}" == "apt" ]] && _distro_au_apt_periodic_on; then
        apt_default_still="true"
    fi

    if [[ -n "${disabled_list}" ]]; then
        printf '%s\n' "Disabled: ${disabled_list}"
    else
        printf '%s\n' "No timers were disabled: workbench hadn't enabled any."
    fi
    if [[ -n "${left_list}" ]]; then
        printf '%s\n' "Still enabled, because they were on before workbench: ${left_list}. They now run with the package's defaults."
    fi
    if [[ "${apt_default_still}" == "true" ]]; then
        printf '%s\n' "The distribution's own settings still turn on unattended upgrades (security updates on Ubuntu). To turn those off: sudo dpkg-reconfigure -plow unattended-upgrades"
    fi
    printf '%s\n' "The ${package} package is still installed; remove it with: sudo ${manager} remove ${package}"

    if [[ "${failed}" == "true" ]]; then
        log_error "distro-auto-updates: not everything could be undone; see the errors above."
        return 1
    fi
    return 0
}

distro-auto-updates() {
    case "${1:-status}" in
        status) _distro_au_status ;;
        off)    _distro_au_off ;;
        -h|--help)
            printf '%s\n' \
                "Usage: distro-auto-updates [status|off]" \
                "status (default): what runs unattended updates here, with what settings, and when." \
                "off: undo 'wb tools install auto-updates' (workbench's files and the timers it enabled)." \
                "Turn on or change: AUTO_UPDATES_SCOPE=security|all AUTO_UPDATES_REBOOT=never|when-needed wb tools install auto-updates"
            return 0
            ;;
        *) log_error "distro-auto-updates: unknown action '$1' (status, off)"; return 2 ;;
    esac
}
