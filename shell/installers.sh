#!/usr/bin/env bash
# shell/installers.sh — workbench-distro
# install-dnf-tuning / installed-dnf-tuning. Writes a DNF 5 drop-in, never
# the user's /etc/dnf/dnf.conf: dnf.conf is read after the drop-ins, so any
# value the user sets there still wins (workbench-core D110: change only
# state workbench created).
#
# `wb tools` sources this file on its own, so it can't use helpers from
# shell/distro*.sh. It keeps its own small copies.

# Overridable for tests only.
_DNF_TUNING_FILE="${_DNF_TUNING_FILE:-/etc/dnf/libdnf5.conf.d/50-workbench.conf}"
_DNF_TUNING_DNF_CONF="${_DNF_TUNING_DNF_CONF:-/etc/dnf/dnf.conf}"
_DNF_TUNING_OSTREE_MARKER="${_DNF_TUNING_OSTREE_MARKER:-/run/ostree-booted}"

_dnf_tuning_is_dnf5() {
    local dnf_path
    dnf_path="$(command -v dnf 2>/dev/null)" || return 1
    case "$(readlink -f "${dnf_path}" 2>/dev/null)" in
        */dnf5) return 0 ;;
    esac
    return 1
}

_dnf_tuning_elev() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi
    get-elevation-command
}

# Warn when the user's own dnf.conf sets a value, since theirs wins.
_dnf_tuning_report_overrides() {
    local key
    [[ -r "${_DNF_TUNING_DNF_CONF}" ]] || return 0
    for key in max_parallel_downloads fastestmirror; do
        if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "${_DNF_TUNING_DNF_CONF}"; then
            log_warn "dnf-tuning: ${_DNF_TUNING_DNF_CONF} sets ${key}; that value wins over workbench's."
        fi
    done
}

install-dnf-tuning() {
    local parallel="${DNF_PARALLEL_DOWNLOADS:-10}" fastest="${DNF_FASTESTMIRROR:-false}" elev tmp

    if [[ "${WORKBENCH_DISTRO:-}" != "rhel" ]] || ! command -v dnf >/dev/null 2>&1; then
        log_error "dnf-tuning: only for dnf-based (Fedora/RHEL-family) systems"
        return 1
    fi
    if [[ -e "${_DNF_TUNING_OSTREE_MARKER}" ]]; then
        log_error "dnf-tuning: not for rpm-ostree systems"
        return 1
    fi
    case "${parallel}" in
        ''|*[!0-9]*) log_error "dnf-tuning: DNF_PARALLEL_DOWNLOADS must be a whole number from 1 to 20 (got '${parallel}')"; return 1 ;;
    esac
    if (( parallel < 1 || parallel > 20 )); then
        log_error "dnf-tuning: DNF_PARALLEL_DOWNLOADS must be from 1 to 20 (got ${parallel})"
        return 1
    fi
    case "${fastest}" in
        true|false) ;;
        *) log_error "dnf-tuning: DNF_FASTESTMIRROR must be true or false (got '${fastest}')"; return 1 ;;
    esac
    if ! _dnf_tuning_is_dnf5; then
        log_error "dnf-tuning: this system runs DNF 4, which has no drop-in directory for these settings, and workbench doesn't edit your dnf.conf. To set it yourself:"
        log_error "  sudo dnf config-manager --save --setopt=max_parallel_downloads=${parallel}"
        return 1
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/dnf-tuning.XXXXXX")" || return 1
    {
        printf '%s\n' "# Written by workbench-distro (wb tools install dnf-tuning)."
        printf '%s\n' "# Values in ${_DNF_TUNING_DNF_CONF} take precedence over this file."
        printf '%s\n' "# Remove with: sudo rm ${_DNF_TUNING_FILE}"
        printf '%s\n' "[main]"
        printf 'max_parallel_downloads=%s\n' "${parallel}"
        if [[ "${fastest}" == "true" ]]; then
            printf '%s\n' "fastestmirror=True"
        fi
    } > "${tmp}"

    if [[ -f "${_DNF_TUNING_FILE}" ]] && cmp -s "${tmp}" "${_DNF_TUNING_FILE}"; then
        rm -f "${tmp}"
        log_info "dnf-tuning: already applied (${_DNF_TUNING_FILE})"
        _dnf_tuning_report_overrides
        return 0
    fi

    elev="$(_dnf_tuning_elev)" || { rm -f "${tmp}"; return 1; }
    # shellcheck disable=SC2086
    if ! ${elev} install -d -m 0755 "$(dirname "${_DNF_TUNING_FILE}")" \
        || ! ${elev} install -m 0644 "${tmp}" "${_DNF_TUNING_FILE}"; then
        rm -f "${tmp}"
        log_error "dnf-tuning: couldn't write ${_DNF_TUNING_FILE}"
        return 1
    fi
    rm -f "${tmp}"
    log_info "dnf-tuning: wrote ${_DNF_TUNING_FILE} (max_parallel_downloads=${parallel}, fastestmirror=${fastest})"
    _dnf_tuning_report_overrides
    return 0
}

installed-dnf-tuning() {
    [[ -f "${_DNF_TUNING_FILE}" ]]
}
