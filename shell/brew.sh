#!/usr/bin/env bash
# shell/brew.sh — workbench-distro (tools tier)
# brew-update: Homebrew's own update, then package upgrades, as your user.
# workbench-core puts brew on PATH before any tier (Core API 1.14, D134).

_wb_declare_availability brew brew-update

brew-update() {
    local greedy="false" cleanup="false" arg
    for arg in "$@"; do
        case "${arg}" in
            --greedy)  greedy="true" ;;
            --cleanup) cleanup="true" ;;
            -h|--help)
                printf '%s\n' "Usage: brew-update [--greedy] [--cleanup]" \
                    "Runs 'brew update', then 'brew upgrade' (formulae and casks)." \
                    "  --greedy   also upgrade casks that update themselves" \
                    "  --cleanup  then 'brew cleanup'"
                return 0
                ;;
            *) log_error "brew-update: unknown option '${arg}'"; return 2 ;;
        esac
    done

    # _BREW_TEST_EUID: for tests only, as in shell/installers-brew.sh.
    if [[ "${_BREW_TEST_EUID:-${EUID:-$(id -u)}}" -eq 0 ]]; then
        log_error "brew-update: don't run Homebrew as root or with sudo. Run it as the user who owns ${HOMEBREW_PREFIX:-the Homebrew prefix}."
        return 1
    fi
    if ! command -v brew >/dev/null 2>&1; then
        log_error "brew-update: brew isn't on PATH. Install it with 'wb tools install brew'."
        return 1
    fi

    log_info "brew-update: updating Homebrew"
    brew update || return $?
    log_info "brew-update: upgrading formulae and casks"
    if [[ "${greedy}" == "true" ]]; then
        brew upgrade --greedy || return $?
    else
        brew upgrade || return $?
    fi
    if [[ "${cleanup}" == "true" ]]; then
        brew cleanup || log_warn "brew-update: brew cleanup failed (packages were upgraded)"
    fi
    return 0
}
