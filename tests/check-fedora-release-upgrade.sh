#!/usr/bin/env bash
# tests/check-fedora-release-upgrade.sh — workbench-distro
# fedora-release-upgrade in shell/distro/fedora.sh, with `rpm -E %fedora`
# stubbed to 44 (or to 45 after an upgrade, for --post). Plain bash, numbered
# OK:/FAIL: checks. Every external tool is a fake that logs its arguments;
# answers to the typed-word prompt come from $ANSWER and the terminal from
# $HAVE_TTY. Each scenario runs in bash, and in zsh when it is installed.
#
#   - refused: not newer, more than two ahead, not a number, no argument;
#   - DNF 5: no plugin installed; upgrade, reboot check, download, record,
#     confirm, then `dnf offline reboot`; DNF 4: plugin installed and
#     `dnf system-upgrade reboot`;
#   - a reboot pending after step 1 stops before the download;
#   - no typed 'reboot' means no reboot call and the clean-up command printed;
#   - no terminal means refused before anything runs;
#   - WSL: stage, or not; no systemd and DNF 4 are refused before step 1;
#   - --post: state file, TO mismatch, no record, two release packages,
#     duplicates on DNF 5 and DNF 4.
set -uo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib/harness.sh"

fake readlink 'case "${DNF_GEN:-5}" in 5) echo /usr/bin/dnf5 ;; *) echo /usr/bin/dnf-3 ;; esac'
fake dnf 'case "$*" in
    needs-restarting*) exit "${NR_RC:-0}" ;;
    "repoquery --duplicates") [ -n "${DUPES:-}" ] && printf "%s\n" "${DUPES}" ;;
    "repoquery --extras"*)    [ -n "${EXTRAS:-}" ] && printf "%s\n" "${EXTRAS}" ;;
esac'
fake rpm 'case "$*" in
    "-E %fedora") echo "${FEDORA_NOW:-44}" ;;
    "-q fedora-release-common") printf "%s\n" "${RELEASE_COMMON:-fedora-release-common-44-1.noarch}" ;;
esac'
fake rpmconf
fake remove-retired-packages
fake systemd-detect-virt 'exit "${SDV_RC:-1}"'

touch "${WORK}/ostree-booted"
mkdir -p "${WORK}/state"

cat > "${WORK}/scenario.sh" <<'EOF'
. "${REPO_ROOT}/tests/lib/prelude.sh"
_distro_systemd_running() { [ "${SYSTEMD:-1}" = "1" ]; }

state_has() { grep -qx -- "$1" "${_FEDORA_UPGRADE_STATE_FILE}"; }

case "${SCENARIO}" in
    refuse-same)
        fedora-release-upgrade 44; rc=$?
        check "44 → 44: refused with exit 2" '[ ${rc} -eq 2 ]'
        check "44 → 44: says already on Fedora 44" 'out_has "already on Fedora 44"'
        fedora-release-upgrade 43; rc=$?
        check "44 → 43: downgrade refused" '[ ${rc} -eq 2 ]'
        check "refused upgrades call no dnf" '! logged "^dnf"'
        ;;
    refuse-too-far)
        fedora-release-upgrade 47; rc=$?
        check "44 → 47: refused with exit 2" '[ ${rc} -eq 2 ]'
        check "44 → 47: says at most two releases" 'out_has "at most two releases"'
        fedora-release-upgrade 46; rc=$?
        check "44 → 46: two releases ahead is allowed past the checks" '[ ${rc} -ne 2 ]'
        ;;
    refuse-not-number)
        fedora-release-upgrade 4x; r1=$?
        fedora-release-upgrade;    r2=$?
        fedora-release-upgrade --bogus; r3=$?
        check "4x: exit 2" '[ ${r1} -eq 2 ]'
        check "no release: exit 2" '[ ${r2} -eq 2 ]'
        check "unknown option: exit 2" '[ ${r3} -eq 2 ]'
        check "refused upgrades call no dnf" '! logged "^dnf"'
        ;;
    upgrade-dnf5)
        fedora-release-upgrade 45; rc=$?
        check "dnf5: succeeds" '[ ${rc} -eq 0 ]'
        check "dnf5: no system-upgrade plugin installed" '! logged "dnf-plugin-system-upgrade"'
        check "dnf5: order is upgrade, reboot check, download, reboot" 'line_before "^dnf upgrade --refresh -y$" "^dnf needs-restarting$" && line_before "^dnf needs-restarting$" "^dnf system-upgrade download --releasever=45 -y$" && line_before "^dnf system-upgrade download" "^dnf offline reboot$"'
        check "dnf5: the state file records FROM and TO" 'state_has FROM=44 && state_has TO=45'
        check "dnf5: the state file is written before the reboot" 'grep -q FROM=44 "${_FEDORA_UPGRADE_STATE_FILE}"'
        check "dnf5: reboot is the last dnf call, made once" '[ "$(grep -c "^dnf offline reboot$" "${LOG}")" = "1" ] && [ "$(grep "^dnf " "${LOG}" | tail -n 1)" = "dnf offline reboot" ]'
        check "dnf5: asked to type reboot" 'out_has "Type .reboot. to continue"'
        ;;
    upgrade-dnf4)
        fedora-release-upgrade 45; rc=$?
        check "dnf4: succeeds" '[ ${rc} -eq 0 ]'
        check "dnf4: system-upgrade plugin installed before the download" 'line_before "^dnf install -y dnf-plugin-system-upgrade$" "^dnf system-upgrade download"'
        check "dnf4: reboot with system-upgrade reboot" 'logged "^dnf system-upgrade reboot$" && ! logged "offline"'
        check "dnf4: reboot check is needs-restarting -r" 'logged "^dnf needs-restarting -r$"'
        ;;
    upgrade-two-ahead)
        fedora-release-upgrade 46; rc=$?
        check "44 → 46: downloads Fedora 46" 'logged "^dnf system-upgrade download --releasever=46 -y$"'
        ;;
    upgrade-reboot-pending)
        fedora-release-upgrade 45; rc=$?
        check "reboot pending after step 1: exit 1" '[ ${rc} -eq 1 ]'
        check "reboot pending: no download" '! logged "download"'
        check "reboot pending: tells you to reboot and run it again" 'out_has "need a reboot first"'
        ;;
    upgrade-update-fails)
        fedora-release-upgrade 45; rc=$?
        check "failed update: exit 1" '[ ${rc} -eq 1 ]'
        check "failed update: stops there" '! logged "needs-restarting" && ! logged "download"'
        ;;
    upgrade-download-fails)
        fedora-release-upgrade 45; rc=$?
        check "failed download: exit 1" '[ ${rc} -eq 1 ]'
        check "failed download: nothing was changed, and says how to clean up" 'out_has "dnf offline clean" && ! logged "reboot"'
        check "failed download: nothing recorded" '[ ! -e "${_FEDORA_UPGRADE_STATE_FILE}" ]'
        ;;
    no-confirm)
        fedora-release-upgrade 45; rc=$?
        check "answer other than reboot: exit 0" '[ ${rc} -eq 0 ]'
        check "answer other than reboot: no reboot call" '! logged "reboot$"'
        check "answer other than reboot: prints how to reboot later" 'out_has "dnf offline reboot"'
        check "answer other than reboot: prints how to clean up" 'out_has "dnf offline clean"'
        check "answer other than reboot: the download is kept recorded" 'state_has TO=45'
        ;;
    no-tty)
        fedora-release-upgrade 45; rc=$?
        check "no terminal: refused" '[ ${rc} -eq 1 ] && out_has "needs a terminal"'
        check "no terminal: nothing ran" '! logged "^dnf" && ! logged "^elev"'
        ;;
    ostree)
        fedora-release-upgrade 45; rc=$?
        check "rpm-ostree: refused with the rpm-ostree command" '[ ${rc} -eq 1 ] && out_has "rpm-ostree rebase" && ! logged "^dnf"'
        ;;
    container)
        fedora-release-upgrade 45; rc=$?
        check "container: refused" '[ ${rc} -eq 1 ] && out_has "this is a container" && ! logged "^dnf"'
        ;;
    wsl-stage)
        fedora-release-upgrade 45 >> "${OUT}"; rc=$?
        check "wsl, answer stage: succeeds" '[ ${rc} -eq 0 ]'
        check "wsl, answer stage: stages once with dnf offline reboot" '[ "$(grep -c "^dnf offline reboot$" "${LOG}")" = "1" ]'
        check "wsl: the backup advice comes before staging" 'out_has "wsl --export Fedora C:.wsl.Fedora-fedora-44.tar"'
        check "wsl: prints the terminate line" 'out_has "1. wsl --terminate Fedora"'
        check "wsl: prints the journal-following line" 'out_has "2. wsl -d Fedora -u root -- journalctl -f -o cat -u dnf5-offline-transaction"'
        check "wsl: says to run --post afterwards" 'out_has "fedora-release-upgrade --post"'
        check "wsl: never offers dnf distro-sync" '! logged "distro-sync" && ! out_has "distro-sync --releasever"'
        ;;
    wsl-no-stage)
        fedora-release-upgrade 45; rc=$?
        check "wsl, other answer: exit 0" '[ ${rc} -eq 0 ]'
        check "wsl, other answer: nothing staged" '! logged "reboot$"'
        check "wsl, other answer: the download stays and the clean-up command is printed" 'logged "download" && out_has "dnf offline clean"'
        ;;
    wsl-no-systemd)
        fedora-release-upgrade 45; rc=$?
        check "wsl without systemd: refused" '[ ${rc} -eq 1 ] && out_has "systemd isn.t running"'
        check "wsl without systemd: before step 1, so no dnf calls" '! logged "^dnf"'
        check "wsl without systemd: names the distro in the terminate command" 'out_has "wsl --terminate Fedora"'
        ;;
    wsl-dnf4)
        fedora-release-upgrade 45; rc=$?
        check "wsl with DNF 4: refused" '[ ${rc} -eq 1 ] && out_has "needs DNF 5" && ! logged "^dnf"'
        ;;
    post-ok)
        fedora-release-upgrade --post; rc=$?
        check "post: succeeds" '[ ${rc} -eq 0 ]'
        check "post: installs rpmconf and remove-retired-packages" 'logged "^dnf install -y rpmconf remove-retired-packages$"'
        check "post: rpmconf -a, interactive" 'logged "^rpmconf -a$"'
        check "post: remove-retired-packages gets the old release, unelevated" 'logged "^remove-retired-packages 44$" && ! logged "^elev remove-retired-packages"'
        check "post: autoremove is interactive (no -y)" 'logged "^dnf autoremove$"'
        check "post: order is install, rpmconf, retired, autoremove" 'line_before "^dnf install" "^rpmconf" && line_before "^rpmconf" "^remove-retired" && line_before "^remove-retired" "^dnf autoremove"'
        check "post: duplicates and extras are reported, never removed" 'logged "^dnf repoquery --duplicates$" && logged "^dnf repoquery --extras" && ! logged "dnf remove"'
        check "post: extras exclude the kernel packages" 'logged "exclude=kernel,kernel-\*,kmod-\*"'
        check "post: state file removed" '[ ! -e "${_FEDORA_UPGRADE_STATE_FILE}" ]'
        check "post: says it is done" 'out_has "Fedora 45 post-upgrade steps done"'
        ;;
    post-from-flag)
        fedora-release-upgrade --post --from 43; rc=$?
        check "post --from, no state file: succeeds" '[ ${rc} -eq 0 ]'
        check "post --from: passes that release on" 'logged "^remove-retired-packages 43$"'
        ;;
    post-not-applied)
        fedora-release-upgrade --post; rc=$?
        check "post, still on 44 after recording TO=45: exit 1" '[ ${rc} -eq 1 ]'
        check "post, not applied: says so and points at the log" 'out_has "didn.t apply" && out_has "dnf offline log --number=-1"'
        check "post, not applied: nothing installed" '! logged "install"'
        check "post, not applied: the state file is kept" '[ -e "${_FEDORA_UPGRADE_STATE_FILE}" ]'
        ;;
    post-no-record)
        fedora-release-upgrade --post; rc=$?
        check "post with no record and no --from: exit 2" '[ ${rc} -eq 2 ]'
        check "post with no record: says to pass --from" 'out_has "--post --from"'
        check "post with no record: nothing ran" '! logged "^dnf"'
        ;;
    post-interrupted)
        fedora-release-upgrade --post; rc=$?
        check "post, two fedora-release-common versions: exit 1" '[ ${rc} -eq 1 ]'
        check "post, interrupted: names the signature" 'out_has "interrupted upgrade"'
        check "post, interrupted: nothing installed" '! logged "install"'
        ;;
    post-duplicates-dnf5)
        fedora-release-upgrade --post >> "${OUT}"
        check "post, DNF 5 duplicates: lists them" 'out_has "more than one version"'
        check "post, DNF 5: does not print a command that fails" '! out_has "dnf remove --duplicates" || out_has "isn.t supported there"'
        ;;
    post-duplicates-dnf4)
        fedora-release-upgrade --post >/dev/null
        check "post, DNF 4 duplicates: prints the command to remove them" 'out_has "dnf remove --duplicates"'
        ;;
    post-state-not-sourced)
        printf 'FROM=44\nTO=45\n$(touch %s/pwned)\n' "${HOME}" > "${_FEDORA_UPGRADE_STATE_FILE}"
        fedora-release-upgrade --post >/dev/null
        check "post: the state file is parsed, never sourced" '[ ! -e "${HOME}/pwned" ]'
        ;;
esac
EOF

STATE_FILE="${WORK}/state/fedora-upgrade"
write_state() { printf 'FROM=44\nTO=45\n' > "${STATE_FILE}"; }

FEDORA_ENV="WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora _DISTRO_OSTREE_MARKER=${WORK}/does-not-exist _FEDORA_UPGRADE_STATE_FILE=${STATE_FILE}"
FILES="shell/distro.sh shell/distro/rhel.sh shell/distro/fedora.sh"

# run <shell> <scenario> [VAR=value ...]
run() {
    local shell="$1" name="$2"
    shift 2
    rm -f "${STATE_FILE}"
    # shellcheck disable=SC2086  # FEDORA_ENV is a VAR=value list on purpose
    report_scenario "${shell}" "" "$(run_scenario "${shell}" "${WORK}/scenario.sh" "${name}" FILES="${FILES}" ${FEDORA_ENV} "$@")"
}
# run_with_state: the same, with the state file from an earlier download.
run_with_state() {
    local shell="$1" name="$2"
    shift 2
    write_state
    # shellcheck disable=SC2086
    report_scenario "${shell}" "" "$(run_scenario "${shell}" "${WORK}/scenario.sh" "${name}" FILES="${FILES}" ${FEDORA_ENV} "$@")"
}

for shell in $(test_shells); do
    run "${shell}" refuse-same HAVE_TTY=1
    run "${shell}" refuse-too-far HAVE_TTY=1 ANSWER=no
    run "${shell}" refuse-not-number HAVE_TTY=1
    run "${shell}" upgrade-dnf5 HAVE_TTY=1 ANSWER=reboot DNF_GEN=5
    run "${shell}" upgrade-dnf4 HAVE_TTY=1 ANSWER=reboot DNF_GEN=4
    run "${shell}" upgrade-two-ahead HAVE_TTY=1 ANSWER=no
    run "${shell}" upgrade-reboot-pending HAVE_TTY=1 ANSWER=reboot NR_RC=1
    run "${shell}" upgrade-update-fails HAVE_TTY=1 FAIL_ON='^dnf upgrade'
    run "${shell}" upgrade-download-fails HAVE_TTY=1 ANSWER=reboot FAIL_ON='^dnf system-upgrade download'
    run "${shell}" no-confirm HAVE_TTY=1 ANSWER=yes
    run "${shell}" no-tty HAVE_TTY=0
    run "${shell}" ostree HAVE_TTY=1 _DISTRO_OSTREE_MARKER="${WORK}/ostree-booted"
    run "${shell}" container HAVE_TTY=1 SDV_RC=0
    run "${shell}" wsl-stage HAVE_TTY=1 ANSWER=stage WORKBENCH_WSL=true WSL_DISTRO_NAME=Fedora SYSTEMD=1
    run "${shell}" wsl-no-stage HAVE_TTY=1 ANSWER=no WORKBENCH_WSL=true WSL_DISTRO_NAME=Fedora SYSTEMD=1
    run "${shell}" wsl-no-systemd HAVE_TTY=1 WORKBENCH_WSL=true WSL_DISTRO_NAME=Fedora SYSTEMD=0
    run "${shell}" wsl-dnf4 HAVE_TTY=1 WORKBENCH_WSL=true WSL_DISTRO_NAME=Fedora SYSTEMD=1 DNF_GEN=4

    run_with_state "${shell}" post-ok FEDORA_NOW=45 DUPES= EXTRAS=
    run_with_state "${shell}" post-not-applied FEDORA_NOW=44
    run "${shell}" post-no-record FEDORA_NOW=45
    run "${shell}" post-from-flag FEDORA_NOW=45
    run_with_state "${shell}" post-interrupted FEDORA_NOW=45 RELEASE_COMMON="fedora-release-common-44-1.noarch
fedora-release-common-45-1.noarch"
    run_with_state "${shell}" post-duplicates-dnf5 FEDORA_NOW=45 DUPES="foo-1.0-1.x86_64" DNF_GEN=5
    run_with_state "${shell}" post-duplicates-dnf4 FEDORA_NOW=45 DUPES="foo-1.0-1.x86_64" DNF_GEN=4
    run_with_state "${shell}" post-state-not-sourced FEDORA_NOW=45
done

finish
