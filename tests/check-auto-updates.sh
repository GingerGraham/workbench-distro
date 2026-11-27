#!/usr/bin/env bash
# tests/check-auto-updates.sh — workbench-distro
# install-auto-updates / installed-auto-updates (shell/installers-auto-updates.sh)
# and distro-auto-updates (shell/distro-auto-updates.sh). Plain bash, numbered
# OK:/FAIL: checks, same harness as check-dnf-tuning.sh.
#
#   - the two files repeat the same _AUTO_UPDATES_* assignments;
#   - every file the installer writes is byte-compared with
#     tests/fixtures/auto-updates/<case>/expected;
#   - first install, rerun, recorded values, ownership, refusals;
#   - `distro-auto-updates` status and off, with the exit codes.
#
# systemctl is a fake that keeps the enabled timers in a file, so a rerun
# sees the state the first run left. Installer scenarios run in bash only,
# which is how workbench-core runs installer files; shell-function scenarios
# run in bash and, when installed, zsh.
# shellcheck disable=SC2016  # the fakes and the checks are single-quoted scripts on purpose
set -uo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib/harness.sh"

INSTALLER="${REPO_ROOT}/shell/installers-auto-updates.sh"
SHELLFILE="${REPO_ROOT}/shell/distro-auto-updates.sh"

# ── Drift: the shell file's paths are the installer's paths ──────────────────
drift=""
while IFS= read -r line; do
    grep -qxF -- "${line}" "${INSTALLER}" || drift="${drift} ${line%%=*}"
done <<EOF
$(grep '^_AUTO_UPDATES_[A-Z0-9_]*=' "${SHELLFILE}")
EOF
if [[ -z "${drift}" ]]; then
    ok "drift: every _AUTO_UPDATES_* line in the shell file is in the installer, byte for byte"
else
    fail "drift: lines that differ from the installer:${drift}"
fi

# ── Fakes ─────────────────────────────────────────────────────────────────────
fake readlink 'case "${DNF_GEN:-5}" in 5) echo /usr/bin/dnf5 ;; *) echo /usr/bin/dnf-3 ;; esac; exit 0'
# install: -d <dir> makes the directory, otherwise <src> <dst> copies.
fake install 'last=""; second=""
for a in "$@"; do second="${last}"; last="${a}"; done
if [ "$1" = "-d" ]; then mkdir -p "${last}"; else cp "${second}" "${last}"; fi'
# Package managers: install adds the last argument to the "installed" list.
# PKG_CONF_SRC/PKG_CONF_DST make dnf drop the packaged DNF 4 config.
fake dnf 'if [ "$1" = "install" ]; then
    last=""; for a in "$@"; do last="${a}"; done; echo "${last}" >> "${HOME}/pkgs"
    if [ -n "${PKG_CONF_SRC:-}" ]; then mkdir -p "$(dirname "${PKG_CONF_DST}")"; cp "${PKG_CONF_SRC}" "${PKG_CONF_DST}"; fi
fi'
fake apt-get 'last=""; for a in "$@"; do last="${a}"; done; echo "${last}" >> "${HOME}/pkgs"'
fake zypper 'last=""; for a in "$@"; do last="${a}"; done; echo "${last}" >> "${HOME}/pkgs"'
fake rpm 'grep -qx -e "$2" "${HOME}/pkgs" 2>/dev/null; exit $?'
fake dpkg-query 'if grep -qx -e unattended-upgrades "${HOME}/pkgs" 2>/dev/null; then printf "install ok installed"; fi; exit 0'
fake apt-config 'if [ -n "${APT_PERIODIC:-}" ]; then echo "APT::Periodic::Unattended-Upgrade \"${APT_PERIODIC}\";"; fi; exit 0'
fake systemd-detect-virt '[ -n "${VIRT:-}" ] && exit 0; exit 1'
fake systemctl 'f="${HOME}/enabled-timers"; [ -f "${f}" ] || : > "${f}"
cmd="$1"; shift
case "${cmd}" in
    is-enabled)
        quiet="no"; if [ "$1" = "--quiet" ]; then quiet="yes"; shift; fi
        if grep -qx -e "$1" "${f}"; then
            [ "${quiet}" = "yes" ] || echo enabled
            exit 0
        fi
        [ "${quiet}" = "yes" ] || echo disabled
        exit 1 ;;
    enable)
        last=""; for a in "$@"; do last="${a}"; done; echo "${last}" >> "${f}" ;;
    disable)
        last=""; for a in "$@"; do last="${a}"; done
        grep -vx -e "${last}" "${f}" > "${f}.new"; cat "${f}.new" > "${f}"; rm -f "${f}.new" ;;
    show)
        case "$*" in
            *NextElapseUSecRealtime*) [ -f "${HOME}/next" ] && cat "${HOME}/next" ;;
            *ExecMainExitTimestamp*)  [ -f "${HOME}/lastrun" ] && cat "${HOME}/lastrun" ;;
            *Result*)                 [ -f "${HOME}/result" ] && cat "${HOME}/result" ;;
        esac ;;
esac'
: > "${WORK}/foreign-marker"

# ── Setup shared by both scenario files ──────────────────────────────────────
cat > "${WORK}/common.sh" <<'EOF'
. "${REPO_ROOT}/tests/lib/prelude.sh"
TMPDIR="${HOME}"
_auto_updates_elev() { echo elev; }
_distro_elev() { echo elev; }

FIX="${REPO_ROOT}/tests/fixtures/auto-updates"
ETC="${HOME}/etc"
_AUTO_UPDATES_DNF5_CONF="${ETC}/dnf5-automatic.conf"
_AUTO_UPDATES_DNF4_CONF="${ETC}/automatic-workbench.conf"
_AUTO_UPDATES_DNF4_DROPIN="${ETC}/dropin/50-workbench.conf"
_AUTO_UPDATES_DNF4_PACKAGED_CONF="${ETC}/packaged.conf"
_AUTO_UPDATES_APT_CONF="${ETC}/apt.conf.d/52workbench-auto-updates"
_AUTO_UPDATES_SUSE_CONF="${ETC}/os-update.conf"
_AUTO_UPDATES_OSTREE_MARKER="${HOME}/no-ostree"
_AUTO_UPDATES_SYSTEMD_DIR="${HOME}/systemd"
_AUTO_UPDATES_CONTAINER_MARKERS="${HOME}/no-container-marker"
export PKG_CONF_DST="${_AUTO_UPDATES_DNF4_PACKAGED_CONF}"

# fresh_host — a clean host: no files, no packages, every timer disabled, except
# what PRE_ENABLED (comma list), PKGS_PRESENT (comma list) and
# PACKAGED_FIXTURE (a file under tests/fixtures/auto-updates) ask for.
fresh_host() {
    rm -rf "${ETC}" "${HOME}/systemd"
    mkdir -p "${ETC}/apt.conf.d" "${HOME}/systemd"
    : > "${HOME}/pkgs"
    : > "${HOME}/enabled-timers"
    rm -f "${HOME}/next" "${HOME}/lastrun" "${HOME}/result"
    if [ -n "${PRE_ENABLED:-}" ]; then printf '%s\n' "${PRE_ENABLED}" | tr ',' '\n' > "${HOME}/enabled-timers"; fi
    if [ -n "${PKGS_PRESENT:-}" ]; then printf '%s\n' "${PKGS_PRESENT}" | tr ',' '\n' > "${HOME}/pkgs"; fi
    if [ -n "${PACKAGED_FIXTURE:-}" ]; then cp "${FIX}/${PACKAGED_FIXTURE}" "${_AUTO_UPDATES_DNF4_PACKAGED_CONF}"; fi
    : > "${LOG}"
    : > "${OUT}"
}

# matches <file> <fixture> — byte for byte, after filling in the two paths a
# fixture can't know.
matches() {
    [ -f "$1" ] || return 1
    sed -e "s|@DNF4_CONF@|${_AUTO_UPDATES_DNF4_CONF}|g" \
        -e "s|@PACKAGED_CONF@|${_AUTO_UPDATES_DNF4_PACKAGED_CONF}|g" "$2" | cmp -s - "$1"
}
# make_ours <file> <comment-prefix> <scope> <reboot> <timers> — a file as the installer would leave it.
make_ours() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2 Written by workbench-distro (wb tools install auto-updates)." \
        "$2 workbench-auto-updates: scope=$3 reboot=$4 enabled-timers=$5" "$6" > "$1"
}
timer_enabled() { grep -qx -e "$1" "${HOME}/enabled-timers"; }
count() { grep -c -E -e "$1" "${LOG}"; }
installs() { count '^(dnf|apt-get|zypper) .*install'; }
enables()  { count '^systemctl enable'; }
reloads()  { count '^systemctl daemon-reload'; }
# no_changes — nothing that installs, enables or disables was called.
no_changes() { ! grep -Eq '^(install|dnf|apt-get|zypper|systemctl) ' "${LOG}"; }
has() { printf '%s\n' "${out}" | grep -qF -- "$1"; }
Q="'"
EOF

# ── Installer scenarios (bash only) ──────────────────────────────────────────
cat > "${WORK}/scenario-install.sh" <<'EOF'
. "${WORK_DIR}/common.sh"

recorded() { _auto_updates_recorded "$(_auto_updates_conf_path "$(_auto_updates_backend)")" "$1"; }

# render_case <case> <family> <id> <dnf-generation> <scope> <reboot>
render_case() {
    case_name="$1"
    fresh_host
    export WORKBENCH_DISTRO="$2" WORKBENCH_DISTRO_ID="$3" DNF_GEN="$4"
    if [ "$4" = "4" ] && [ "$6" = "when-needed" ]; then cp "${FIX}/dnf4-packaged-with-reboot" "${_AUTO_UPDATES_DNF4_PACKAGED_CONF}"; fi
    AUTO_UPDATES_SCOPE="$5" AUTO_UPDATES_REBOOT="$6" install-auto-updates >/dev/null 2>&1; rc=$?
    conf="$(_auto_updates_conf_path "$(_auto_updates_backend)")"
    check "render ${case_name}: written byte for byte" '[ ${rc} -eq 0 ] && matches "${conf}" "${FIX}/${case_name}/expected"'
}

# refuses <label> <expected text> [VAR=value ...] — one install in a clean
# host, with the variables set only for that run.
refuses() {
    label="$1"; text="$2"; shift 2
    (
        for kv in "$@"; do export "${kv}"; done
        fresh_host
        install-auto-updates
    ) >/dev/null 2>&1
    rc=$?
    check "refused, nothing changed: ${label}" '[ ${rc} -eq 1 ] && no_changes && out_has "${text}"'
}

case "${SCENARIO}" in
    render)
        render_case dnf5-security-never       rhel fedora 5 security never
        render_case dnf5-security-when-needed rhel fedora 5 security when-needed
        render_case dnf5-all-never            rhel fedora 5 all never
        render_case dnf5-all-when-needed      rhel fedora 5 all when-needed
        render_case dnf4-security-never       rhel rocky 4 security never
        check "render dnf4: the systemd drop-in, byte for byte" 'matches "${_AUTO_UPDATES_DNF4_DROPIN}" "${FIX}/dnf4-dropin/expected"'
        render_case dnf4-all-when-needed      rhel rocky 4 all when-needed
        render_case apt-debian-security-never debian debian 5 security never
        render_case apt-debian-all-never      debian debian 5 all never
        render_case apt-ubuntu-security-never debian ubuntu 5 security never
        render_case apt-ubuntu-all-never      debian ubuntu 5 all never
        render_case apt-ubuntu-all-when-needed debian ubuntu 5 all when-needed
        render_case apt-pop-security-never    debian pop 5 security never
        render_case apt-pop-all-never         debian pop 5 all never
        render_case suse-leap-security-never  suse opensuse-leap 5 security never
        render_case suse-leap-all-never       suse opensuse-leap 5 all never
        render_case suse-leap-all-when-needed suse opensuse-leap 5 all when-needed
        render_case suse-tumbleweed-all-never suse opensuse-tumbleweed 5 all never
        ;;
    render-literals)
        render_case apt-ubuntu-all-never debian ubuntu 5 all never
        check "apt: \${distro_codename} stays literal in the file" 'grep -qF "archive=\${distro_codename}-security" "${conf}" && ! grep -q "archive=noble" "${conf}"'
        check "apt: no custom origins from third-party repos in the list" '! grep -qi "docker\|ppa" "${conf}"'
        ;;
    first-install)
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        install-auto-updates; rc=$?
        check "first install: succeeds" '[ ${rc} -eq 0 ]'
        check "first install: installs dnf5-plugin-automatic once, with the elevation command" '[ "$(installs)" = "1" ] && logged "^elev dnf install -y dnf5-plugin-automatic"'
        check "first install: writes the file with the elevation command" 'logged "^elev install -m 0644" && [ -f "${_AUTO_UPDATES_DNF5_CONF}" ]'
        check "first install: enables the disabled timer with --now" 'logged "^elev systemctl enable --now dnf5-automatic.timer" && timer_enabled dnf5-automatic.timer'
        check "first install: records exactly the timer it enabled" '[ "$(recorded enabled-timers)" = "dnf5-automatic.timer" ]'
        check "first install: package, then file, then timer" 'line_before "^dnf install" "^install -m 0644" && line_before "^install -m 0644" "^systemctl enable"'
        check "first install: defaults are security and never" '[ "$(recorded scope)" = "security" ] && [ "$(recorded reboot)" = "never" ]'
        check "first install: installed-auto-updates is true" 'installed-auto-updates'
        check "first install: says it is on" 'out_has "auto-updates: on (dnf5, scope security, reboot never)"'
        ;;
    package-present)
        PKGS_PRESENT=dnf5-plugin-automatic fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        install-auto-updates; rc=$?
        check "package already installed: succeeds without a package-manager call" '[ ${rc} -eq 0 ] && [ "$(installs)" = "0" ]'
        ;;
    first-install-apt)
        fresh_host
        export WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu
        install-auto-updates; rc=$?
        check "apt: installs unattended-upgrades non-interactively" '[ ${rc} -eq 0 ] && logged "^elev env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades"'
        check "apt: file is 52workbench-auto-updates and both timers were recorded" '[ -f "${_AUTO_UPDATES_APT_CONF}" ] && [ "$(recorded enabled-timers)" = "apt-daily.timer,apt-daily-upgrade.timer" ]'
        install-auto-updates
        check "apt: a second run installs and enables nothing" '[ "$(installs)" = "1" ] && [ "$(enables)" = "2" ]'
        ;;
    first-install-suse)
        fresh_host
        export WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap
        install-auto-updates; rc=$?
        check "os-update: installs the package with zypper and enables os-update.timer" '[ ${rc} -eq 0 ] && logged "^elev zypper --non-interactive install os-update" && timer_enabled os-update.timer'
        ;;
    rerun)
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        install-auto-updates
        : > "${OUT}"
        first_installs="$(installs)"; first_enables="$(enables)"
        before="$(cat "${_AUTO_UPDATES_DNF5_CONF}")"
        install-auto-updates; rc=$?
        check "second run, same environment: succeeds" '[ ${rc} -eq 0 ]'
        check "second run: no further install call" '[ "$(installs)" = "${first_installs}" ]'
        check "second run: no further systemctl enable" '[ "$(enables)" = "${first_enables}" ]'
        check "second run: no daemon-reload" '[ "$(reloads)" = "0" ]'
        check "second run: file unchanged and only one write call was made" '[ "$(cat "${_AUTO_UPDATES_DNF5_CONF}")" = "${before}" ] && [ "$(count "^install -m 0644")" = "1" ]'
        check "second run: says it is already on" 'out_has "already on (dnf5, scope security, reboot never)"'
        ;;
    recorded-survives)
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        AUTO_UPDATES_SCOPE=all AUTO_UPDATES_REBOOT=when-needed install-auto-updates
        cp "${_AUTO_UPDATES_DNF5_CONF}" "${HOME}/after-first"
        install-auto-updates; rc=$?
        check "bare rerun: succeeds" '[ ${rc} -eq 0 ]'
        check "bare rerun: file still says all and when-needed" '[ "$(recorded scope)" = "all" ] && [ "$(recorded reboot)" = "when-needed" ]'
        check "bare rerun: file is byte-for-byte what the first run wrote" 'cmp -s "${HOME}/after-first" "${_AUTO_UPDATES_DNF5_CONF}"'
        ;;
    one-field)
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        AUTO_UPDATES_SCOPE=all install-auto-updates
        AUTO_UPDATES_REBOOT=when-needed install-auto-updates; rc=$?
        check "reboot set on a rerun: scope stays all, reboot changes" '[ ${rc} -eq 0 ] && [ "$(recorded scope)" = "all" ] && [ "$(recorded reboot)" = "when-needed" ]'
        check "reboot set on a rerun: enabled-timers kept although the timer is on now" '[ "$(recorded enabled-timers)" = "dnf5-automatic.timer" ]'
        AUTO_UPDATES_SCOPE=security install-auto-updates
        check "scope set on a rerun: reboot stays when-needed" '[ "$(recorded scope)" = "security" ] && [ "$(recorded reboot)" = "when-needed" ]'
        check "changes rewrote the file, never re-enabled the timer" '[ "$(count "^install -m 0644")" = "3" ] && [ "$(enables)" = "1" ]'
        ;;
    pre-enabled)
        PRE_ENABLED=dnf5-automatic.timer fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        install-auto-updates; rc=$?
        check "timer already enabled: not recorded, not enabled again" '[ ${rc} -eq 0 ] && [ "$(recorded enabled-timers)" = "none" ] && [ "$(enables)" = "0" ]'
        fresh_host
        PRE_ENABLED=apt-daily.timer fresh_host
        export WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu
        install-auto-updates
        check "apt, one timer already on: only the other is recorded and enabled" '[ "$(recorded enabled-timers)" = "apt-daily-upgrade.timer" ] && [ "$(enables)" = "1" ]'
        ;;
    foreign-file)
        for backend_case in dnf5 dnf4-conf dnf4-dropin apt suse; do
            fresh_host
            case "${backend_case}" in
                dnf5)        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5; target="${_AUTO_UPDATES_DNF5_CONF}" ;;
                dnf4-conf)   export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=rocky DNF_GEN=4; target="${_AUTO_UPDATES_DNF4_CONF}" ;;
                dnf4-dropin) export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=rocky DNF_GEN=4; target="${_AUTO_UPDATES_DNF4_DROPIN}" ;;
                apt)         export WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu; target="${_AUTO_UPDATES_APT_CONF}" ;;
                suse)        export WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap; target="${_AUTO_UPDATES_SUSE_CONF}" ;;
            esac
            mkdir -p "$(dirname "${target}")"
            printf '%s\n' "# somebody else's settings" "upgrade_type = default" > "${target}"
            cp "${target}" "${HOME}/foreign-copy"
            install-auto-updates; rc=$?
            check "foreign file at the ${backend_case} path: refused, file untouched, nothing installed or enabled" '[ ${rc} -eq 1 ] && cmp -s "${HOME}/foreign-copy" "${target}" && no_changes && out_has "wasn.t written by workbench"'
        done
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        printf '%s\n' "[commands]" > "${_AUTO_UPDATES_DNF5_CONF}"
        AUTO_UPDATES_SCOPE=all AUTO_UPDATES_REBOOT=when-needed install-auto-updates
        check "foreign dnf5 file: prints the settings to set by hand" 'out_has "upgrade_type = default, apply_updates = True, reboot = when-needed" && out_has "systemctl enable --now dnf5-automatic.timer"'
        ;;
    foreign-file-after-install)
        # Installing the package creates a file at workbench's path: refused afterwards, left alone.
        fresh_host
        export PKG_CONF_SRC="${FIX}/dnf4-packaged-with-reboot" PKG_CONF_DST="${_AUTO_UPDATES_DNF5_CONF}"
        install-auto-updates; rc=$?
        check "file created by the package during install: refused" '[ ${rc} -eq 1 ] && out_has "wasn.t written by workbench"'
        check "file created by the package: left as the package made it, no timer enabled" 'cmp -s "${FIX}/dnf4-packaged-with-reboot" "${_AUTO_UPDATES_DNF5_CONF}" && [ "$(enables)" = "0" ]'
        ;;
    refusals)
        : > "${HOME}/marker"
        refuses "Arch"                      "Arch doesn.t support unattended upgrades"  WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch
        refuses "Omarchy (arch family)"     "Omarchy.s updater"                         WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=omarchy
        refuses "Linux Mint"                "Update Manager"                            WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=linuxmint
        refuses "an unknown debian-family ID" "isn.t handled"                           WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=elementary
        refuses "rpm-ostree"                "rpm-ostree"                                "_AUTO_UPDATES_OSTREE_MARKER=${HOME}/marker"
        refuses "container marker file"     "this is a container"                       "_AUTO_UPDATES_CONTAINER_MARKERS=${HOME}/marker"
        refuses "systemd-detect-virt says container" "this is a container"             VIRT=yes
        refuses "no systemd"                "systemd isn.t running here"                "_AUTO_UPDATES_SYSTEMD_DIR=${HOME}/no-such-dir"
        refuses "no systemd on WSL, with the wsl.conf hint" "systemd=true"             "_AUTO_UPDATES_SYSTEMD_DIR=${HOME}/no-such-dir" WORKBENCH_WSL=true WSL_DISTRO_NAME=Fedora
        refuses "WSL hint names the distro" "wsl --terminate Fedora"                    "_AUTO_UPDATES_SYSTEMD_DIR=${HOME}/no-such-dir" WORKBENCH_WSL=true WSL_DISTRO_NAME=Fedora
        refuses "WSL with when-needed"      "isn.t for WSL"                             WORKBENCH_WSL=true AUTO_UPDATES_REBOOT=when-needed
        refuses "Tumbleweed with security"  "snapshots, not security patches"           WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-tumbleweed
        refuses "Slowroll with security"    "snapshots, not security patches"           WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-slowroll
        refuses "CentOS Stream with security" "no security advisories"                  WORKBENCH_DISTRO_ID=centos
        refuses "DNF 4 when-needed, packaged config has no reboot option" "too old to reboot" DNF_GEN=4 WORKBENCH_DISTRO_ID=rocky AUTO_UPDATES_REBOOT=when-needed PACKAGED_FIXTURE=dnf4-packaged-without-reboot
        refuses "bad AUTO_UPDATES_SCOPE"    "AUTO_UPDATES_SCOPE must be"                AUTO_UPDATES_SCOPE=everything
        refuses "bad AUTO_UPDATES_REBOOT"   "AUTO_UPDATES_REBOOT must be"               AUTO_UPDATES_REBOOT=always
        refuses "macOS"                     "only for Linux"                            WORKBENCH_OS=Darwin
        refuses "unknown family"            "not a supported distribution"              WORKBENCH_DISTRO=unknown
        ;;
    centos-all)
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=centos DNF_GEN=4
        AUTO_UPDATES_SCOPE=all install-auto-updates; rc=$?
        check "CentOS Stream with all: allowed" '[ ${rc} -eq 0 ] && [ "$(recorded scope)" = "all" ]'
        ;;
    no-dnf)
        fresh_host
        install-auto-updates; rc=$?
        check "rhel host without dnf: refused, nothing changed" '[ ${rc} -eq 1 ] && no_changes && out_has "dnf isn.t installed"'
        ;;
    suse-security-leap)
        fresh_host
        export WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap
        install-auto-updates; rc=$?
        check "Leap with security: allowed" '[ ${rc} -eq 0 ]'
        ;;
    dnf4-when-needed-first-install)
        # No packaged config yet: the package install creates it, then it's checked.
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=rocky DNF_GEN=4 AUTO_UPDATES_REBOOT=when-needed
        export PKG_CONF_SRC="${FIX}/dnf4-packaged-with-reboot"
        install-auto-updates; rc=$?
        check "DNF 4 when-needed on a fresh host: installs, checks the packaged config, writes the reboot line" '[ ${rc} -eq 0 ] && [ "$(installs)" = "1" ] && grep -qx "reboot = when-needed" "${_AUTO_UPDATES_DNF4_CONF}"'
        fresh_host
        export PKG_CONF_SRC="${FIX}/dnf4-packaged-without-reboot"
        install-auto-updates; rc=$?
        check "DNF 4 when-needed, packaged config turns out to lack it: refused after the install, nothing written or enabled" '[ ${rc} -eq 1 ] && out_has "too old to reboot" && [ ! -e "${_AUTO_UPDATES_DNF4_CONF}" ] && [ "$(enables)" = "0" ]'
        ;;
    dnf4-reload)
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=rocky DNF_GEN=4
        install-auto-updates; rc=$?
        check "DNF 4: first install writes both files and reloads systemd once" '[ ${rc} -eq 0 ] && [ -f "${_AUTO_UPDATES_DNF4_CONF}" ] && [ -f "${_AUTO_UPDATES_DNF4_DROPIN}" ] && [ "$(reloads)" = "1" ]'
        check "DNF 4: daemon-reload comes before the timer is enabled" 'line_before "^systemctl daemon-reload" "^systemctl enable"'
        install-auto-updates
        check "DNF 4: an unchanged rerun reloads nothing more" '[ "$(reloads)" = "1" ]'
        printf '%s\n' "# Written by workbench-distro (wb tools install auto-updates)." "[Service]" > "${_AUTO_UPDATES_DNF4_DROPIN}"
        install-auto-updates
        check "DNF 4: a changed drop-in is rewritten and triggers exactly one more reload" '[ "$(reloads)" = "2" ] && matches "${_AUTO_UPDATES_DNF4_DROPIN}" "${FIX}/dnf4-dropin/expected"'
        ;;
    apt-overrides)
        fresh_host
        export WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu
        printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "true";' > "${ETC}/apt.conf.d/20auto-upgrades"
        printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "true";' > "${ETC}/apt.conf.d/99local.dpkg-old"
        install-auto-updates
        check "apt: an earlier file, and a backup after it, set the same option: no warning" '! out_has "is read after workbench"'
        printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "true";' > "${ETC}/apt.conf.d/99local"
        install-auto-updates
        check "apt: a later 99local that sets Automatic-Reboot: warns, naming the file" 'out_has "99local is read after workbench"'
        check "apt: the warning doesn't name the earlier file" '! out_has "20auto-upgrades is read after"'
        ;;
    pop-warning)
        fresh_host
        export WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=pop
        install-auto-updates
        check "Pop with security: warns that Pop's own repository isn't covered" 'out_has "Pop!_OS.s own repository"'
        fresh_host
        AUTO_UPDATES_SCOPE=all install-auto-updates
        check "Pop with all: no such warning" '! out_has "Pop!_OS.s own repository"'
        ;;
    installed-check)
        fresh_host
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        check "no file: installed-auto-updates is false" '! installed-auto-updates'
        printf '%s\n' "# someone else's" > "${_AUTO_UPDATES_DNF5_CONF}"
        check "foreign file: false" '! installed-auto-updates'
        rm -f "${_AUTO_UPDATES_DNF5_CONF}"
        install-auto-updates
        check "workbench's file: true" 'installed-auto-updates'
        export WORKBENCH_DISTRO_ID=rocky DNF_GEN=4
        fresh_host
        install-auto-updates
        check "DNF 4, both files: true" 'installed-auto-updates'
        rm -f "${_AUTO_UPDATES_DNF4_DROPIN}"
        check "DNF 4, drop-in missing: false" '! installed-auto-updates'
        export WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch
        check "Arch: false" '! installed-auto-updates'
        export WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5
        fresh_host
        install-auto-updates
        export _AUTO_UPDATES_OSTREE_MARKER="${HOME}/marker"; : > "${HOME}/marker"
        check "an rpm-ostree host that has the file still answers: true (so REMOVAL-NOTES can report it)" 'installed-auto-updates'
        ;;
esac
EOF

# ── Shell-function scenarios (bash and zsh) ──────────────────────────────────
cat > "${WORK}/scenario-shell.sh" <<'EOF'
. "${WORK_DIR}/common.sh"
fresh_host
conf5="${_AUTO_UPDATES_DNF5_CONF}"

case "${SCENARIO}" in
    status-on)
        make_ours "${conf5}" "#" all when-needed dnf5-automatic.timer "[commands]"
        printf '%s\n' dnf5-automatic.timer > "${HOME}/enabled-timers"
        printf '%s\n' dnf5-plugin-automatic > "${HOME}/pkgs"
        printf '%s\n' "Sat 2026-11-28 06:12:00 UTC" > "${HOME}/next"
        printf '%s\n' "Fri 2026-11-27 06:20:01 UTC" > "${HOME}/lastrun"
        printf '%s\n' success > "${HOME}/result"
        out="$(distro-auto-updates)"; rc=$?
        check "status: on exits 0" '[ ${rc} -eq 0 ]'
        check "status: backend and package" 'has "backend:   dnf5-automatic (dnf5-plugin-automatic installed)"'
        check "status: config path, written by workbench" 'has "config:    ${conf5}, written by workbench"'
        check "status: scope and reboot from the state line" 'has "scope:     all" && has "reboot:    when-needed"'
        check "status: timer and next run" 'has "timer:     dnf5-automatic.timer enabled, next run Sat 2026-11-28 06:12:00 UTC"'
        check "status: last run and result" 'has "last run:  Fri 2026-11-27 06:20:01 UTC, success"'
        check "status: state on" 'has "state:     on"'
        check "status: says 'status' as the default and as an argument" '[ "$(distro-auto-updates)" = "$(distro-auto-updates status)" ]'
        check "status: never elevates" '! logged "^elev"'
        ;;
    status-off)
        make_ours "${conf5}" "#" security never none "[commands]"
        out="$(distro-auto-updates)"; rc=$?
        check "status: timer disabled exits 1" '[ ${rc} -eq 1 ]'
        check "status: shows the timer as disabled and state off" 'has "timer:     dnf5-automatic.timer disabled" && has "state:     off"'
        check "status: not run yet" 'has "last run:  not run yet"'
        ;;
    status-unknown-values)
        printf '%s\n' dnf5-automatic.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates)"; rc=$?
        check "status: an empty next-run value reads as unknown" 'has "next run unknown"'
        ;;
    status-dnf5-no-config)
        printf '%s\n' dnf5-automatic.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates)"; rc=$?
        check "status: dnf5 timer on with no config file: downloads only" '[ ${rc} -eq 0 ] && has "downloads only (dnf5 automatic" && has "state:     on"'
        check "status: no scope or reboot lines without a workbench file" '! has "scope:" && ! has "reboot:"'
        ;;
    status-foreign)
        printf '%s\n' "somebody else's file" > "${conf5}"
        out="$(distro-auto-updates)"; rc=$?
        check "status: a file without the marker is reported as written outside workbench" 'has "written outside workbench"'
        ;;
    status-unsupported)
        out="$(distro-auto-updates)"; rc=$?
        check "status: no backend exits 2 and points at the installer" '[ ${rc} -eq 2 ] && has "unsupported: run ${Q}wb tools install auto-updates${Q} to see why"'
        out="$(distro-auto-updates off)"; rc=$?
        check "off: no backend exits 2, same message" '[ ${rc} -eq 2 ] && has "unsupported"'
        ;;
    status-systemctl-fails)
        printf '%s\n' dnf5-automatic.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates 2>&1)"; rc=$?
        check "status: a failing systemctl exits 2, not 1" '[ ${rc} -eq 2 ]'
        ;;
    status-no-systemctl)
        out="$(distro-auto-updates 2>&1)"; rc=$?
        check "status: no systemctl exits 2 and says why" '[ ${rc} -eq 2 ] && out_has "systemctl"'
        ;;
    status-apt-default)
        printf '%s\n' apt-daily-upgrade.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates)"; rc=$?
        check "status: apt, no workbench file, apt-config reports 1: distribution default, on, exit 0" '[ ${rc} -eq 0 ] && has "distribution default (20auto-upgrades)" && has "state:     on"'
        ;;
    status-apt-periodic-off)
        printf '%s\n' apt-daily-upgrade.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates)"; rc=$?
        check "status: apt timer on but the periodic setting is 0: off, exit 1" '[ ${rc} -eq 1 ] && has "state:     off"'
        ;;
    status-suse)
        printf '%s\n' os-update.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates)"; rc=$?
        check "status: os-update timer on: exit 0, named os-update" '[ ${rc} -eq 0 ] && has "backend:   os-update (os-update not installed)"'
        ;;
    off-dnf5)
        make_ours "${conf5}" "#" all never dnf5-automatic.timer "[commands]"
        printf '%s\n' dnf5-automatic.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates off)"; rc=$?
        check "off: succeeds" '[ ${rc} -eq 0 ]'
        check "off: disables the recorded timer with the elevation command" 'logged "^elev systemctl disable --now dnf5-automatic.timer" && ! timer_enabled dnf5-automatic.timer'
        check "off: removes the file" '[ ! -e "${conf5}" ] && logged "^elev rm -f ${conf5}"'
        check "off: reports the timer and that the package stays, with the remove command" 'has "Disabled: dnf5-automatic.timer" && has "dnf5-plugin-automatic package is still installed; remove it with: sudo dnf remove dnf5-plugin-automatic"'
        out="$(distro-auto-updates off)"; rc=$?
        check "off again: nothing to undo, exit 0" '[ ${rc} -eq 0 ] && has "nothing to undo"'
        ;;
    off-pre-enabled)
        make_ours "${conf5}" "#" security never none "[commands]"
        printf '%s\n' dnf5-automatic.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates off)"; rc=$?
        check "off: a timer workbench didn't enable is never disabled" '[ ${rc} -eq 0 ] && timer_enabled dnf5-automatic.timer && ! logged "systemctl disable"'
        check "off: still removes the file, and says the timer keeps running" '[ ! -e "${conf5}" ] && has "Still enabled, because they were on before workbench: dnf5-automatic.timer"'
        ;;
    off-apt)
        export WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu
        make_ours "${_AUTO_UPDATES_APT_CONF}" "//" security never apt-daily-upgrade.timer 'APT::Periodic::Unattended-Upgrade "1";'
        printf '%s\n%s\n' apt-daily.timer apt-daily-upgrade.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates off)"; rc=$?
        check "off apt: disables only the recorded timer; apt-daily.timer stays on" '[ ${rc} -eq 0 ] && ! timer_enabled apt-daily-upgrade.timer && timer_enabled apt-daily.timer'
        check "off apt: says the distribution default still applies, with the dpkg-reconfigure command" 'has "sudo dpkg-reconfigure -plow unattended-upgrades" && has "still turn on unattended upgrades"'
        check "off apt: the package line uses apt" 'has "sudo apt remove unattended-upgrades"'
        ;;
    off-dnf4)
        export WORKBENCH_DISTRO_ID=rocky DNF_GEN=4
        make_ours "${_AUTO_UPDATES_DNF4_CONF}" "#" security never dnf-automatic.timer "[commands]"
        make_ours "${_AUTO_UPDATES_DNF4_DROPIN}" "#" x x x "[Service]"
        printf '%s\n' dnf-automatic.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates off)"; rc=$?
        check "off dnf4: removes both files, then reloads systemd once" '[ ${rc} -eq 0 ] && [ ! -e "${_AUTO_UPDATES_DNF4_CONF}" ] && [ ! -e "${_AUTO_UPDATES_DNF4_DROPIN}" ] && [ "$(grep -c "^systemctl daemon-reload" "${LOG}")" = "1" ]'
        fresh_host
        make_ours "${_AUTO_UPDATES_DNF4_CONF}" "#" security never none "[commands]"
        mkdir -p "$(dirname "${_AUTO_UPDATES_DNF4_DROPIN}")"
        printf '%s\n' "# administrator's own drop-in" > "${_AUTO_UPDATES_DNF4_DROPIN}"
        out="$(distro-auto-updates off)"; rc=$?
        check "off dnf4: a drop-in without the marker is left in place" '[ ! -e "${_AUTO_UPDATES_DNF4_CONF}" ] && [ -f "${_AUTO_UPDATES_DNF4_DROPIN}" ] && ! logged "rm -f ${_AUTO_UPDATES_DNF4_DROPIN}"'
        ;;
    off-nothing)
        printf '%s\n' "not ours" > "${conf5}"
        out="$(distro-auto-updates off)"; rc=$?
        check "off: no workbench file: says nothing to undo, exit 0, touches nothing" '[ ${rc} -eq 0 ] && has "workbench hasn${Q}t configured unattended updates here; nothing to undo." && [ -f "${conf5}" ] && ! logged "systemctl disable" && ! logged "rm -f"'
        fresh_host
        export WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu
        out="$(distro-auto-updates off)"; rc=$?
        check "off apt: no workbench file and apt-config reports 1: adds the dpkg-reconfigure line" '[ ${rc} -eq 0 ] && has "nothing to undo" && has "sudo dpkg-reconfigure -plow unattended-upgrades"'
        ;;
    off-failure)
        make_ours "${conf5}" "#" security never dnf5-automatic.timer "[commands]"
        printf '%s\n' dnf5-automatic.timer > "${HOME}/enabled-timers"
        out="$(distro-auto-updates off 2>&1)"; rc=$?
        check "off: a failing systemctl disable exits 1, says which timer is left, and still removes the file" '[ ${rc} -eq 1 ] && out_has "couldn.t disable dnf5-automatic.timer" && timer_enabled dnf5-automatic.timer && [ ! -e "${conf5}" ]'
        ;;
    usage)
        out="$(distro-auto-updates frobnicate 2>&1)"; rc=$?
        check "unknown action exits 2" '[ ${rc} -eq 2 ] && out_has "unknown action .frobnicate."'
        out="$(distro-auto-updates -h)"; rc=$?
        check "-h exits 0 and prints the usage" '[ ${rc} -eq 0 ] && has "Usage: distro-auto-updates [status|off]"'
        ;;
    silent-source)
        out="$(. "${REPO_ROOT}/shell/distro-auto-updates.sh" 2>&1)"
        check "sourcing the shell file prints nothing" '[ -z "${out}" ]'
        ;;
esac
EOF

# ── Runner ────────────────────────────────────────────────────────────────────
INSTALL_ENV="WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora DNF_GEN=5 WORK_DIR=${WORK}"

run_install() {
    local name="$1"
    shift
    # shellcheck disable=SC2086  # INSTALL_ENV is a VAR=value list on purpose
    report_scenario bash "" "$(run_scenario bash "${WORK}/scenario-install.sh" "${name}" \
        FILES="shell/installers-auto-updates.sh" ${INSTALL_ENV} "$@")"
}

run_shell() {
    local shell="$1" name="$2"
    shift 2
    # shellcheck disable=SC2086
    report_scenario "${shell}" "" "$(run_scenario "${shell}" "${WORK}/scenario-shell.sh" "${name}" \
        FILES="shell/distro-auto-updates.sh" ${INSTALL_ENV} "$@")"
}

for name in render render-literals first-install package-present first-install-apt first-install-suse \
    rerun recorded-survives one-field pre-enabled foreign-file foreign-file-after-install refusals \
    centos-all suse-security-leap dnf4-when-needed-first-install dnf4-reload apt-overrides pop-warning \
    installed-check; do
    run_install "${name}"
done
run_install no-dnf WITHOUT=dnf

for shell in $(test_shells); do
    run_shell "${shell}" status-on
    run_shell "${shell}" status-off
    run_shell "${shell}" status-unknown-values
    run_shell "${shell}" status-dnf5-no-config
    run_shell "${shell}" status-foreign
    run_shell "${shell}" status-unsupported WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch
    run_shell "${shell}" status-systemctl-fails FAIL_ON="systemctl is-enabled"
    run_shell "${shell}" status-no-systemctl WITHOUT=systemctl
    run_shell "${shell}" status-apt-default WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu APT_PERIODIC=1
    run_shell "${shell}" status-apt-periodic-off WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=ubuntu APT_PERIODIC=0
    run_shell "${shell}" status-suse WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap
    run_shell "${shell}" off-dnf5
    run_shell "${shell}" off-pre-enabled
    run_shell "${shell}" off-apt APT_PERIODIC=1
    run_shell "${shell}" off-dnf4
    run_shell "${shell}" off-nothing APT_PERIODIC=1
    run_shell "${shell}" off-failure FAIL_ON="systemctl disable"
    run_shell "${shell}" usage
    run_shell "${shell}" silent-source
done

finish
