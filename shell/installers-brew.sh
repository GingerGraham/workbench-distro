#!/usr/bin/env bash
# shell/installers-brew.sh — workbench-distro
# install-brew / installed-brew (workbench-core D134).
#
# macOS, Apple Silicon, 15+: Homebrew's signed .pkg from its latest GitHub
#   release, checked against GitHub's SHA-256 and a pinned Team ID.
# macOS, Apple Silicon, 11-14: Homebrew's install.sh (Tier 3), with a warning.
# macOS, Intel: refused. install.sh stops there ("Homebrew on macOS is only
#   supported on Apple Silicon processors!", read from Homebrew/install HEAD
#   on 27 Nov 2026).
# Linux x86_64/aarch64: report and ask for Homebrew's prerequisites (D117),
#   then install.sh on the terminal, which asks before it starts.
# Already installed: `brew update` (Homebrew itself), so `wb tools upgrade
#   brew` works on any brew, including one the user installed.
#
# install.sh comes from Homebrew/install HEAD under the vendor-script policy
# (accepted and documented, as for starship and oh-my-posh).
#
# `wb tools` sources this file on its own, in bash: no helpers from
# shell/distro*.sh.

# ── Overridable for tests only ────────────────────────────────────────────────
_BREW_RELEASES_API="${_BREW_RELEASES_API:-https://api.github.com/repos/Homebrew/brew/releases/latest}"
_BREW_INSTALL_SH_URL="${_BREW_INSTALL_SH_URL:-https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh}"
_BREW_PREFIX_CANDIDATES="${_BREW_PREFIX_CANDIDATES:-}"   # space-separated; empty = per-OS defaults
_BREW_TEST_EUID="${_BREW_TEST_EUID:-}"
_BREW_TTY="${_BREW_TTY:-/dev/tty}"

# Developer ID Installer Team ID that signs Homebrew's .pkg: "Developer ID
# Installer: Patrick Linnane (927JGANW46)", a Homebrew lead maintainer.
# Confirmed 27 Nov 2026 against the latest release with check-pkg-signer.py
# (Linux; project tools/). The signature is an individual maintainer's, so
# Homebrew may change it: a different signer fails closed, and the value is
# re-confirmed and updated here, never loosened.
_BREW_PKG_TEAM_ID="927JGANW46"

# ── Helpers (private) ─────────────────────────────────────────────────────────

_brew_euid() {
    if [[ -n "${_BREW_TEST_EUID}" ]]; then
        printf '%s\n' "${_BREW_TEST_EUID}"
    else
        printf '%s\n' "${EUID:-$(id -u)}"
    fi
}

_brew_have_tty() {
    { : <"${_BREW_TTY}"; } 2>/dev/null
}

# _brew_find — prints the brew executable, or returns 1.
_brew_find() {
    local p candidates
    if [[ -n "${HOMEBREW_PREFIX:-}" && -x "${HOMEBREW_PREFIX}/bin/brew" ]]; then
        printf '%s\n' "${HOMEBREW_PREFIX}/bin/brew"
        return 0
    fi
    candidates="${_BREW_PREFIX_CANDIDATES}"
    if [[ -z "${candidates}" ]]; then
        if [[ "${WORKBENCH_OS:-}" == "Mac" ]]; then
            candidates="/opt/homebrew /usr/local"
        else
            candidates="/home/linuxbrew/.linuxbrew ${HOME}/.linuxbrew"
        fi
    fi
    for p in ${candidates}; do
        if [[ -x "${p}/bin/brew" ]]; then
            printf '%s\n' "${p}/bin/brew"
            return 0
        fi
    done
    return 1
}

# _brew_activate_here <brew-executable> — PATH for this process only, so a
# later target in the same `wb tools install` run sees brew. Same placement
# rule as the loader (D134).
_brew_activate_here() {
    local prefix="${1%/bin/brew}" mode="${WORKBENCH_BREW_PATH:-}"
    case ":${PATH}:" in
        *":${prefix}/bin:"*) export HOMEBREW_PREFIX="${prefix}"; return 0 ;;
    esac
    if [[ -z "${mode}" ]]; then
        if [[ "${WORKBENCH_OS:-}" == "Mac" ]]; then mode="front"; else mode="end"; fi
    fi
    case "${mode}" in
        off)   return 0 ;;
        front) PATH="${prefix}/bin:${prefix}/sbin${PATH:+:${PATH}}" ;;
        *)     PATH="${PATH:+${PATH}:}${prefix}/bin:${prefix}/sbin" ;;
    esac
    export PATH HOMEBREW_PREFIX="${prefix}"
}

_brew_macos_major() {
    sw_vers -productVersion 2>/dev/null | cut -d. -f1
}

_brew_self_update() {
    local brew_bin="$1"
    log_info "brew: Homebrew is installed at ${brew_bin%/bin/brew}; updating Homebrew itself (brew update). 'brew-update' or 'distro-update' upgrades packages."
    "${brew_bin}" update
}

# ── Linux prerequisites (Homebrew's documented lists) ─────────────────────────

_brew_linux_missing() {
    local bin missing=""
    for bin in gcc make curl file git ps; do
        command -v "${bin}" >/dev/null 2>&1 || missing="${missing} ${bin}"
    done
    printf '%s\n' "${missing# }"
}

# One command per line, without elevation. No argument contains a space.
_brew_linux_prereq_steps() {
    case "${WORKBENCH_DISTRO:-unknown}" in
        debian)
            printf '%s\n' "apt-get install -y build-essential procps curl file git"
            ;;
        rhel)
            if [[ "${WORKBENCH_DISTRO_ID:-}" == "fedora" ]]; then
                printf '%s\n' "dnf group install -y development-tools"
            else
                printf '%s\n' "dnf group install -y development"
            fi
            # git-core: the binary without git's Perl tooling (D117).
            printf '%s\n' "dnf install -y procps-ng curl file git-core"
            ;;
        arch)
            printf '%s\n' "pacman -S --needed --noconfirm base-devel procps-ng curl file git"
            ;;
        suse)
            printf '%s\n' "zypper --non-interactive install -t pattern devel_basis" \
                "zypper --non-interactive install procps curl file git"
            ;;
        *)
            return 1
            ;;
    esac
}

_brew_linux_prereqs() {
    local missing elev line reply i
    local -a steps=() cmd=()

    missing="$(_brew_linux_missing)"
    [[ -z "${missing}" ]] && return 0

    while IFS= read -r line; do
        [[ -n "${line}" ]] && steps+=("${line}")
    done < <(_brew_linux_prereq_steps)
    if [[ "${#steps[@]}" -eq 0 ]]; then
        log_error "brew: missing ${missing}, and workbench doesn't know this distribution's packages for Homebrew. See https://docs.brew.sh/Homebrew-on-Linux#requirements, then re-run."
        return 1
    fi

    elev="$(get-elevation-command)" || {
        log_error "brew: installing Homebrew's prerequisites needs sudo or run0. Missing: ${missing}"
        return 1
    }

    {
        echo
        echo "brew: Homebrew's installer needs tools that are missing: ${missing}"
        echo "brew: this will run:"
        i=0
        while [[ ${i} -lt ${#steps[@]} ]]; do
            echo "  ${elev} ${steps[${i}]}"
            i=$((i + 1))
        done
    } >&2

    if ! _brew_have_tty; then
        log_error "brew: no terminal to ask on. Install them yourself, then re-run 'wb tools install brew'. Nothing was changed."
        return 1
    fi
    _read_prompt "Install them now? [y/N]: " reply
    case "$(_str_lower "${reply}")" in
        y|yes) ;;
        *) log_info "brew: stopped. Nothing was changed."; return 1 ;;
    esac

    i=0
    while [[ ${i} -lt ${#steps[@]} ]]; do
        read -r -a cmd <<< "${steps[${i}]}"
        # shellcheck disable=SC2086
        ${elev} "${cmd[@]}" </dev/null || { log_error "brew: '${steps[${i}]}' failed"; return 1; }
        i=$((i + 1))
    done

    missing="$(_brew_linux_missing)"
    if [[ -n "${missing}" ]]; then
        log_error "brew: still missing after installing: ${missing}"
        return 1
    fi
    log_info "brew: installed Homebrew's prerequisites"
}

# ── Install routes ────────────────────────────────────────────────────────────

_brew_install_script() {
    local tmp rc
    if ! _brew_have_tty; then
        log_error "brew: Homebrew's installer needs a terminal (it asks for your password and a confirmation)."
        return 1
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/brew-install.XXXXXX")" || { log_error "brew: mktemp failed"; return 1; }
    if ! _download_file_robust "${_BREW_INSTALL_SH_URL}" "${tmp}" || [[ ! -s "${tmp}" ]]; then
        log_error "brew: couldn't download ${_BREW_INSTALL_SH_URL}"
        rm -f "${tmp}"
        return 1
    fi
    log_info "brew: running Homebrew's install script (${_BREW_INSTALL_SH_URL}). It shows what it will do and asks before it starts."
    # stdin from the terminal: install.sh switches to non-interactive mode
    # when stdin isn't one.
    /bin/bash "${tmp}" <"${_BREW_TTY}"
    rc=$?
    rm -f "${tmp}"
    return "${rc}"
}

_brew_pkg_signed_by_homebrew() {
    local pkg="$1" out
    if ! out="$(pkgutil --check-signature "${pkg}" 2>&1)"; then
        log_error "brew: ${pkg##*/} has no valid signature:"
        printf '%s\n' "${out}" >&2
        return 1
    fi
    case "${out}" in
        *"signed by a developer certificate issued by Apple for distribution"*) ;;
        *) log_error "brew: ${pkg##*/} isn't signed with a Developer ID certificate"; return 1 ;;
    esac
    case "${out}" in
        *"(${_BREW_PKG_TEAM_ID})"*) ;;
        *)
            log_error "brew: ${pkg##*/} isn't signed by the Team ID workbench expects (${_BREW_PKG_TEAM_ID}). Homebrew may have changed who signs it; nothing was installed. Please report it against workbench-distro."
            return 1
            ;;
    esac
    if ! spctl --assess --type install "${pkg}" >/dev/null 2>&1; then
        log_error "brew: Gatekeeper rejects ${pkg##*/} (not notarized?)"
        return 1
    fi
}

_brew_install_pkg() {
    local api url digest tmp_dir pkg elev rc
    api="$(curl -fsS "${_BREW_RELEASES_API}")" || { log_error "brew: couldn't read ${_BREW_RELEASES_API}"; return 1; }
    # The asset has no version in its name (confirmed 27 Nov 2026).
    url="$(_wb_gh_release_asset_url "${api}" '/Homebrew\.pkg$')"
    if [[ -z "${url}" ]]; then
        log_error "brew: Homebrew/brew's latest release has no .pkg"
        return 1
    fi
    digest="$(_wb_gh_asset_digest "${api}" "${url}")"
    if [[ -z "${digest}" ]]; then
        log_error "brew: GitHub publishes no SHA-256 for ${url##*/}; not installing an unverified package"
        return 1
    fi
    tmp_dir="$(mktemp -d)" || { log_error "brew: mktemp failed"; return 1; }
    pkg="${tmp_dir}/${url##*/}"
    if ! _wb_fetch_verified "${url}" "${pkg}" "${digest}"; then
        rm -rf "${tmp_dir}"
        return 1
    fi
    if ! _brew_pkg_signed_by_homebrew "${pkg}"; then
        rm -rf "${tmp_dir}"
        return 1
    fi
    elev="$(get-elevation-command)" || { rm -rf "${tmp_dir}"; log_error "brew: installing the .pkg needs sudo"; return 1; }
    log_info "brew: installing ${url##*/} with macOS Installer (asks for your password)"
    # shellcheck disable=SC2086
    ${elev} installer -pkg "${pkg}" -target /
    rc=$?
    rm -rf "${tmp_dir}"
    return "${rc}"
}

# ── Entry points ──────────────────────────────────────────────────────────────

install-brew() {
    local brew_bin major arch

    if [[ "$(_brew_euid)" -eq 0 ]]; then
        log_error "brew: Homebrew doesn't run as root. Run 'wb tools install brew' as your own user."
        return 1
    fi

    if brew_bin="$(_brew_find)"; then
        _brew_self_update "${brew_bin}"
        return $?
    fi

    arch="${WORKBENCH_ARCH:-$(uname -m)}"
    case "${WORKBENCH_OS:-}" in
        Mac)
            major="$(_brew_macos_major)"
            case "${major}" in
                ''|*[!0-9]*) log_error "brew: couldn't read the macOS version"; return 1 ;;
            esac
            if [[ "${major}" -le 10 ]]; then
                log_error "brew: Homebrew no longer runs on macOS 10.15 or earlier."
                return 1
            fi
            if [[ "${arch}" != "arm64" ]]; then
                log_error "brew: this is an Intel Mac, and Homebrew's installer stops there: \"Homebrew on macOS is only supported on Apple Silicon processors!\" An existing Homebrew is still found, and 'wb tools upgrade brew' updates it."
                return 1
            fi
            if [[ "${major}" -ge 15 ]]; then
                _brew_install_pkg || return 1
            else
                log_warn "brew: Homebrew supports macOS before 15 at Tier 3 only: fewer prebuilt packages. Using Homebrew's install script."
                _brew_install_script || return 1
            fi
            if ! xcode-select -p >/dev/null 2>&1; then
                log_warn "brew: the Xcode Command Line Tools aren't installed. Formulae built from source need them: xcode-select --install"
            fi
            ;;
        Linux)
            case "${arch}" in
                x86_64|aarch64) ;;
                *) log_error "brew: Homebrew on Linux supports x86_64 and aarch64, not ${arch}."; return 1 ;;
            esac
            if [[ "${WORKBENCH_WSL:-false}" == "true" ]] \
                && ! grep -qi wsl2 /proc/sys/kernel/osrelease 2>/dev/null; then
                log_warn "brew: this looks like WSL 1, where Homebrew is Tier 3 and some packages break. WSL 2 is supported."
            fi
            _brew_linux_prereqs || return 1
            _brew_install_script || return 1
            ;;
        *)
            log_error "brew: unsupported OS '${WORKBENCH_OS:-unknown}'"
            return 1
            ;;
    esac

    if ! brew_bin="$(_brew_find)"; then
        log_error "brew: the installer finished, but no brew was found where Homebrew installs it."
        return 1
    fi
    _brew_activate_here "${brew_bin}"
    log_info "brew: installed $("${brew_bin}" --version 2>/dev/null | head -n 1) at ${brew_bin%/bin/brew}. Open a new shell, or run 'wb reload', to use it."
    if [[ "${WORKBENCH_OS:-}" == "Linux" ]]; then
        log_info "brew: workbench puts Homebrew at the end of PATH on Linux, so your distribution's packages win where both provide a command. WORKBENCH_BREW_PATH=front in ~/.config/workbench/local/settings.sh changes that."
    fi
}

installed-brew() {
    _brew_find >/dev/null
}
