#!/usr/bin/env bash
# tests/check-dnf-tuning.sh — workbench-distro
# install-dnf-tuning and installed-dnf-tuning in shell/installers.sh.
# _DNF_TUNING_FILE and _DNF_TUNING_DNF_CONF point at a temp directory and
# `readlink` is a fake that makes dnf look like DNF 5 or DNF 4. Plain bash,
# numbered OK:/FAIL: checks; each scenario runs in bash, and in zsh when it
# is installed.
#
#   - the default file is byte-compared; DNF_PARALLEL_DOWNLOADS and
#     DNF_FASTESTMIRROR change it as documented;
#   - 0, 21, abc and DNF_FASTESTMIRROR=yes are refused before anything is
#     written;
#   - a second run with the same values doesn't call install; different
#     values do;
#   - DNF 4, a non-rhel family and rpm-ostree are refused, DNF 4 with the
#     config-manager line to run by hand;
#   - a user's dnf.conf that sets a tuned value produces a warning;
#   - installed-dnf-tuning follows the file.
set -uo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib/harness.sh"

fake readlink 'case "${DNF_GEN:-5}" in 5) echo /usr/bin/dnf5 ;; *) echo /usr/bin/dnf-3 ;; esac'
fake dnf
# install: -d <dir> makes the directory, otherwise <src> <dst> copies. The
# mode and owner arguments are ignored.
fake install 'last=""; second=""
for a in "$@"; do second="${last}"; last="${a}"; done
if [ "$1" = "-d" ]; then mkdir -p "${last}"; else cp "${second}" "${last}"; fi'
touch "${WORK}/ostree-booted"

cat > "${WORK}/scenario.sh" <<'EOF'
. "${REPO_ROOT}/tests/lib/prelude.sh"
TMPDIR="${HOME}"
_dnf_tuning_elev() { echo elev; }

DIR="${HOME}/etc-dnf"
_DNF_TUNING_FILE="${DIR}/libdnf5.conf.d/50-workbench.conf"
_DNF_TUNING_DNF_CONF="${DIR}/dnf.conf"
mkdir -p "${DIR}"

# expected <parallel> [fastest] — the file's exact content.
expected() {
    printf '%s\n' "# Written by workbench-distro (wb tools install dnf-tuning)." \
        "# Values in ${_DNF_TUNING_DNF_CONF} take precedence over this file." \
        "# Remove with: sudo rm ${_DNF_TUNING_FILE}" \
        "[main]" \
        "max_parallel_downloads=$1"
    if [ "${2:-false}" = "true" ]; then
        printf '%s\n' "fastestmirror=True"
    fi
}
file_is() { [ -f "${_DNF_TUNING_FILE}" ] && [ "$(cat "${_DNF_TUNING_FILE}")" = "$(expected "$@")" ]; }
no_file() { [ ! -e "${_DNF_TUNING_FILE}" ]; }
installs() { grep -c "^install " "${LOG}"; }

case "${SCENARIO}" in
    default)
        install-dnf-tuning; rc=$?
        check "default: succeeds" '[ ${rc} -eq 0 ]'
        check "default: 10 parallel downloads, no fastestmirror, byte for byte" 'file_is 10'
        check "default: uses the elevation command to write" 'logged "^elev install -m 0644"'
        check "default: leaves dnf.conf alone" '[ ! -e "${_DNF_TUNING_DNF_CONF}" ]'
        check "default: installed-dnf-tuning is true" 'installed-dnf-tuning'
        ;;
    parallel)
        DNF_PARALLEL_DOWNLOADS=6 install-dnf-tuning; rc=$?
        check "DNF_PARALLEL_DOWNLOADS=6: written" '[ ${rc} -eq 0 ] && file_is 6'
        ;;
    fastest)
        DNF_FASTESTMIRROR=true install-dnf-tuning; rc=$?
        check "DNF_FASTESTMIRROR=true: adds the fastestmirror line" '[ ${rc} -eq 0 ] && file_is 10 true'
        ;;
    bad-values)
        bad=""
        for v in 0 21 abc 1.5 -3 ""; do
            if [ -z "${v}" ]; then
                DNF_PARALLEL_DOWNLOADS=" " install-dnf-tuning 2>/dev/null; rc=$?
            else
                DNF_PARALLEL_DOWNLOADS="${v}" install-dnf-tuning 2>/dev/null; rc=$?
            fi
            [ ${rc} -eq 1 ] || bad="${bad} parallel=${v}(rc=${rc})"
        done
        DNF_FASTESTMIRROR=yes install-dnf-tuning 2>/dev/null; rc=$?
        [ ${rc} -eq 1 ] || bad="${bad} fastest=yes(rc=${rc})"
        check "0, 21, abc, 1.5, -3, blank and DNF_FASTESTMIRROR=yes are all refused${bad:+ (not: ${bad})}" '[ -z "${bad}" ]'
        check "refused values: nothing written, install never called" 'no_file && [ "$(installs)" = "0" ]'
        ;;
    boundaries)
        DNF_PARALLEL_DOWNLOADS=1 install-dnf-tuning; r1=$?
        file_is 1 && ok1=yes || ok1=no
        DNF_PARALLEL_DOWNLOADS=20 install-dnf-tuning; r2=$?
        file_is 20 && ok2=yes || ok2=no
        check "1 and 20 are accepted" '[ ${r1} -eq 0 ] && [ ${r2} -eq 0 ] && [ "${ok1}" = "yes" ] && [ "${ok2}" = "yes" ]'
        ;;
    idempotent)
        install-dnf-tuning
        first="$(installs)"
        install-dnf-tuning; rc=$?
        check "second run with the same values: succeeds" '[ ${rc} -eq 0 ]'
        check "second run: no further install call" '[ "$(installs)" = "${first}" ]'
        check "second run: says it is already applied" 'out_has "already applied"'
        DNF_PARALLEL_DOWNLOADS=6 install-dnf-tuning
        check "third run with a new value: rewritten" 'file_is 6 && [ "$(installs)" != "${first}" ]'
        ;;
    dnf4)
        install-dnf-tuning; rc=$?
        check "DNF 4: refused" '[ ${rc} -eq 1 ] && no_file'
        check "DNF 4: prints the config-manager line, with the value" 'out_has "sudo dnf config-manager --save --setopt=max_parallel_downloads=10"'
        check "DNF 4: does not touch dnf.conf" '[ ! -e "${_DNF_TUNING_DNF_CONF}" ] && [ "$(installs)" = "0" ]'
        ;;
    not-rhel)
        install-dnf-tuning; rc=$?
        check "debian family: refused" '[ ${rc} -eq 1 ] && no_file && out_has "only for dnf-based"'
        ;;
    ostree)
        install-dnf-tuning; rc=$?
        check "rpm-ostree: refused" '[ ${rc} -eq 1 ] && no_file && out_has "not for rpm-ostree"'
        ;;
    user-override)
        printf '[main]\nmax_parallel_downloads=3\nfastestmirror=1\n' > "${_DNF_TUNING_DNF_CONF}"
        install-dnf-tuning; rc=$?
        check "user dnf.conf: still writes the drop-in" '[ ${rc} -eq 0 ] && file_is 10'
        check "user dnf.conf: warns that max_parallel_downloads wins" 'out_has "sets max_parallel_downloads; that value wins"'
        check "user dnf.conf: warns about fastestmirror too" 'out_has "sets fastestmirror; that value wins"'
        check "user dnf.conf: the user's file is unchanged" '[ "$(cat "${_DNF_TUNING_DNF_CONF}")" = "[main]
max_parallel_downloads=3
fastestmirror=1" ]'
        ;;
    installed-check)
        check "before: installed-dnf-tuning is false" '! installed-dnf-tuning'
        install-dnf-tuning
        check "after: installed-dnf-tuning is true" 'installed-dnf-tuning'
        rm -f "${_DNF_TUNING_FILE}"
        check "after removing the file: false again" '! installed-dnf-tuning'
        ;;
esac
EOF

run() {
    local shell="$1" name="$2"
    shift 2
    # shellcheck disable=SC2086  # RHEL_ENV is a VAR=value list on purpose
    report_scenario "${shell}" "" "$(run_scenario "${shell}" "${WORK}/scenario.sh" "${name}" \
        FILES="shell/installers.sh" ${RHEL_ENV} "$@")"
}
RHEL_ENV="WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora _DNF_TUNING_OSTREE_MARKER=${WORK}/does-not-exist"

for shell in $(test_shells); do
    run "${shell}" default
    run "${shell}" parallel
    run "${shell}" fastest
    run "${shell}" bad-values
    run "${shell}" boundaries
    run "${shell}" idempotent
    run "${shell}" dnf4 DNF_GEN=4
    run "${shell}" not-rhel WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu
    run "${shell}" ostree _DNF_TUNING_OSTREE_MARKER="${WORK}/ostree-booted"
    run "${shell}" user-override
    run "${shell}" installed-check
done

finish
