#!/usr/bin/env bash
# tests/check-release-upgrades.sh — workbench-distro
# debian-release-upgrade, ubuntu-release-upgrade, pop-release-upgrade and
# opensuse-release-upgrade. Fedora's has its own suite. Plain bash, numbered
# OK:/FAIL: checks, every external tool a fake that logs its arguments, each
# scenario in bash and, when installed, zsh.
#
#   - debian: refused on Ubuntu/Pop, for a skipped release, a release that
#     isn't stable yet, in a container, without a terminal or without curl;
#     preflight stops on a pending reboot, broken or held packages; the happy
#     path rewrites only official entries, backs up first, runs the three apt
#     steps in order; a failed step restores nothing; no typed word, no change;
#   - ubuntu: only the offered release, Prompt= explained when none is offered;
#   - pop: the recovery step, the typed words;
#   - openSUSE Leap: the migration tool, --dry-run needs no confirmation.
set -uo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib/harness.sh"

fake apt-get
fake apt 'echo "(obsolete package list)"'
fake dpkg 'case "$*" in "--audit") [ -n "${DPKG_AUDIT:-}" ] && printf "%s\n" "${DPKG_AUDIT}" ;; esac'
fake apt-mark 'case "$*" in showhold) [ -n "${HOLDS:-}" ] && printf "%s\n" "${HOLDS}" ;; esac'
fake curl 'case "${CURL_SUITE:-stable}" in none) exit 22 ;; *) printf "Origin: Debian\nSuite: %s\nCodename: trixie\n" "${CURL_SUITE:-stable}" ;; esac'
fake install 'last=""; second=""
for a in "$@"; do second="${last}"; last="${a}"; done
if [ "$1" = "-d" ]; then mkdir -p "${last}"; else cp "${second}" "${last}"; fi'
fake systemd-detect-virt 'exit "${SDV_RC:-1}"'
fake do-release-upgrade 'case "$1" in -c) printf "%s\n" "${DRU_CHECK:-No new release found.}" ;; esac'
fake pop-upgrade
fake zypper
fake opensuse-migration-tool

cat > "${WORK}/scenario.sh" <<'EOF'
. "${REPO_ROOT}/tests/lib/prelude.sh"

_DISTRO_APT_DIR="${HOME}/apt"
_DISTRO_BACKUP_ROOT="${HOME}/backups"
_DISTRO_REBOOT_REQUIRED_FILE="${HOME}/reboot-required"
_DISTRO_UBUNTU_RELEASE_UPGRADES="${HOME}/release-upgrades"
printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "${HOME}/os-release"
_DISTRO_OS_RELEASE="${HOME}/os-release"

make_sources() {
    mkdir -p "${_DISTRO_APT_DIR}/sources.list.d"
    cat > "${_DISTRO_APT_DIR}/sources.list" <<'S'
deb http://deb.debian.org/debian bookworm main
deb http://security.debian.org/debian-security bookworm-security main
S
    printf 'deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable\n' \
        > "${_DISTRO_APT_DIR}/sources.list.d/docker.list"
}
make_sources
SOURCES_BEFORE="$(cat "${_DISTRO_APT_DIR}/sources.list" "${_DISTRO_APT_DIR}/sources.list.d/docker.list")"
sources_unchanged() {
    [ "$(cat "${_DISTRO_APT_DIR}/sources.list" "${_DISTRO_APT_DIR}/sources.list.d/docker.list")" = "${SOURCES_BEFORE}" ]
}
# ran_nothing: nothing but the probes (container and DNF detection) was called
ran_nothing() { ! grep -Eqv "^(systemd-detect-virt|readlink)" "${LOG}"; }
no_backup() { [ ! -d "${_DISTRO_BACKUP_ROOT}" ] || [ -z "$(ls "${_DISTRO_BACKUP_ROOT}")" ]; }
backup_dir() { find "${_DISTRO_BACKUP_ROOT}" -maxdepth 1 -type d -name 'apt-sources-bookworm-to-trixie-*' 2>/dev/null | head -n 1; }

case "${SCENARIO}" in
    # ── debian: refusals ────────────────────────────────────────────────────
    deb-not-debian)
        WORKBENCH_DISTRO_ID=ubuntu debian-release-upgrade trixie; r1=$?
        check "ubuntu: refused, names ubuntu-release-upgrade" '[ ${r1} -eq 1 ] && out_has "ubuntu-release-upgrade"'
        : > "${OUT}"
        WORKBENCH_DISTRO_ID=pop debian-release-upgrade trixie; r2=$?
        check "pop: refused, names pop-release-upgrade" '[ ${r2} -eq 1 ] && out_has "pop-release-upgrade"'
        check "refused: nothing ran" 'ran_nothing && sources_unchanged'
        ;;
    deb-arguments)
        debian-release-upgrade; r1=$?
        debian-release-upgrade --bogus trixie; r2=$?
        debian-release-upgrade trixie forky; r3=$?
        debian-release-upgrade sid; r4=$?
        check "no target: exit 2" '[ ${r1} -eq 2 ]'
        check "unknown option: exit 2" '[ ${r2} -eq 2 ]'
        check "two targets: exit 2" '[ ${r3} -eq 2 ]'
        check "a release the table doesn't know: exit 2" '[ ${r4} -eq 2 ]'
        check "arguments refused before anything ran" 'ran_nothing'
        ;;
    deb-skip)
        debian-release-upgrade forky; r1=$?
        debian-release-upgrade 12; r2=$?
        check "skipping a release (bookworm to forky): exit 2, names trixie" '[ ${r1} -eq 2 ] && out_has "skipping releases" && out_has "trixie"'
        check "staying on the same release: exit 2" '[ ${r2} -eq 2 ]'
        check "skip refused before anything ran" 'ran_nothing'
        ;;
    deb-number-target)
        debian-release-upgrade 13; rc=$?
        check "the release number works as a target" 'logged "^curl .*dists/trixie/Release"'
        ;;
    deb-unknown-current)
        printf 'ID=debian\nVERSION_CODENAME=sid\n' > "${_DISTRO_OS_RELEASE}"
        _DISTRO_DEBIAN_VERSION_FILE="${HOME}/debian_version"
        printf 'trixie/sid\n' > "${_DISTRO_DEBIAN_VERSION_FILE}"
        debian-release-upgrade trixie; rc=$?
        check "testing/sid: refused" '[ ${rc} -eq 1 ] && out_has "testing and sid aren.t handled" && ran_nothing'
        ;;
    deb-version-file-fallback)
        printf 'ID=debian\n' > "${_DISTRO_OS_RELEASE}"
        _DISTRO_DEBIAN_VERSION_FILE="${HOME}/debian_version"
        printf '12.9\n' > "${_DISTRO_DEBIAN_VERSION_FILE}"
        debian-release-upgrade trixie; rc=$?
        check "no codename in os-release: the major of /etc/debian_version is used" 'logged "^curl .*dists/trixie/Release"'
        ;;
    deb-container)
        debian-release-upgrade trixie; rc=$?
        check "container: refused" '[ ${rc} -eq 1 ] && out_has "this is a container" && ran_nothing'
        ;;
    deb-no-tty)
        debian-release-upgrade trixie; rc=$?
        check "no terminal: refused before anything ran" '[ ${rc} -eq 1 ] && out_has "needs a terminal" && ran_nothing'
        ;;
    deb-no-curl)
        debian-release-upgrade trixie; rc=$?
        check "no curl: refused, says why" '[ ${rc} -eq 1 ] && out_has "curl is needed" && ! logged "^apt-get"'
        ;;
    deb-not-stable)
        debian-release-upgrade trixie; rc=$?
        check "target Suite is testing: refused" '[ ${rc} -eq 1 ] && out_has "isn.t the stable release yet"'
        check "target not released: nothing changed" '! logged "^apt-get" && sources_unchanged && no_backup'
        ;;
    deb-curl-fails)
        debian-release-upgrade trixie; rc=$?
        check "Release file unreachable: refused, doesn't guess" '[ ${rc} -eq 1 ] && out_has "couldn.t fetch" && ! logged "^apt-get"'
        ;;
    deb-fetches-official-archive)
        debian-release-upgrade trixie
        check "the Release file comes from the official archive, not the third-party repo" 'logged "^curl -fsSL http://deb.debian.org/debian/dists/trixie/Release$"'
        ;;
    deb-ssh-warning)
        debian-release-upgrade trixie
        check "ssh outside tmux: warned" 'out_has "SSH session outside tmux"'
        : > "${OUT}"
        TMUX=/tmp/tmux-1 debian-release-upgrade trixie
        check "ssh inside tmux: not warned" '! out_has "SSH session outside tmux"'
        ;;

    # ── debian: preflight ───────────────────────────────────────────────────
    deb-preflight-reboot)
        : > "${_DISTRO_REBOOT_REQUIRED_FILE}"
        debian-release-upgrade trixie; rc=$?
        check "pending reboot: stops" '[ ${rc} -eq 1 ] && out_has "reboot is pending"'
        check "pending reboot: sources untouched, nothing backed up" 'sources_unchanged && no_backup'
        ;;
    deb-preflight-dpkg)
        debian-release-upgrade trixie 2>> "${OUT}"; rc=$?
        check "dpkg --audit output: stops and lists it" '[ ${rc} -eq 1 ] && out_has "bad state" && out_has "half-configured"'
        check "dpkg problems: sources untouched" 'sources_unchanged && no_backup'
        ;;
    deb-preflight-holds)
        debian-release-upgrade trixie 2>> "${OUT}"; rc=$?
        check "held packages: stops and lists them" '[ ${rc} -eq 1 ] && out_has "held back" && out_has "linux-image-amd64"'
        check "held packages: sources untouched" 'sources_unchanged && no_backup'
        ;;
    deb-preflight-update-fails)
        debian-release-upgrade trixie; rc=$?
        check "preflight apt-get update fails: stops" '[ ${rc} -eq 1 ] && sources_unchanged'
        ;;

    # ── debian: the upgrade ─────────────────────────────────────────────────
    deb-happy)
        debian-release-upgrade trixie; rc=$?
        bk="$(backup_dir)"
        check "happy path: succeeds" '[ ${rc} -eq 0 ]'
        check "official entries moved to trixie" 'grep -q "^deb http://deb.debian.org/debian trixie main$" "${_DISTRO_APT_DIR}/sources.list" && grep -q "bookworm" "${_DISTRO_APT_DIR}/sources.list" || ! grep -q bookworm "${_DISTRO_APT_DIR}/sources.list"'
        check "the security entry moved to trixie-security" 'grep -q "debian-security trixie-security main" "${_DISTRO_APT_DIR}/sources.list"'
        check "the third-party entry is unchanged" 'grep -q "download.docker.com/linux/debian bookworm stable" "${_DISTRO_APT_DIR}/sources.list.d/docker.list"'
        check "third-party entry reported, not rewritten" 'out_has "Third-party entry names bookworm"'
        check "backup directory named with both releases and a UTC stamp" '[ -n "${bk}" ] && case "${bk}" in *apt-sources-bookworm-to-trixie-[0-9]*Z) true ;; *) false ;; esac'
        check "backup holds the original sources.list" 'grep -q "bookworm main" "${bk}/sources.list"'
        check "backup is not inside sources.list.d" '[ ! -e "${_DISTRO_APT_DIR}/sources.list.d/RESTORE.txt" ] && [ ! -d "${_DISTRO_APT_DIR}/sources.list.d/apt-sources-bookworm-to-trixie" ]'
        check "RESTORE.txt holds the exact cp commands" 'grep -q "^cp -p .${bk}/sources.list. .${_DISTRO_APT_DIR}/sources.list.$" "${bk}/RESTORE.txt"'
        check "files installed root-owned with their own mode" 'logged "^install -m [0-7]* -o root -g root .*sources.list "'
        check "apt steps in order: update, minimal upgrade, full-upgrade" 'line_before "^apt-get update$" "^apt-get upgrade$" && line_before "^apt-get upgrade$" "^apt-get full-upgrade$"'
        check "release steps are interactive (no -y)" '! grep -q "^apt-get full-upgrade -y" "${LOG}" && ! grep -q "^apt-get upgrade --without" "${LOG}"'
        check "backup is made before the sources are replaced" 'line_before "^elev cp -p" "^install -m [0-7]* -o root -g root"'
        check "autoremove is interactive and last of the apt calls" '[ "$(grep "^apt-get " "${LOG}" | tail -n 1)" = "apt-get autoremove" ]'
        check "obsolete packages listed with the documented pattern" 'logged "^apt list .obsolete"'
        check "says to reboot" 'out_has "Debian 13 (trixie) is installed"'
        ;;
    deb-disable-third-party)
        debian-release-upgrade trixie --disable-third-party; rc=$?
        check "--disable-third-party: succeeds" '[ ${rc} -eq 0 ]'
        check "the docker entry is commented out, not rewritten" 'grep -q "^# disabled by workbench-distro (bookworm.*trixie): deb .arch=amd64. https://download.docker.com/linux/debian bookworm stable$" "${_DISTRO_APT_DIR}/sources.list.d/docker.list"'
        ;;
    deb-no-confirm)
        debian-release-upgrade trixie; rc=$?
        check "anything but 'upgrade': exit 0, nothing changed" '[ ${rc} -eq 0 ] && sources_unchanged && no_backup'
        check "no confirmation: only the preflight apt calls ran" '! logged "full-upgrade"'
        check "the diff was shown before asking" 'out_has "Type .upgrade. to continue"'
        ;;
    deb-fails-midway)
        debian-release-upgrade trixie; rc=$?
        check "a failed step: exit 1" '[ ${rc} -eq 1 ]'
        check "a failed step: the old sources are NOT restored" 'grep -q "trixie main" "${_DISTRO_APT_DIR}/sources.list"'
        check "a failed step: says how to resume" 'out_has "apt-get -f install" && out_has "apt-get full-upgrade"'
        check "a failed step: points at the restore commands" 'out_has "RESTORE.txt"'
        ;;
    deb-deb822-only)
        # Debian 12 and later can have only .sources files: no sources.list
        # entries and no *.list at all. An unmatched glob is an error in zsh.
        rm -f "${_DISTRO_APT_DIR}/sources.list" "${_DISTRO_APT_DIR}/sources.list.d/docker.list"
        cat > "${_DISTRO_APT_DIR}/sources.list.d/debian.sources" <<'S'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
S
        debian-release-upgrade trixie; rc=$?
        check "only a .sources file: succeeds" '[ ${rc} -eq 0 ]'
        check "only a .sources file: both suites moved" 'grep -q "^Suites: trixie trixie-updates$" "${_DISTRO_APT_DIR}/sources.list.d/debian.sources"'
        check "only a .sources file: backed up under its relative path" '[ -f "$(backup_dir)/sources.list.d/debian.sources" ]'
        ;;
    deb-nothing-to-rewrite)
        printf 'deb http://deb.debian.org/debian trixie main\n' > "${_DISTRO_APT_DIR}/sources.list"
        rm -f "${_DISTRO_APT_DIR}/sources.list.d/docker.list"
        debian-release-upgrade trixie; rc=$?
        check "no official entry names the old release: refused" '[ ${rc} -eq 1 ] && out_has "nothing to rewrite"'
        check "nothing to rewrite: no backup" 'no_backup'
        ;;

    # ── ubuntu ──────────────────────────────────────────────────────────────
    ubuntu-offered)
        ubuntu-release-upgrade 26.04; rc=$?
        check "ubuntu: succeeds" '[ ${rc} -eq 0 ]'
        check "ubuntu: brought up to date first" 'line_before "^apt-get update$" "^apt-get full-upgrade -y$"'
        check "ubuntu: do-release-upgrade runs interactively, after the check" 'line_before "^do-release-upgrade -c$" "^do-release-upgrade$" && ! logged "DistUpgradeViewNonInteractive"'
        check "ubuntu: the release step goes through the elevation command" 'logged "^elev do-release-upgrade$"'
        ;;
    ubuntu-no-version)
        ubuntu-release-upgrade; rc=$?
        check "ubuntu without a version: upgrades to the offered release" '[ ${rc} -eq 0 ] && logged "^do-release-upgrade$"'
        ;;
    ubuntu-wrong-version)
        ubuntu-release-upgrade 25.10; rc=$?
        check "ubuntu, a version that isn't offered: refused, names the offered one" '[ ${rc} -eq 1 ] && out_has "offers 26.04.1 LTS" && ! logged "^do-release-upgrade$"'
        ;;
    ubuntu-none-offered)
        printf '[DEFAULT]\nPrompt=lts\n' > "${_DISTRO_UBUNTU_RELEASE_UPGRADES}"
        ubuntu-release-upgrade; rc=$?
        check "ubuntu, nothing offered: exit 0, explains Prompt=" '[ ${rc} -eq 0 ] && out_has "No new release is offered" && out_has "Prompt=lts" && out_has "first point release"'
        check "ubuntu, nothing offered: do-release-upgrade not run" '! logged "^do-release-upgrade$"'
        ;;
    ubuntu-reboot)
        : > "${_DISTRO_REBOOT_REQUIRED_FILE}"
        ubuntu-release-upgrade; rc=$?
        check "ubuntu, reboot pending after the updates: stops" '[ ${rc} -eq 1 ] && ! logged "do-release-upgrade"'
        ;;
    ubuntu-no-tool)
        ubuntu-release-upgrade; rc=$?
        check "ubuntu without do-release-upgrade: installs update-manager-core first" 'logged "^apt-get install -y update-manager-core$"'
        ;;
    ubuntu-no-confirm)
        ubuntu-release-upgrade; rc=$?
        check "ubuntu, no typed word: nothing upgraded" '[ ${rc} -eq 0 ] && ! logged "^do-release-upgrade$"'
        ;;
    ubuntu-refusals)
        ubuntu-release-upgrade; r1=$?
        check "ubuntu, container: refused" '[ ${r1} -eq 1 ] && ran_nothing'
        ;;
    ubuntu-no-tty)
        ubuntu-release-upgrade; rc=$?
        check "ubuntu, no terminal: refused" '[ ${rc} -eq 1 ] && ran_nothing'
        ;;

    # ── pop ─────────────────────────────────────────────────────────────────
    pop-ok)
        pop-release-upgrade; rc=$?
        check "pop: succeeds" '[ ${rc} -eq 0 ]'
        check "pop: order is apt, recovery refresh, release upgrade" 'line_before "^apt-get full-upgrade -y$" "^pop-upgrade recovery upgrade from-release$" && line_before "^pop-upgrade recovery" "^pop-upgrade release upgrade$"'
        check "pop: pop-upgrade runs unelevated" '! logged "^elev pop-upgrade"'
        ;;
    pop-recovery-fails)
        pop-release-upgrade; rc=$?
        check "pop, recovery step fails, not confirmed: stops, no release upgrade" '[ ${rc} -eq 1 ] && ! logged "release upgrade"'
        ;;
    pop-recovery-fails-continue)
        pop-release-upgrade; rc=$?
        check "pop, recovery step fails, 'continue': asks again before the upgrade" '[ "$(grep -c "^PROMPT:" "${OUT}")" = "2" ] && ! logged "release upgrade"'
        ;;
    pop-no-confirm)
        pop-release-upgrade; rc=$?
        check "pop, no typed word: the release upgrade never starts" '[ ${rc} -eq 0 ] && ! logged "release upgrade"'
        ;;
    pop-reboot)
        : > "${_DISTRO_REBOOT_REQUIRED_FILE}"
        pop-release-upgrade; rc=$?
        check "pop, reboot pending: stops before pop-upgrade" '[ ${rc} -eq 1 ] && ! logged "^pop-upgrade"'
        ;;

    # ── openSUSE Leap ───────────────────────────────────────────────────────
    leap-ok)
        opensuse-release-upgrade; rc=$?
        check "leap: succeeds" '[ ${rc} -eq 0 ]'
        check "leap: updates, installs the tool, runs it, in that order" 'line_before "^zypper --non-interactive update$" "^zypper --non-interactive install opensuse-migration-tool$" && line_before "^zypper --non-interactive install" "^opensuse-migration-tool"'
        ;;
    leap-dry-run)
        opensuse-release-upgrade --dry-run; rc=$?
        check "leap --dry-run: passed to the tool, no confirmation asked" '[ ${rc} -eq 0 ] && logged "^opensuse-migration-tool --dry-run$" && ! out_has "PROMPT"'
        ;;
    leap-no-confirm)
        opensuse-release-upgrade; rc=$?
        check "leap, no typed word: the migration tool does not run" '[ ${rc} -eq 0 ] && ! logged "^opensuse-migration-tool"'
        ;;
    leap-container)
        opensuse-release-upgrade; rc=$?
        check "leap, container: refused" '[ ${rc} -eq 1 ] && ran_nothing'
        ;;
esac
EOF

DEB_FILES="shell/distro.sh shell/distro/debian.sh shell/distro/ubuntu.sh shell/distro/pop.sh"
DEB_ENV="WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian"
SUSE_FILES="shell/distro.sh shell/distro/suse.sh shell/distro/opensuse-leap.sh"

# run <shell> <scenario> <files> [VAR=value ...]
run() {
    local shell="$1" name="$2" files="$3"
    shift 3
    # shellcheck disable=SC2086  # the *_ENV words are VAR=value lists on purpose
    report_scenario "${shell}" "" "$(run_scenario "${shell}" "${WORK}/scenario.sh" "${name}" FILES="${files}" "$@")"
}

for shell in $(test_shells); do
    # shellcheck disable=SC2086
    {
        D="${DEB_FILES}"
        run "${shell}" deb-not-debian "${D}" ${DEB_ENV} HAVE_TTY=1
        run "${shell}" deb-arguments "${D}" ${DEB_ENV} HAVE_TTY=1
        run "${shell}" deb-skip "${D}" ${DEB_ENV} HAVE_TTY=1
        run "${shell}" deb-number-target "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=no CURL_SUITE=stable
        run "${shell}" deb-unknown-current "${D}" ${DEB_ENV} HAVE_TTY=1
        run "${shell}" deb-version-file-fallback "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=no
        run "${shell}" deb-container "${D}" ${DEB_ENV} HAVE_TTY=1 SDV_RC=0
        run "${shell}" deb-no-tty "${D}" ${DEB_ENV} HAVE_TTY=0
        run "${shell}" deb-no-curl "${D}" ${DEB_ENV} HAVE_TTY=1 WITHOUT=curl
        run "${shell}" deb-not-stable "${D}" ${DEB_ENV} HAVE_TTY=1 CURL_SUITE=testing
        run "${shell}" deb-curl-fails "${D}" ${DEB_ENV} HAVE_TTY=1 CURL_SUITE=none
        run "${shell}" deb-fetches-official-archive "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=no
        run "${shell}" deb-ssh-warning "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=no SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"
        run "${shell}" deb-preflight-reboot "${D}" ${DEB_ENV} HAVE_TTY=1
        run "${shell}" deb-preflight-dpkg "${D}" ${DEB_ENV} HAVE_TTY=1 DPKG_AUDIT="The following packages are only half-configured: foo"
        run "${shell}" deb-preflight-holds "${D}" ${DEB_ENV} HAVE_TTY=1 HOLDS="linux-image-amd64"
        run "${shell}" deb-preflight-update-fails "${D}" ${DEB_ENV} HAVE_TTY=1 FAIL_ON='^apt-get update'
        run "${shell}" deb-happy "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=upgrade
        run "${shell}" deb-disable-third-party "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=upgrade
        run "${shell}" deb-no-confirm "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=nope
        run "${shell}" deb-fails-midway "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=upgrade FAIL_ON='^apt-get full-upgrade$'
        run "${shell}" deb-deb822-only "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=upgrade
        run "${shell}" deb-nothing-to-rewrite "${D}" ${DEB_ENV} HAVE_TTY=1 ANSWER=upgrade

        U="${DEB_FILES}"
        UBU="WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu"
        run "${shell}" ubuntu-offered "${U}" ${UBU} HAVE_TTY=1 ANSWER=upgrade DRU_CHECK="New release '26.04.1 LTS' available."
        run "${shell}" ubuntu-no-version "${U}" ${UBU} HAVE_TTY=1 ANSWER=upgrade DRU_CHECK="New release '26.04.1 LTS' available."
        run "${shell}" ubuntu-wrong-version "${U}" ${UBU} HAVE_TTY=1 ANSWER=upgrade DRU_CHECK="New release '26.04.1 LTS' available."
        run "${shell}" ubuntu-none-offered "${U}" ${UBU} HAVE_TTY=1 DRU_CHECK="No new release found."
        run "${shell}" ubuntu-reboot "${U}" ${UBU} HAVE_TTY=1
        run "${shell}" ubuntu-no-tool "${U}" ${UBU} HAVE_TTY=1 WITHOUT=do-release-upgrade
        run "${shell}" ubuntu-no-confirm "${U}" ${UBU} HAVE_TTY=1 ANSWER=no DRU_CHECK="New release '26.04.1 LTS' available."
        run "${shell}" ubuntu-refusals "${U}" ${UBU} HAVE_TTY=1 SDV_RC=0
        run "${shell}" ubuntu-no-tty "${U}" ${UBU} HAVE_TTY=0

        POP="WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=pop"
        run "${shell}" pop-ok "${U}" ${POP} HAVE_TTY=1 ANSWER=upgrade
        run "${shell}" pop-recovery-fails "${U}" ${POP} HAVE_TTY=1 ANSWER=no FAIL_ON='^pop-upgrade recovery'
        run "${shell}" pop-recovery-fails-continue "${U}" ${POP} HAVE_TTY=1 ANSWER=continue FAIL_ON='^pop-upgrade recovery'
        run "${shell}" pop-no-confirm "${U}" ${POP} HAVE_TTY=1 ANSWER=no
        run "${shell}" pop-reboot "${U}" ${POP} HAVE_TTY=1

        LEAP="WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap"
        run "${shell}" leap-ok "${SUSE_FILES}" ${LEAP} HAVE_TTY=1 ANSWER=upgrade
        run "${shell}" leap-dry-run "${SUSE_FILES}" ${LEAP} HAVE_TTY=1
        run "${shell}" leap-no-confirm "${SUSE_FILES}" ${LEAP} HAVE_TTY=1 ANSWER=no
        run "${shell}" leap-container "${SUSE_FILES}" ${LEAP} HAVE_TTY=1 SDV_RC=0
    }
done

finish
