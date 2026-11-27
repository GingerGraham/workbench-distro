#!/usr/bin/env bash
# tests/check-brew.sh — workbench-distro
# install-brew / installed-brew (shell/installers-brew.sh), brew-update
# (shell/brew.sh) and the Homebrew parts of distro-update (shell/distro.sh)
# (workbench-core D134). Plain bash, numbered OK:/FAIL: checks, same harness
# as check-distro-dispatch.sh. No network, no root, no real package manager,
# no real Homebrew: every external tool is a fake that logs what it was
# called with.
#
#   - installed-brew, the root refusal, and brew update when already there;
#   - Linux: arch refusal, Homebrew's prerequisites per family, asking once,
#     then install.sh on the terminal;
#   - macOS: the signed .pkg route and each way it is refused, the install.sh
#     route for Apple Silicon on macOS 11-14, Intel and macOS 10 refused;
#   - the process PATH after an install follows WORKBENCH_BREW_PATH;
#   - brew-update, distro-update on Linux and on macOS, availability, and
#     silent sourcing.
#
# Installer scenarios run in bash only, which is how workbench-core runs
# installer files. Shell-function scenarios run in bash and, when installed,
# zsh. The Core API pieces the installer calls (_wb_fetch_verified and its
# helpers) are stubbed: this module's CI has no core checkout, and core's own
# tests/check-fetch-verified.sh covers them.
# shellcheck disable=SC2016  # the fakes and the checks are single-quoted scripts on purpose
set -uo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib/harness.sh"

# ── Fixtures ──────────────────────────────────────────────────────────────────
DIGEST="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
PKG_URL="https://github.com/Homebrew/brew/releases/download/7.0.0/Homebrew.pkg"
FIX="${WORK}/fixtures"
mkdir -p "${FIX}"
cat > "${FIX}/api-ok.json" <<EOF
{"tag_name":"7.0.0","assets":[{"name":"Homebrew.pkg","digest":"sha256:${DIGEST}","browser_download_url":"${PKG_URL}"}]}
EOF
cat > "${FIX}/api-no-pkg.json" <<EOF
{"tag_name":"7.0.0","assets":[{"name":"notes.txt","digest":"sha256:${DIGEST}","browser_download_url":"https://github.com/Homebrew/brew/releases/download/7.0.0/notes.txt"}]}
EOF
cat > "${FIX}/api-null-digest.json" <<EOF
{"tag_name":"7.0.0","assets":[{"name":"Homebrew.pkg","digest":null,"browser_download_url":"${PKG_URL}"}]}
EOF
cat > "${FIX}/sig-ok.txt" <<'EOF'
Package "Homebrew.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. Developer ID Installer: Patrick Linnane (927JGANW46)
       Expires: 2029-07-02
EOF
sed 's/927JGANW46/AAAAAAAAAA/' "${FIX}/sig-ok.txt" > "${FIX}/sig-wrong-team.txt"
printf 'Package "Homebrew.pkg":\n   Status: signed Apple Software\n' > "${FIX}/sig-not-developer-id.txt"
printf 'Package "Homebrew.pkg":\n   Status: no signature\n' > "${FIX}/sig-none.txt"
# install.sh stand-in: records that it ran and leaves a brew in the test prefix.
cat > "${FIX}/install.sh" <<'EOF'
#!/bin/bash
echo "install.sh ran" >> "${LOG}"
[ "${INSTALL_SH_FAIL:-0}" = 1 ] && exit 1
/bin/mkdir -p "${HOME}/prefix/bin"
printf '#!/bin/sh\necho "brew $*" >> "$LOG"\n[ "$1" = "--version" ] && echo "Homebrew 7.0.0"\n[ -n "$FAIL_ON" ] && echo "brew $*" | grep -Eq -e "$FAIL_ON" && exit 1\nexit 0\n' > "${HOME}/prefix/bin/brew"
/bin/chmod +x "${HOME}/prefix/bin/brew"
EOF
: > "${WORK}/tty"   # stands in for /dev/tty: a readable file

# ── Fakes ─────────────────────────────────────────────────────────────────────
# Package managers: an install step supplies Homebrew's prerequisites unless
# PREREQ_PROVIDE=no. dnf also answers `needs-restarting` for distro-update.
PROVIDE='for t in gcc make curl file git ps; do [ -e "${HOME}/bin/${t}" ] || /bin/ln -s /usr/bin/true "${HOME}/bin/${t}"; done'
fake apt-get 'case "$*" in *install*) [ "${PREREQ_PROVIDE:-yes}" = yes ] && { '"${PROVIDE}"'; } ;; esac'
fake dnf 'case "$*" in needs-restarting*) exit "${NR_RC:-0}" ;; *install*) [ "${PREREQ_PROVIDE:-yes}" = yes ] && { '"${PROVIDE}"'; } ;; esac'
fake pacman 'case "$*" in *base-devel*) [ "${PREREQ_PROVIDE:-yes}" = yes ] && { '"${PROVIDE}"'; } ;; esac'
fake zypper 'case "$*" in *"install procps"*) [ "${PREREQ_PROVIDE:-yes}" = yes ] && { '"${PROVIDE}"'; } ;; esac'
fake readlink 'echo /usr/bin/dnf5'
fake flatpak
fake brew
# What Homebrew's installer needs on Linux, and curl for the .pkg route.
fake gcc
fake make
fake file
fake git
fake ps
fake curl '[ -n "${API_FILE:-}" ] && cat "${API_FILE}"'
fake sw_vers 'echo "${SW_VERS:-15.1}"'
fake xcode-select
fake spctl
fake pkgutil 'cat "${PKGUTIL_OUT:-}" 2>/dev/null; exit "${PKGUTIL_RC:-0}"'
fake installer '/bin/mkdir -p "${HOME}/prefix/bin"
printf "#!/bin/sh\necho \"brew \$*\" >> \"\$LOG\"\n[ \"\$1\" = \"--version\" ] && echo \"Homebrew 7.0.0\"\nexit 0\n" > "${HOME}/prefix/bin/brew"
/bin/chmod +x "${HOME}/prefix/bin/brew"'

cat > "${WORK}/scenario.sh" <<'EOF'
. "${REPO_ROOT}/tests/lib/prelude.sh"

# Core API pieces the installer calls, stubbed.
_str_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
_download_file_robust() {
    echo "download $1" >> "${LOG}"
    [ "${DL_FAIL:-0}" = 1 ] && return 1
    cp "${INSTALL_SH_SRC}" "$2"
}
_wb_fetch_verified() {
    echo "fetch_verified $1 $3" >> "${LOG}"
    [ "${FETCH_FAIL:-0}" = 1 ] && return 1
    : > "$2"
}
# The same bodies as core's installers-common.sh.
_wb_gh_release_asset_url() {
    printf '%s' "$1" \
        | grep -Eo '"browser_download_url": *"[^"]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/' \
        | grep -E "$2" \
        | head -1
}
_wb_gh_asset_digest() {
    printf '%s' "$1" \
        | grep -oE '"(digest|browser_download_url)"[[:space:]]*:[[:space:]]*("[^"]*"|null)' \
        | sed -E 's/^"(digest|browser_download_url)"[[:space:]]*:[[:space:]]*"?([^"]*)"?$/\1 \2/' \
        | awk -v want="$2" '
            $1 == "digest" { last_digest = $2; next }
            $1 == "browser_download_url" {
                if ($2 == want) { print last_digest; exit }
                last_digest = ""
            }
          ' \
        | sed -n 's/^sha256://p'
}

# A brew already installed under the test prefix.
make_brew() {
    mkdir -p "${HOME}/prefix/bin"
    printf '#!/bin/sh\necho "brew $*" >> "$LOG"\n[ "$1" = "--version" ] && echo "Homebrew 7.0.0"\n[ -n "$FAIL_ON" ] && echo "brew $*" | grep -Eq -e "$FAIL_ON" && exit 1\nexit 0\n' > "${HOME}/prefix/bin/brew"
    /bin/chmod +x "${HOME}/prefix/bin/brew"
}
[ "${PRESENT:-0}" = 1 ] && make_brew
INST="${HOME}/inst.out"
START_PATH="${PATH}"

case "${SCENARIO}" in
    # ── installed-brew ──────────────────────────────────────────────────────
    find)
        installed-brew; rc1=$?
        make_brew
        installed-brew; rc2=$?
        mkdir -p "${HOME}/other/bin"; cp "${HOME}/prefix/bin/brew" "${HOME}/other/bin/brew"
        rm -rf "${HOME}/prefix"
        HOMEBREW_PREFIX="${HOME}/other" installed-brew; rc3=$?
        HOMEBREW_PREFIX="${HOME}/missing" installed-brew; rc4=$?
        check "installed-brew: 1 with no brew at any candidate" '[ ${rc1} -eq 1 ]'
        check "installed-brew: 0 with <candidate>/bin/brew" '[ ${rc2} -eq 0 ]'
        check "installed-brew: 0 through HOMEBREW_PREFIX" '[ ${rc3} -eq 0 ]'
        check "installed-brew: a stale HOMEBREW_PREFIX doesn't count" '[ ${rc4} -eq 1 ]'
        ;;

    # ── Refusals before anything runs ───────────────────────────────────────
    root)
        install-brew >"${INST}" 2>&1; rc=$?
        check "root: refused" '[ ${rc} -ne 0 ]'
        check "root: says why" 'out_has "doesn.t run as root"'
        check "root: nothing ran" 'ran_nothing'
        ;;
    linux-arch)
        install-brew >"${INST}" 2>&1; rc=$?
        check "armv7l: refused" '[ ${rc} -ne 0 ]'
        check "armv7l: names the supported architectures" 'out_has "x86_64 and aarch64, not armv7l"'
        check "armv7l: nothing ran" 'ran_nothing'
        ;;

    # ── Already installed ───────────────────────────────────────────────────
    present)
        install-brew >"${INST}" 2>&1; rc=$?
        check "present: succeeds" '[ ${rc} -eq 0 ]'
        check "present: brew update, once" '[ "$(grep -c "^brew update$" "${LOG}")" = 1 ]'
        check "present: nothing else was installed" '! logged "install.sh" && ! logged "^elev"'
        ;;
    present-fails)
        install-brew >"${INST}" 2>&1; rc=$?
        check "present, brew update fails: its status comes back" '[ ${rc} -ne 0 ]'
        ;;

    # ── Linux prerequisites ─────────────────────────────────────────────────
    prereq-report)
        install-brew >"${INST}" 2>&1; rc=$?
        check "report: stopped when answered n" '[ ${rc} -ne 0 ]'
        check "report: names what is missing" 'grep -q "missing: gcc make curl file git ps" "${INST}"'
        check "report: asked once" '[ "$(grep -c "^PROMPT:" "${OUT}")" = 1 ]'
        check "report: nothing ran" 'ran_nothing'
        check "report: install.sh not fetched" '! logged "^download"'
        case "${EXPECT_FAMILY}" in
            debian)
                check "debian: build-essential line" 'grep -qxF "  elev apt-get install -y build-essential procps curl file git" "${INST}"' ;;
            fedora)
                check "fedora: development-tools group" 'grep -qxF "  elev dnf group install -y development-tools" "${INST}"'
                check "fedora: git-core line" 'grep -qxF "  elev dnf install -y procps-ng curl file git-core" "${INST}"' ;;
            rocky)
                check "rocky: development group" 'grep -qxF "  elev dnf group install -y development" "${INST}"'
                check "rocky: git-core line" 'grep -qxF "  elev dnf install -y procps-ng curl file git-core" "${INST}"' ;;
            arch)
                check "arch: base-devel line" 'grep -qxF "  elev pacman -S --needed --noconfirm base-devel procps-ng curl file git" "${INST}"' ;;
            suse)
                check "suse: devel_basis pattern" 'grep -qxF "  elev zypper --non-interactive install -t pattern devel_basis" "${INST}"'
                check "suse: the rest" 'grep -qxF "  elev zypper --non-interactive install procps curl file git" "${INST}"' ;;
        esac
        ;;
    prereq-unknown)
        install-brew >"${INST}" 2>&1; rc=$?
        check "unknown family: refused" '[ ${rc} -ne 0 ]'
        check "unknown family: links Homebrew's requirements" 'out_has "docs.brew.sh/Homebrew-on-Linux#requirements"'
        check "unknown family: nothing ran, nothing asked" 'ran_nothing && ! out_has "^PROMPT:"'
        ;;
    prereq-no-tty)
        install-brew >"${INST}" 2>&1; rc=$?
        check "no terminal: exit 1" '[ ${rc} -eq 1 ]'
        check "no terminal: says nothing was changed" 'out_has "no terminal to ask on"'
        check "no terminal: no package manager called" '! logged "apt-get" && ! logged "^elev"'
        ;;
    prereq-yes)
        install-brew >"${INST}" 2>&1; rc=$?
        check "y: succeeds" '[ ${rc} -eq 0 ]'
        check "y: the line ran elevated" 'logged "^elev apt-get install -y build-essential procps curl file git$"'
        check "y: and reached the package manager" 'logged "^apt-get install -y build-essential"'
        check "y: install.sh runs after the prerequisites" 'line_before "^apt-get install" "^install.sh ran"'
        check "y: install.sh was downloaded from the install script URL" 'logged "^download fake://install.sh$"'
        ;;
    prereq-still-missing)
        install-brew >"${INST}" 2>&1; rc=$?
        check "still missing: exit 1" '[ ${rc} -eq 1 ]'
        check "still missing: names them" 'out_has "still missing after installing: gcc make curl file git ps"'
        check "still missing: install.sh not run" '! logged "install.sh ran"'
        ;;
    linux-script)
        install-brew >"${INST}" 2>&1; rc=$?
        check "prerequisites present: succeeds" '[ ${rc} -eq 0 ]'
        check "prerequisites present: asked nothing, installed no packages" '! out_has "^PROMPT:" && ! logged "^elev"'
        check "prerequisites present: install.sh ran" 'logged "install.sh ran"'
        check "Linux: says brew goes at the end of PATH and how to change it" 'out_has "end of PATH on Linux" && out_has "WORKBENCH_BREW_PATH=front"'
        check "Linux: no Tier 3 warning" '! out_has "Tier 3"'
        ;;
    script-fails)
        install-brew >"${INST}" 2>&1; rc=$?
        check "install.sh failure: refused" '[ ${rc} -ne 0 ]'
        ;;
    script-no-tty)
        install-brew >"${INST}" 2>&1; rc=$?
        check "install.sh needs a terminal: refused" '[ ${rc} -ne 0 ] && out_has "needs a terminal"'
        check "install.sh needs a terminal: not downloaded" '! logged "^download"'
        ;;
    script-no-brew)
        install-brew >"${INST}" 2>&1; rc=$?
        check "installer finished with no brew anywhere: fails and says so" '[ ${rc} -ne 0 ] && out_has "no brew was found"'
        ;;

    # ── macOS ───────────────────────────────────────────────────────────────
    mac-pkg)
        install-brew >"${INST}" 2>&1; rc=$?
        check ".pkg: succeeds" '[ ${rc} -eq 0 ]'
        check ".pkg: read the releases API" 'logged "^curl -fsS fake://releases$"'
        check ".pkg: fetched with GitHub's digest" 'logged "^fetch_verified ${PKG_URL} ${DIGEST}$"'
        check ".pkg: signature, then Gatekeeper" 'line_before "^pkgutil --check-signature" "^spctl --assess --type install"'
        check ".pkg: installer -pkg <tmp>/Homebrew.pkg -target /" 'logged "^installer -pkg .*/Homebrew.pkg -target /$"'
        check ".pkg: installer ran elevated, after the checks" 'logged "^elev installer" && line_before "^spctl" "^elev installer"'
        check ".pkg: install.sh was not used" '! logged "install.sh"'
        check ".pkg: no Tier 3 warning" '! out_has "Tier 3"'
        ;;
    mac-pkg-refused)
        install-brew >"${INST}" 2>&1; rc=$?
        check "refused: non-zero" '[ ${rc} -ne 0 ]'
        check "refused: installer never called" '! logged "installer"'
        check "refused: install.sh never used" '! logged "install.sh"'
        ;;
    mac-pkg-wrong-team)
        install-brew >"${INST}" 2>&1; rc=$?
        check "wrong Team ID: refused, naming the expected one" '[ ${rc} -ne 0 ] && out_has "927JGANW46"'
        check "wrong Team ID: installer never called" '! logged "installer"'
        ;;
    mac-script)
        install-brew >"${INST}" 2>&1; rc=$?
        check "install.sh route: succeeds" '[ ${rc} -eq 0 ]'
        check "install.sh route: warns about Tier 3" 'out_has "WARN: brew: Homebrew supports macOS before 15 at Tier 3 only"'
        check "install.sh route: install.sh ran" 'logged "install.sh ran"'
        check "install.sh route: no .pkg, no installer" '! logged "installer" && ! logged "pkgutil"'
        ;;
    mac-intel)
        install-brew >"${INST}" 2>&1; rc=$?
        check "Intel Mac: refused" '[ ${rc} -ne 0 ]'
        check "Intel Mac: gives Homebrew's reason" 'out_has "only supported on Apple Silicon processors"'
        check "Intel Mac: nothing installed or downloaded" '! logged "installer" && ! logged "install.sh" && ! logged "^download" && ! logged "^curl"'
        ;;
    mac-clt-warning)
        install-brew >"${INST}" 2>&1; rc=$?
        check "no Command Line Tools: still succeeds" '[ ${rc} -eq 0 ]'
        check "no Command Line Tools: warns and names xcode-select --install" 'out_has "xcode-select --install"'
        ;;
    mac-10)
        install-brew >"${INST}" 2>&1; rc=$?
        check "macOS 10: refused" '[ ${rc} -ne 0 ] && out_has "no longer runs on macOS 10"'
        check "macOS 10: nothing installed" '! logged "installer" && ! logged "install.sh" && ! logged "^download"'
        ;;

    # ── PATH in this process after an install ───────────────────────────────
    path-after)
        install-brew >"${INST}" 2>&1; rc=$?
        check "after install: succeeds" '[ ${rc} -eq 0 ]'
        case "${EXPECT_PATH}" in
            end)   check "after install: bin and sbin at the end of PATH" '[ "${PATH}" = "${START_PATH}:${HOME}/prefix/bin:${HOME}/prefix/sbin" ]' ;;
            front) check "after install: bin and sbin at the front of PATH" '[ "${PATH}" = "${HOME}/prefix/bin:${HOME}/prefix/sbin:${START_PATH}" ]' ;;
            off)   check "after install: WORKBENCH_BREW_PATH=off leaves PATH alone" '[ "${PATH}" = "${START_PATH}" ]' ;;
        esac
        ;;
    path-already)
        make_brew
        PATH="${HOME}/mid:${HOME}/prefix/bin:${PATH}"
        before="${PATH}"
        _brew_activate_here "${HOME}/prefix/bin/brew"
        check "a prefix already on PATH is not moved or repeated" '[ "${PATH}" = "${before}" ]'
        check "...and HOMEBREW_PREFIX is exported" '[ "${HOMEBREW_PREFIX}" = "${HOME}/prefix" ]'
        ;;

    # ── Constants ───────────────────────────────────────────────────────────
    team-id)
        check "_BREW_PKG_TEAM_ID is ten capitals and digits" 'printf "%s" "${_BREW_PKG_TEAM_ID}" | grep -Eq "^[A-Z0-9]{10}$"'
        check "_BREW_PKG_TEAM_ID is the confirmed 27 Nov 2026 value" '[ "${_BREW_PKG_TEAM_ID}" = "927JGANW46" ]'
        ;;

    # ── brew-update ─────────────────────────────────────────────────────────
    update-root)
        brew-update; rc=$?
        check "root: refused" '[ ${rc} -ne 0 ]'
        check "root: says so" 'out_has "don.t run Homebrew as root"'
        check "root: nothing ran" 'ran_nothing'
        ;;
    update-no-brew)
        brew-update; rc=$?
        check "no brew: refused" '[ ${rc} -ne 0 ]'
        check "no brew: names wb tools install brew" 'out_has "wb tools install brew"'
        ;;
    update-default)
        brew-update; rc=$?
        check "default: succeeds" '[ ${rc} -eq 0 ]'
        check "default: brew update, then brew upgrade" 'logged "^brew update$" && logged "^brew upgrade$" && line_before "^brew update$" "^brew upgrade$"'
        check "default: no --greedy, no cleanup" '! logged "greedy" && ! logged "cleanup"'
        ;;
    update-greedy)
        brew-update --greedy; rc=$?
        check "--greedy: brew upgrade --greedy" '[ ${rc} -eq 0 ] && logged "^brew upgrade --greedy$"'
        ;;
    update-cleanup)
        brew-update --cleanup; rc=$?
        check "--cleanup: brew cleanup after the upgrade" '[ ${rc} -eq 0 ] && line_before "^brew upgrade$" "^brew cleanup$"'
        ;;
    update-cleanup-fails)
        brew-update --cleanup; rc=$?
        check "cleanup failure: warns" 'out_has "WARN: brew-update: brew cleanup failed"'
        check "cleanup failure: the packages were upgraded, so still succeeds" '[ ${rc} -eq 0 ]'
        ;;
    update-fails)
        brew-update; rc=$?
        check "brew update fails: its status comes back" '[ ${rc} -ne 0 ]'
        check "brew update fails: no upgrade" '! logged "^brew upgrade"'
        ;;
    update-bad-option)
        brew-update --bogus 2>/dev/null; rc=$?
        check "unknown option: exit 2" '[ ${rc} -eq 2 ]'
        check "unknown option: nothing ran" 'ran_nothing'
        ;;
    update-help)
        brew-update --help >"${INST}"; rc=$?
        check "--help: exit 0, usage, nothing ran" '[ ${rc} -eq 0 ] && grep -q "^Usage: brew-update" "${INST}" && ran_nothing'
        ;;

    # ── distro-update, Linux ────────────────────────────────────────────────
    du-linux)
        distro-update; rc=$?
        check "Linux: succeeds" '[ ${rc} -eq 0 ]'
        check "Linux: order is the family updater, Flatpak, then Homebrew" 'line_before "^dnf upgrade" "^flatpak update" && line_before "^flatpak update" "^brew update$" && line_before "^brew update$" "^brew upgrade$"'
        ;;
    du-no-brew-flag)
        distro-update --no-brew; rc=$?
        check "--no-brew: succeeds, Homebrew never called" '[ ${rc} -eq 0 ] && ! logged "^brew" && logged "^flatpak update"'
        ;;
    du-brew-absent)
        distro-update; rc=$?
        check "no brew installed: succeeds without it" '[ ${rc} -eq 0 ] && ! logged "^brew" && ! out_has "brew"'
        ;;
    du-brew-fails)
        distro-update; rc=$?
        check "brew failure: packages were updated, so exit 0" '[ ${rc} -eq 0 ]'
        check "brew failure: warns" 'out_has "WARN: distro-update: Homebrew update failed"'
        ;;
    du-brew-not-loaded)
        distro-update; rc=$?
        check "brew present, brew-update not loaded: warns, exit 0" '[ ${rc} -eq 0 ] && out_has "brew-update isn.t loaded"'
        ;;
    du-help)
        distro-update --help >"${INST}"
        check "--help documents --no-brew and macOS" 'grep -q -- "--no-brew" "${INST}" && grep -q "^macOS:" "${INST}"'
        ;;

    # ── distro-update, macOS ────────────────────────────────────────────────
    du-mac)
        distro-update; rc=$?
        check "macOS: succeeds" '[ ${rc} -eq 0 ]'
        check "macOS: brew update and upgrade" 'logged "^brew update$" && logged "^brew upgrade$"'
        check "macOS: no Linux updater, no Flatpak" '! logged "^dnf" && ! logged "^flatpak" && ! logged "^elev"'
        check "macOS: says where macOS updates itself" 'out_has "Software Update"'
        ;;
    du-mac-no-brew)
        distro-update; rc=$?
        check "macOS without brew: exit 1" '[ ${rc} -eq 1 ]'
        check "macOS without brew: names wb tools install brew" 'out_has "wb tools install brew"'
        ;;
    du-mac-no-brew-flag)
        distro-update --no-brew; rc=$?
        check "macOS --no-brew: exit 0 with the message" '[ ${rc} -eq 0 ] && out_has "nothing to update on macOS" && ran_nothing'
        ;;
    du-mac-fails)
        distro-update; rc=$?
        check "macOS, Homebrew fails: that is the exit status" '[ ${rc} -ne 0 ]'
        ;;

    # ── Availability ────────────────────────────────────────────────────────
    availability)
        : > "${HOME}/avail.log"
        _wb_alias_availability() { echo "alias $*" >> "${HOME}/avail.log"; }
        _wb_declare_availability() { echo "declare $*" >> "${HOME}/avail.log"; }
        . "${R}/shell/distro.sh"
        . "${R}/shell/brew.sh"
        check "distro-upgrade, -reboot-required and -info still need a Linux distribution" 'grep -q "_distro_supported distro-upgrade distro-reboot-required distro-info$" "${HOME}/avail.log"'
        check "distro-update is no longer in that Linux-only group" '! grep "_distro_supported " "${HOME}/avail.log" | grep -q "distro-update"'
        check "distro-update has its own check, naming Linux or macOS" 'grep -q "or macOS _distro_update_supported distro-update$" "${HOME}/avail.log"'
        check "brew-update is declared on the brew command" 'grep -q "^declare brew brew-update$" "${HOME}/avail.log"'
        WORKBENCH_OS=Mac WORKBENCH_DISTRO=unknown; _distro_update_supported; mac=$?
        WORKBENCH_OS=Linux WORKBENCH_DISTRO=unknown; _distro_update_supported; unknown=$?
        WORKBENCH_OS=Linux WORKBENCH_DISTRO=debian; _distro_update_supported; debian=$?
        check "distro-update is available on macOS" '[ ${mac} -eq 0 ]'
        check "distro-update is available on a supported Linux" '[ ${debian} -eq 0 ]'
        check "distro-update is not available on an unknown Linux" '[ ${unknown} -ne 0 ]'
        WORKBENCH_OS=Mac; _distro_supported; mac_supported=$?
        check "distro-upgrade's check is still false on macOS" '[ ${mac_supported} -ne 0 ]'
        ;;

    # ── Shell start stays silent ────────────────────────────────────────────
    silent)
        bad=""
        for f in shell/brew.sh shell/distro.sh; do
            printed="$(. "${R}/${f}" 2>&1)"
            [ -z "${printed}" ] || bad="${bad} ${f}"
        done
        check "sourcing brew.sh and distro.sh prints nothing${bad:+ (printed:${bad})}" '[ -z "${bad}" ]'
        ;;
    silent-installer)
        printed="$(. "${R}/shell/installers-brew.sh" 2>&1)"
        check "sourcing installers-brew.sh prints nothing" '[ -z "${printed}" ]'
        ;;
esac
EOF

NO_OSTREE="_DISTRO_OSTREE_MARKER=${WORK}/does-not-exist"
FEDORA="WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora"
NOT_ROOT="_BREW_TEST_EUID=1000"

# run_inst <scenario> [label-prefix] [VAR=value ...] — an installer scenario,
# bash only, with a prefix candidate and a terminal inside the scenario's HOME.
run_inst() {
    local name="$1" prefix="$2"
    shift 2
    # Fresh HOME each time: an earlier run of this scenario may have left a brew.
    rm -rf "${WORK}/home-bash-${name}"
    report_scenario bash "${prefix}" "$(run_scenario bash "${WORK}/scenario.sh" "${name}" \
        FILES="shell/installers-brew.sh" \
        _BREW_PREFIX_CANDIDATES="${WORK}/home-bash-${name}/prefix" \
        _BREW_TTY="${WORK}/tty" _BREW_RELEASES_API="fake://releases" \
        _BREW_INSTALL_SH_URL="fake://install.sh" INSTALL_SH_SRC="${FIX}/install.sh" \
        PKG_URL="${PKG_URL}" DIGEST="${DIGEST}" \
        "$@")"
}

# run_fn <shell> <scenario> <files> [VAR=value ...] — a shell-function scenario.
run_fn() {
    local shell="$1" name="$2" files="$3"
    shift 3
    report_scenario "${shell}" "" "$(run_scenario "${shell}" "${WORK}/scenario.sh" "${name}" FILES="${files}" "$@")"
}

LINUX="WORKBENCH_OS=Linux WORKBENCH_ARCH=x86_64"
MAC="WORKBENCH_OS=Mac"
NO_TOOLS="gcc make curl file git ps"

# shellcheck disable=SC2086  # the *_ENV words are VAR=value lists on purpose
{
    # 1. installed-brew (+ the stale prefix case)
    run_inst find "" ${LINUX}

    # 2. root
    run_inst root "" ${LINUX} _BREW_TEST_EUID=0

    # 3. already installed
    run_inst present "" ${LINUX} ${NOT_ROOT} PRESENT=1
    run_inst present-fails "" ${LINUX} ${NOT_ROOT} PRESENT=1 FAIL_ON='^brew update'

    # 4. Linux architecture
    run_inst linux-arch "" WORKBENCH_OS=Linux WORKBENCH_ARCH=armv7l ${NOT_ROOT}

    # 5. prerequisites, per family
    run_inst prereq-report "debian: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu ANSWER=n WITHOUT="${NO_TOOLS}" EXPECT_FAMILY=debian
    run_inst prereq-report "fedora: " ${LINUX} ${NOT_ROOT} ${FEDORA} ANSWER=n WITHOUT="${NO_TOOLS}" EXPECT_FAMILY=fedora
    run_inst prereq-report "rocky: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=rocky ANSWER=n WITHOUT="${NO_TOOLS}" EXPECT_FAMILY=rocky
    run_inst prereq-report "arch: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch ANSWER=n WITHOUT="${NO_TOOLS}" EXPECT_FAMILY=arch
    run_inst prereq-report "suse: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap ANSWER=n WITHOUT="${NO_TOOLS}" EXPECT_FAMILY=suse
    run_inst prereq-unknown "" ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=unknown WORKBENCH_DISTRO_ID=unknown WITHOUT="${NO_TOOLS}"

    # 6. no terminal
    run_inst prereq-no-tty "" ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian WITHOUT="${NO_TOOLS}" _BREW_TTY="${WORK}/no-such-tty"

    # 7. answer y: run each line elevated, re-check, then install.sh
    run_inst prereq-yes "" ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian ANSWER=y WITHOUT="${NO_TOOLS}"

    # 8. still missing afterwards
    run_inst prereq-still-missing "" ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian ANSWER=y PREREQ_PROVIDE=no WITHOUT="${NO_TOOLS}"

    # Linux with the prerequisites already there: install.sh only
    run_inst linux-script "" ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian
    run_inst script-fails "" ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian INSTALL_SH_FAIL=1
    run_inst script-fails "download fails: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian DL_FAIL=1
    run_inst script-no-tty "" ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian _BREW_TTY="${WORK}/no-such-tty"

    # 9. macOS, Apple Silicon, 15+: the .pkg
    run_inst mac-pkg "" ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} SW_VERS=15.1 API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-ok.txt"
    run_inst mac-pkg "macOS 26: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} SW_VERS=26.1 API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-ok.txt"

    # 10. every way the .pkg is refused
    run_inst mac-pkg-refused "no .pkg asset: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-no-pkg.json" PKGUTIL_OUT="${FIX}/sig-ok.txt"
    run_inst mac-pkg-refused "null digest: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-null-digest.json" PKGUTIL_OUT="${FIX}/sig-ok.txt"
    run_inst mac-pkg-refused "digest mismatch: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-ok.txt" FETCH_FAIL=1
    run_inst mac-pkg-refused "unsigned: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-none.txt" PKGUTIL_RC=1
    run_inst mac-pkg-refused "not a Developer ID certificate: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-not-developer-id.txt"
    run_inst mac-pkg-wrong-team "" ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-wrong-team.txt"
    run_inst mac-pkg-refused "Gatekeeper rejects it: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-ok.txt" FAIL_ON='^spctl'
    run_inst mac-pkg-refused "releases API unreadable: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-ok.txt" FAIL_ON='^curl'

    # 11. Apple Silicon on 11-14: install.sh with a warning. Intel: refused,
    #     because install.sh itself stops there.
    run_inst mac-script "arm64 on 14: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} SW_VERS=14.7
    run_inst mac-script "arm64 on 11: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} SW_VERS=11.7
    run_inst mac-intel "on 15: " ${MAC} WORKBENCH_ARCH=x86_64 ${NOT_ROOT} SW_VERS=15.1
    run_inst mac-intel "on 13: " ${MAC} WORKBENCH_ARCH=x86_64 ${NOT_ROOT} SW_VERS=13.6
    run_inst mac-clt-warning "" ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} SW_VERS=14.7 FAIL_ON='^xcode-select'

    # 12. macOS 10
    run_inst mac-10 "" ${MAC} WORKBENCH_ARCH=x86_64 ${NOT_ROOT} SW_VERS=10.15.7

    # 13. PATH after an install
    run_inst path-after "Linux: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian EXPECT_PATH=end
    run_inst path-after "Linux, front: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian WORKBENCH_BREW_PATH=front EXPECT_PATH=front
    run_inst path-after "Linux, off: " ${LINUX} ${NOT_ROOT} WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian WORKBENCH_BREW_PATH=off EXPECT_PATH=off
    run_inst path-after "macOS: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} SW_VERS=15.1 API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-ok.txt" EXPECT_PATH=front
    run_inst path-after "macOS, end: " ${MAC} WORKBENCH_ARCH=arm64 ${NOT_ROOT} SW_VERS=15.1 API_FILE="${FIX}/api-ok.json" PKGUTIL_OUT="${FIX}/sig-ok.txt" WORKBENCH_BREW_PATH=end EXPECT_PATH=end
    run_inst path-already "" ${LINUX} ${NOT_ROOT}

    # 14. the pinned Team ID
    run_inst team-id ""

    # Installer file sourced on its own prints nothing
    run_inst silent-installer ""
}

# 15-19: brew-update, distro-update, availability, silent sourcing.
RHEL_FILES="shell/distro.sh shell/brew.sh shell/distro/rhel.sh shell/distro/fedora.sh"
RHEL_NO_BREW_FILES="shell/distro.sh shell/distro/rhel.sh shell/distro/fedora.sh"
for shell in $(test_shells); do
    # shellcheck disable=SC2086
    {
        run_fn "${shell}" update-root "shell/brew.sh" _BREW_TEST_EUID=0
        run_fn "${shell}" update-no-brew "shell/brew.sh" ${NOT_ROOT} WITHOUT=brew
        run_fn "${shell}" update-default "shell/brew.sh" ${NOT_ROOT}
        run_fn "${shell}" update-greedy "shell/brew.sh" ${NOT_ROOT}
        run_fn "${shell}" update-cleanup "shell/brew.sh" ${NOT_ROOT}
        run_fn "${shell}" update-cleanup-fails "shell/brew.sh" ${NOT_ROOT} FAIL_ON='^brew cleanup'
        run_fn "${shell}" update-fails "shell/brew.sh" ${NOT_ROOT} FAIL_ON='^brew update'
        run_fn "${shell}" update-bad-option "shell/brew.sh" ${NOT_ROOT}
        run_fn "${shell}" update-help "shell/brew.sh" ${NOT_ROOT}

        run_fn "${shell}" du-linux "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} ${NOT_ROOT}
        run_fn "${shell}" du-no-brew-flag "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} ${NOT_ROOT}
        run_fn "${shell}" du-brew-absent "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} ${NOT_ROOT} WITHOUT=brew
        run_fn "${shell}" du-brew-fails "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} ${NOT_ROOT} FAIL_ON='^brew update'
        run_fn "${shell}" du-brew-not-loaded "${RHEL_NO_BREW_FILES}" ${FEDORA} ${NO_OSTREE} ${NOT_ROOT}
        run_fn "${shell}" du-help "${RHEL_FILES}" ${FEDORA}

        run_fn "${shell}" du-mac "${RHEL_FILES}" ${MAC} WORKBENCH_DISTRO=unknown ${NOT_ROOT}
        run_fn "${shell}" du-mac-no-brew "${RHEL_FILES}" ${MAC} WORKBENCH_DISTRO=unknown ${NOT_ROOT} WITHOUT=brew
        run_fn "${shell}" du-mac-no-brew-flag "${RHEL_FILES}" ${MAC} WORKBENCH_DISTRO=unknown ${NOT_ROOT} WITHOUT=brew
        run_fn "${shell}" du-mac-fails "${RHEL_FILES}" ${MAC} WORKBENCH_DISTRO=unknown ${NOT_ROOT} FAIL_ON='^brew update'

        run_fn "${shell}" availability ""
        run_fn "${shell}" silent ""
    }
done

# The manifest registers both files, and asks for the core that puts brew on PATH.
if grep -q 'src: shell/brew.sh' "${REPO_ROOT}/workbench.yml" && grep -q 'src: shell/installers-brew.sh' "${REPO_ROOT}/workbench.yml"; then
    ok "manifest: shell/brew.sh and shell/installers-brew.sh are registered"
else
    fail "manifest: shell/brew.sh or shell/installers-brew.sh is missing from workbench.yml"
fi
if grep -Eq '^core_api: ">=1\.(1[4-9]|[2-9][0-9]) <2\.0"' "${REPO_ROOT}/workbench.yml"; then
    ok "manifest: core_api needs 1.14 or later"
else
    fail "manifest: core_api doesn't need 1.14 or later"
fi

finish
