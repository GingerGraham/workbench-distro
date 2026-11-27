#!/usr/bin/env bash
# shell/installers-auto-updates.sh — workbench-distro
# install-auto-updates / installed-auto-updates (workbench-core D133).
#
# Turns on the distribution's own unattended-update service (dnf5 automatic,
# dnf-automatic, unattended-upgrades, os-update) and writes its settings to a
# file workbench creates and marks. A file of the same name that workbench
# didn't write is never changed (D110).
#
# `wb tools` sources this file on its own, in bash, so it can't use helpers
# from shell/distro*.sh or shell/installers.sh and keeps small copies. The
# _AUTO_UPDATES_* paths are repeated, under the same names, in
# shell/distro-auto-updates.sh; tests/check-auto-updates.sh fails if they
# drift.
#
# Settings (D102): AUTO_UPDATES_SCOPE=security|all,
# AUTO_UPDATES_REBOOT=never|when-needed. Unset means "keep what's recorded",
# then the default.

# ── Overridable for tests only ────────────────────────────────────────────────
_AUTO_UPDATES_DNF5_CONF="${_AUTO_UPDATES_DNF5_CONF:-/etc/dnf/automatic.conf}"
_AUTO_UPDATES_DNF4_CONF="${_AUTO_UPDATES_DNF4_CONF:-/etc/dnf/automatic-workbench.conf}"
_AUTO_UPDATES_DNF4_DROPIN="${_AUTO_UPDATES_DNF4_DROPIN:-/etc/systemd/system/dnf-automatic.service.d/50-workbench.conf}"
_AUTO_UPDATES_DNF4_PACKAGED_CONF="${_AUTO_UPDATES_DNF4_PACKAGED_CONF:-/etc/dnf/automatic.conf}"
_AUTO_UPDATES_APT_CONF="${_AUTO_UPDATES_APT_CONF:-/etc/apt/apt.conf.d/52workbench-auto-updates}"
_AUTO_UPDATES_SUSE_CONF="${_AUTO_UPDATES_SUSE_CONF:-/etc/os-update.conf}"
_AUTO_UPDATES_OSTREE_MARKER="${_AUTO_UPDATES_OSTREE_MARKER:-/run/ostree-booted}"
_AUTO_UPDATES_SYSTEMD_DIR="${_AUTO_UPDATES_SYSTEMD_DIR:-/run/systemd/system}"
_AUTO_UPDATES_CONTAINER_MARKERS="${_AUTO_UPDATES_CONTAINER_MARKERS:-/run/.containerenv /.dockerenv}"

_AUTO_UPDATES_MARKER="Written by workbench-distro (wb tools install auto-updates)."
# Pop!_OS's own release repository origin. Verify on the Pop!_OS host:
#   apt-cache policy | grep -o 'o=[^,]*' | sort -u
_AUTO_UPDATES_POP_ORIGIN="${_AUTO_UPDATES_POP_ORIGIN:-pop-os-release}"

# ── Small copies of module helpers ────────────────────────────────────────────

_auto_updates_elev() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi
    get-elevation-command
}

_auto_updates_dnf_is_5() {
    local dnf_path
    dnf_path="$(command -v dnf 2>/dev/null)" || return 1
    case "$(readlink -f "${dnf_path}" 2>/dev/null)" in
        */dnf5) return 0 ;;
    esac
    return 1
}

# WSL first: systemd-detect-virt reports WSL itself as a container.
_auto_updates_in_container() {
    local marker
    [[ "${WORKBENCH_WSL:-false}" == "true" ]] && return 1
    for marker in ${_AUTO_UPDATES_CONTAINER_MARKERS}; do
        [[ -e "${marker}" ]] && return 0
    done
    command -v systemd-detect-virt >/dev/null 2>&1 \
        && systemd-detect-virt --container --quiet 2>/dev/null
}

# ── Backend facts ─────────────────────────────────────────────────────────────

# _auto_updates_backend — dnf5, dnf4, apt or os-update. Silent; exit 1 when
# this host has none (the reason comes from _auto_updates_check_host).
_auto_updates_backend() {
    case "${WORKBENCH_DISTRO:-unknown}" in
        rhel)
            command -v dnf >/dev/null 2>&1 || return 1
            if _auto_updates_dnf_is_5; then
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

_auto_updates_conf_path() {
    case "$1" in
        dnf5)      printf '%s\n' "${_AUTO_UPDATES_DNF5_CONF}" ;;
        dnf4)      printf '%s\n' "${_AUTO_UPDATES_DNF4_CONF}" ;;
        apt)       printf '%s\n' "${_AUTO_UPDATES_APT_CONF}" ;;
        os-update) printf '%s\n' "${_AUTO_UPDATES_SUSE_CONF}" ;;
    esac
}

_auto_updates_package() {
    case "$1" in
        dnf5)      echo dnf5-plugin-automatic ;;
        dnf4)      echo dnf-automatic ;;
        apt)       echo unattended-upgrades ;;
        os-update) echo os-update ;;
    esac
}

# Space-separated; bash-only splitting is fine here (installer files run in bash).
_auto_updates_timers() {
    case "$1" in
        dnf5)      echo "dnf5-automatic.timer" ;;
        dnf4)      echo "dnf-automatic.timer" ;;
        apt)       echo "apt-daily.timer apt-daily-upgrade.timer" ;;
        os-update) echo "os-update.timer" ;;
    esac
}

_auto_updates_is_ours() {
    [[ -f "$1" ]] && grep -qF "${_AUTO_UPDATES_MARKER}" "$1" 2>/dev/null
}

# _auto_updates_recorded <file> <key> — a value from the state line of a file
# workbench wrote; empty when there's no such file or key.
_auto_updates_recorded() {
    local file="$1" key="$2"
    _auto_updates_is_ours "${file}" || return 0
    sed -n "s/^.*workbench-auto-updates:.* ${key}=\([^ ]*\).*\$/\1/p" "${file}" | head -n 1
}

# ── Checks ────────────────────────────────────────────────────────────────────

_auto_updates_check_host() {
    if [[ "${WORKBENCH_OS:-}" != "Linux" ]]; then
        log_error "auto-updates: only for Linux"
        return 1
    fi
    if [[ -e "${_AUTO_UPDATES_OSTREE_MARKER}" ]]; then
        log_error "auto-updates: this is an rpm-ostree system, which stages updates itself: set AutomaticUpdatePolicy=stage in /etc/rpm-ostreed.conf and enable rpm-ostreed-automatic.timer, or use your software centre's automatic updates."
        return 1
    fi
    if _auto_updates_in_container; then
        log_error "auto-updates: this is a container. Recreate it from a newer image instead."
        return 1
    fi
    case "${WORKBENCH_DISTRO:-unknown}" in
        arch)
            log_error "auto-updates: Arch doesn't support unattended upgrades: some updates need manual steps announced on archlinux.org/news. Run 'distro-update' yourself (on Omarchy it runs Omarchy's updater)."
            return 1
            ;;
        debian)
            case "${WORKBENCH_DISTRO_ID:-unknown}" in
                debian|ubuntu|pop) ;;
                linuxmint)
                    log_error "auto-updates: Linux Mint's Update Manager has its own automatic updates; turn them on in its preferences."
                    return 1
                    ;;
                *)
                    log_error "auto-updates: '${WORKBENCH_DISTRO_ID:-unknown}' isn't handled: workbench doesn't know its archive origins."
                    return 1
                    ;;
            esac
            ;;
        rhel)
            if ! command -v dnf >/dev/null 2>&1; then
                log_error "auto-updates: dnf isn't installed"
                return 1
            fi
            ;;
        suse) ;;
        *)
            log_error "auto-updates: not a supported distribution (family '${WORKBENCH_DISTRO:-unknown}')"
            return 1
            ;;
    esac
    if [[ ! -d "${_AUTO_UPDATES_SYSTEMD_DIR}" ]]; then
        if [[ "${WORKBENCH_WSL:-false}" == "true" ]]; then
            log_error "auto-updates: runs from a systemd timer, and systemd isn't running here. Add '[boot]' and 'systemd=true' to /etc/wsl.conf, run 'wsl --terminate ${WSL_DISTRO_NAME:-<distro>}' from Windows, start the distro again and re-run this."
        else
            log_error "auto-updates: runs from a systemd timer, and systemd isn't running here."
        fi
        return 1
    fi
    return 0
}

# _auto_updates_validate <scope> <reboot>
_auto_updates_validate() {
    local scope="$1" reboot="$2"
    case "${scope}" in
        security|all) ;;
        *) log_error "auto-updates: AUTO_UPDATES_SCOPE must be security or all (got '${scope}')"; return 1 ;;
    esac
    case "${reboot}" in
        never|when-needed) ;;
        *) log_error "auto-updates: AUTO_UPDATES_REBOOT must be never or when-needed (got '${reboot}')"; return 1 ;;
    esac
    if [[ "${reboot}" == "when-needed" && "${WORKBENCH_WSL:-false}" == "true" ]]; then
        log_error "auto-updates: AUTO_UPDATES_REBOOT=when-needed isn't for WSL: a reboot inside WSL stops the distro, and Windows owns the kernel. Use never; distro-update says when a restart is due."
        return 1
    fi
    if [[ "${scope}" == "security" ]]; then
        case "${WORKBENCH_DISTRO_ID:-unknown}" in
            opensuse-tumbleweed|opensuse-slowroll)
                log_error "auto-updates: ${WORKBENCH_DISTRO_ID} ships fixes as new snapshots, not security patches. Use AUTO_UPDATES_SCOPE=all."
                return 1
                ;;
            centos)
                log_error "auto-updates: CentOS Stream publishes no security advisories, so security-only would install nothing. Use AUTO_UPDATES_SCOPE=all."
                return 1
                ;;
        esac
    fi
    return 0
}

# _auto_updates_check_dnf4_reboot <strict>
# dnf-automatic gained its 'reboot' option in DNF 4.15, and a distribution may
# backport it. The packaged config mentions the option when it's supported.
# Before the package is installed there's no config to read: that's fine
# (strict=false), and the check runs again once it's there (strict=true).
_auto_updates_check_dnf4_reboot() {
    local strict="$1"
    if [[ ! -e "${_AUTO_UPDATES_DNF4_PACKAGED_CONF}" && "${strict}" != "true" ]]; then
        return 0
    fi
    if ! grep -Eq '^[#[:space:]]*reboot[[:space:]]*=' "${_AUTO_UPDATES_DNF4_PACKAGED_CONF}" 2>/dev/null; then
        log_error "auto-updates: this dnf-automatic is too old to reboot by itself (its config has no 'reboot' option). Use AUTO_UPDATES_REBOOT=never."
        return 1
    fi
    return 0
}

# ── Rendering ─────────────────────────────────────────────────────────────────

# _auto_updates_header <comment-prefix> <scope> <reboot> <enabled-timers>
_auto_updates_header() {
    printf '%s\n' \
        "$1 ${_AUTO_UPDATES_MARKER}" \
        "$1 workbench-auto-updates: scope=$2 reboot=$3 enabled-timers=$4" \
        "$1 Change with: AUTO_UPDATES_SCOPE=<security|all> AUTO_UPDATES_REBOOT=<never|when-needed> wb tools upgrade auto-updates" \
        "$1 Turn off with: distro-auto-updates off"
}

# _auto_updates_render_dnf <backend> <scope> <reboot> <enabled-timers>
_auto_updates_render_dnf() {
    local backend="$1" scope="$2" reboot="$3" timers="$4" upgrade_type="default"
    [[ "${scope}" == "security" ]] && upgrade_type="security"
    _auto_updates_header "#" "${scope}" "${reboot}" "${timers}"
    printf '%s\n' \
        "[commands]" \
        "upgrade_type = ${upgrade_type}" \
        "download_updates = True" \
        "apply_updates = True"
    # DNF 4 before the 'reboot' option warns on unknown keys, so it's only
    # written there when it's needed (and _check_dnf4_reboot has checked support).
    if [[ "${backend}" == "dnf5" || "${reboot}" == "when-needed" ]]; then
        printf 'reboot = %s\n' "${reboot}"
    fi
    printf '%s\n' "" "[emitters]" "emit_via = stdio"
}

_auto_updates_render_dnf4_dropin() {
    printf '%s\n' \
        "# ${_AUTO_UPDATES_MARKER}" \
        "# Runs dnf-automatic with workbench's settings, leaving the package's" \
        "# ${_AUTO_UPDATES_DNF4_PACKAGED_CONF} untouched." \
        "[Service]" \
        "ExecStart=" \
        "ExecStart=/usr/bin/dnf-automatic ${_AUTO_UPDATES_DNF4_CONF} --timer"
}

# _auto_updates_apt_origins <id> <scope> — Origins-Pattern entries.
# ${distro_codename} is unattended-upgrades' own substitution: keep it literal.
# shellcheck disable=SC2016
_auto_updates_apt_origins() {
    local id="$1" scope="$2"
    case "${id}" in
        debian)
            printf '%s\n' \
                '    "origin=Debian,codename=${distro_codename},label=Debian-Security";' \
                '    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
            if [[ "${scope}" == "all" ]]; then
                printf '%s\n' \
                    '    "origin=Debian,codename=${distro_codename},label=Debian";' \
                    '    "origin=Debian,codename=${distro_codename}-updates";'
            fi
            ;;
        ubuntu|pop)
            printf '%s\n' \
                '    "origin=Ubuntu,archive=${distro_codename}-security";' \
                '    "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";' \
                '    "origin=UbuntuESM,archive=${distro_codename}-infra-security";'
            if [[ "${scope}" == "all" ]]; then
                printf '%s\n' \
                    '    "origin=Ubuntu,archive=${distro_codename}-updates";' \
                    '    "origin=UbuntuESMApps,archive=${distro_codename}-apps-updates";' \
                    '    "origin=UbuntuESM,archive=${distro_codename}-infra-updates";'
                if [[ "${id}" == "pop" ]]; then
                    printf '    "origin=%s,codename=${distro_codename}";\n' "${_AUTO_UPDATES_POP_ORIGIN}"
                fi
            fi
            ;;
    esac
}

# _auto_updates_render_apt <id> <scope> <reboot> <enabled-timers>
_auto_updates_render_apt() {
    local id="$1" scope="$2" reboot="$3" timers="$4" auto_reboot="false"
    [[ "${reboot}" == "when-needed" ]] && auto_reboot="true"
    _auto_updates_header "//" "${scope}" "${reboot}" "${timers}"
    printf '%s\n' \
        "// Read after 20auto-upgrades and 50unattended-upgrades, so these values" \
        "// win; the #clear lines drop the origin lists those files set." \
        'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' \
        '#clear Unattended-Upgrade::Allowed-Origins;' \
        '#clear Unattended-Upgrade::Origins-Pattern;' \
        'Unattended-Upgrade::Origins-Pattern {'
    _auto_updates_apt_origins "${id}" "${scope}"
    printf '%s\n' '};' "Unattended-Upgrade::Automatic-Reboot \"${auto_reboot}\";"
    if [[ "${auto_reboot}" == "true" ]]; then
        printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot-Time "+5";'
    fi
}

# _auto_updates_render_suse <scope> <reboot> <enabled-timers>
# os-update reboots by default (REBOOT_CMD=auto) and has no delay setting:
# "auto" asks rebootmgr when it's running and reboots at once otherwise.
# "none" only logs that a reboot is needed.
_auto_updates_render_suse() {
    local scope="$1" reboot="$2" timers="$3" cmd="up" reboot_cmd="none"
    if [[ "${scope}" == "security" ]]; then
        cmd="security"
    else
        case "${WORKBENCH_DISTRO_ID:-}" in
            opensuse-tumbleweed|opensuse-slowroll) cmd="dup" ;;
        esac
    fi
    [[ "${reboot}" == "when-needed" ]] && reboot_cmd="auto"
    _auto_updates_header "#" "${scope}" "${reboot}" "${timers}"
    printf 'UPDATE_CMD="%s"\n' "${cmd}"
    printf 'REBOOT_CMD="%s"\n' "${reboot_cmd}"
}

# ── Writing ───────────────────────────────────────────────────────────────────

# _auto_updates_write <elev> <tmp> <dest> — 0644 root:root, directory created.
_auto_updates_write() {
    local elev="$1" tmp="$2" dest="$3"
    # shellcheck disable=SC2086
    ${elev} install -d -m 0755 "$(dirname "${dest}")" || return 1
    # shellcheck disable=SC2086
    ${elev} install -m 0644 "${tmp}" "${dest}"
}

# _auto_updates_install_package <backend> <elev>
_auto_updates_install_package() {
    local backend="$1" elev="$2" pkg
    pkg="$(_auto_updates_package "${backend}")"
    case "${backend}" in
        apt)
            # shellcheck disable=SC2016
            dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed' && return 0
            log_info "auto-updates: installing ${pkg}"
            # shellcheck disable=SC2086
            ${elev} env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}"
            ;;
        dnf5|dnf4)
            rpm -q "${pkg}" >/dev/null 2>&1 && return 0
            log_info "auto-updates: installing ${pkg}"
            # shellcheck disable=SC2086
            ${elev} dnf install -y "${pkg}"
            ;;
        os-update)
            rpm -q "${pkg}" >/dev/null 2>&1 && return 0
            log_info "auto-updates: installing ${pkg}"
            # shellcheck disable=SC2086
            ${elev} zypper --non-interactive install "${pkg}"
            ;;
    esac
}

# _auto_updates_manual_hint <backend> <scope> <reboot> — what to set by hand
# when the config file is someone else's.
_auto_updates_manual_hint() {
    local upgrade_type="default"
    [[ "$2" == "security" ]] && upgrade_type="security"
    case "$1" in
        dnf5)
            log_error "  To do it yourself, set in ${_AUTO_UPDATES_DNF5_CONF} under [commands]: upgrade_type = ${upgrade_type}, apply_updates = True, reboot = $3"
            log_error "  then: sudo systemctl enable --now dnf5-automatic.timer"
            ;;
        dnf4)
            log_error "  ${_AUTO_UPDATES_DNF4_CONF} is workbench's file name; move it aside and re-run, or configure ${_AUTO_UPDATES_DNF4_PACKAGED_CONF} yourself."
            ;;
        apt)
            log_error "  ${_AUTO_UPDATES_APT_CONF} is workbench's file name; move it aside and re-run."
            ;;
        os-update)
            log_error "  To do it yourself, set UPDATE_CMD and REBOOT_CMD in ${_AUTO_UPDATES_SUSE_CONF}, then: sudo systemctl enable --now os-update.timer"
            ;;
    esac
}

# _auto_updates_check_ownership <backend> <conf> <scope> <reboot>
# Refuses when a file workbench would write exists without its marker.
_auto_updates_check_ownership() {
    local backend="$1" conf="$2"
    if [[ -e "${conf}" ]] && ! _auto_updates_is_ours "${conf}"; then
        log_error "auto-updates: ${conf} exists and wasn't written by workbench, so nothing was changed."
        _auto_updates_manual_hint "${backend}" "$3" "$4"
        return 1
    fi
    if [[ "${backend}" == "dnf4" && -e "${_AUTO_UPDATES_DNF4_DROPIN}" ]] \
        && ! _auto_updates_is_ours "${_AUTO_UPDATES_DNF4_DROPIN}"; then
        log_error "auto-updates: ${_AUTO_UPDATES_DNF4_DROPIN} exists and wasn't written by workbench, so nothing was changed."
        return 1
    fi
    return 0
}

# Warn about apt.conf.d files read after workbench's that set the same options.
# apt reads names in C-locale order and skips names with an extension other
# than .conf (backups, .dpkg-old and so on).
_auto_updates_apt_later_overrides() {
    local dir mine
    dir="$(dirname "${_AUTO_UPDATES_APT_CONF}")"
    mine="$(basename "${_AUTO_UPDATES_APT_CONF}")"
    (
        LC_ALL=C
        passed="false"
        for file in "${dir}"/*; do
            name="$(basename "${file}")"
            if [[ "${name}" == "${mine}" ]]; then
                passed="true"
                continue
            fi
            [[ "${passed}" == "true" && -f "${file}" ]] || continue
            case "${name}" in
                *.conf) ;;
                *.*) continue ;;
            esac
            if grep -Eq 'Unattended-Upgrade::(Origins-Pattern|Allowed-Origins|Automatic-Reboot)|APT::Periodic::(Unattended-Upgrade|Update-Package-Lists)' "${file}"; then
                log_warn "auto-updates: ${file} is read after workbench's file and sets unattended-upgrades options; its values win."
            fi
        done
    )
}

# ── Installer ─────────────────────────────────────────────────────────────────

install-auto-updates() {
    local backend conf scope reboot recorded_timers timers t enabled_by_wb elev tmp
    local dropin_changed="false" changed="false"

    _auto_updates_check_host || return 1
    backend="$(_auto_updates_backend)" || return 1
    conf="$(_auto_updates_conf_path "${backend}")"

    scope="${AUTO_UPDATES_SCOPE:-$(_auto_updates_recorded "${conf}" scope)}"
    scope="${scope:-security}"
    reboot="${AUTO_UPDATES_REBOOT:-$(_auto_updates_recorded "${conf}" reboot)}"
    reboot="${reboot:-never}"
    _auto_updates_validate "${scope}" "${reboot}" || return 1

    # Everything that can refuse comes before the package install, so a
    # refusal changes nothing. The package can create a file, so the checks
    # that look at its files run again afterwards.
    _auto_updates_check_ownership "${backend}" "${conf}" "${scope}" "${reboot}" || return 1
    if [[ "${backend}" == "dnf4" && "${reboot}" == "when-needed" ]]; then
        _auto_updates_check_dnf4_reboot "false" || return 1
    fi

    elev="$(_auto_updates_elev)" || return 1
    _auto_updates_install_package "${backend}" "${elev}" \
        || { log_error "auto-updates: couldn't install $(_auto_updates_package "${backend}")"; return 1; }

    _auto_updates_check_ownership "${backend}" "${conf}" "${scope}" "${reboot}" || return 1
    if [[ "${backend}" == "dnf4" && "${reboot}" == "when-needed" ]]; then
        _auto_updates_check_dnf4_reboot "true" || return 1
    fi

    # Timers workbench enabled: what was recorded, plus any disabled now.
    recorded_timers="$(_auto_updates_recorded "${conf}" enabled-timers)"
    [[ "${recorded_timers}" == "none" ]] && recorded_timers=""
    enabled_by_wb="${recorded_timers}"
    timers="$(_auto_updates_timers "${backend}")"
    for t in ${timers}; do
        if ! systemctl is-enabled --quiet "${t}" 2>/dev/null; then
            case ",${enabled_by_wb}," in
                *",${t},"*) ;;
                *) enabled_by_wb="${enabled_by_wb:+${enabled_by_wb},}${t}" ;;
            esac
        fi
    done

    tmp="$(mktemp "${TMPDIR:-/tmp}/auto-updates.XXXXXX")" || return 1
    case "${backend}" in
        dnf5|dnf4) _auto_updates_render_dnf "${backend}" "${scope}" "${reboot}" "${enabled_by_wb:-none}" > "${tmp}" ;;
        apt)       _auto_updates_render_apt "${WORKBENCH_DISTRO_ID}" "${scope}" "${reboot}" "${enabled_by_wb:-none}" > "${tmp}" ;;
        os-update) _auto_updates_render_suse "${scope}" "${reboot}" "${enabled_by_wb:-none}" > "${tmp}" ;;
    esac
    if ! { [[ -f "${conf}" ]] && cmp -s "${tmp}" "${conf}"; }; then
        _auto_updates_write "${elev}" "${tmp}" "${conf}" \
            || { rm -f "${tmp}"; log_error "auto-updates: couldn't write ${conf}"; return 1; }
        changed="true"
    fi

    if [[ "${backend}" == "dnf4" ]]; then
        _auto_updates_render_dnf4_dropin > "${tmp}"
        if ! { [[ -f "${_AUTO_UPDATES_DNF4_DROPIN}" ]] && cmp -s "${tmp}" "${_AUTO_UPDATES_DNF4_DROPIN}"; }; then
            _auto_updates_write "${elev}" "${tmp}" "${_AUTO_UPDATES_DNF4_DROPIN}" \
                || { rm -f "${tmp}"; log_error "auto-updates: couldn't write ${_AUTO_UPDATES_DNF4_DROPIN}"; return 1; }
            dropin_changed="true"
            changed="true"
        fi
    fi
    rm -f "${tmp}"

    if [[ "${dropin_changed}" == "true" ]]; then
        # shellcheck disable=SC2086
        ${elev} systemctl daemon-reload || return 1
    fi
    for t in ${timers}; do
        if ! systemctl is-enabled --quiet "${t}" 2>/dev/null; then
            # shellcheck disable=SC2086
            ${elev} systemctl enable --now "${t}" \
                || { log_error "auto-updates: couldn't enable ${t}"; return 1; }
            changed="true"
        fi
    done

    if [[ "${backend}" == "apt" ]]; then
        _auto_updates_apt_later_overrides
    fi
    if [[ "${WORKBENCH_DISTRO_ID:-}" == "pop" && "${scope}" == "security" ]]; then
        log_warn "auto-updates: Pop!_OS's own repository (kernel, COSMIC, firmware) has no security pocket, so security-only doesn't cover it. AUTO_UPDATES_SCOPE=all includes it."
    fi
    if [[ "${changed}" == "true" ]]; then
        log_info "auto-updates: on (${backend}, scope ${scope}, reboot ${reboot}). 'distro-auto-updates' shows the next run."
    else
        log_info "auto-updates: already on (${backend}, scope ${scope}, reboot ${reboot})"
    fi
    return 0
}

# Exit 0 when workbench's config is in place, 1 otherwise. Never elevates.
installed-auto-updates() {
    local backend conf
    backend="$(_auto_updates_backend 2>/dev/null)" || return 1
    conf="$(_auto_updates_conf_path "${backend}")"
    _auto_updates_is_ours "${conf}" || return 1
    if [[ "${backend}" == "dnf4" ]]; then
        _auto_updates_is_ours "${_AUTO_UPDATES_DNF4_DROPIN}" || return 1
    fi
    return 0
}
