#!/usr/bin/env bash
# tests/check-distro-dispatch.sh — workbench-distro
# distro-update, distro-upgrade, distro-reboot-required, distro-info and the
# per-family update commands (dnf-update, apt-update, pacman-update,
# yay-update, paru-update, zypper-update). Plain bash, numbered OK:/FAIL:
# checks. No network, no root and no real package manager: every external
# tool is a fake that logs what it was called with. Each scenario runs in a
# clean bash, and in zsh when it is installed.
#
#   - distro-update picks the updater for the family, then Flatpak only when
#     it is installed and not skipped, and says when a reboot is wanted;
#   - a failed upgrade stops the run: no autoremove, no Flatpak;
#   - --ask drops the non-interactive flag; an unknown option exits 2;
#   - rpm-ostree hosts are refused with the rpm-ostree command to use;
#   - distro-upgrade dispatches per ID, says "rolling" or "not handled";
#   - WSL is never reported as a container;
#   - on Omarchy every Arch updater hands over to Omarchy's updater;
#   - distro-reboot-required per family, on DNF 4 and DNF 5;
#   - sourcing the module files prints nothing.
set -uo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib/harness.sh"

# ── Fakes ─────────────────────────────────────────────────────────────────────
# readlink -f: DNF 5 links dnf to dnf5, DNF 4 keeps dnf-3.
fake readlink 'case "${DNF_GEN:-5}" in 5) echo /usr/bin/dnf5 ;; *) echo /usr/bin/dnf-3 ;; esac'
fake dnf 'case "$*" in needs-restarting*) exit "${NR_RC:-0}" ;; esac'
fake apt-get
fake pacman
fake paccache
fake yay
fake paru
fake flatpak
fake zypper 'case "$*" in needs-rebooting*) exit "${ZYPPER_NEEDS_REBOOTING_RC:-0}" ;; esac'
fake omarchy-update
fake systemd-detect-virt 'exit "${SDV_RC:-1}"'

# os-release fixtures
OSREL="${WORK}/osrel"
mkdir -p "${OSREL}"
printf 'ID=fedora\nVERSION_ID=44\nVARIANT_ID=workstation\n' > "${OSREL}/fedora"
printf 'ID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n' > "${OSREL}/debian"
touch "${WORK}/ostree-booted"
mkdir -p "${WORK}/modules-present/6.1.0" "${WORK}/modules-missing"

RHEL_FILES="shell/distro.sh shell/distro/rhel.sh shell/distro/fedora.sh"
DEBIAN_FILES="shell/distro.sh shell/distro/debian.sh"
ARCH_FILES="shell/distro.sh shell/distro/arch.sh"
SUSE_FILES="shell/distro.sh shell/distro/suse.sh shell/distro/opensuse-leap.sh"

cat > "${WORK}/scenario.sh" <<'EOF'
. "${REPO_ROOT}/tests/lib/prelude.sh"

case "${SCENARIO}" in
    # ── distro-update ───────────────────────────────────────────────────────
    update-rhel)
        distro-update; rc=$?
        check "rhel: succeeds" '[ ${rc} -eq 0 ]'
        check "rhel: dnf upgrade --refresh -y" 'logged "^dnf upgrade --refresh -y$"'
        check "rhel: dnf autoremove -y" 'logged "^dnf autoremove -y$"'
        check "rhel: order is upgrade, autoremove, flatpak" 'line_before "^dnf upgrade" "^dnf autoremove" && line_before "^dnf autoremove" "^flatpak update"'
        check "rhel: flatpak update is non-interactive" 'logged "^flatpak update -y --noninteractive$"'
        check "rhel: no clean without --clean" '! logged "dnf clean"'
        check "rhel: everything went through the elevation command" '! grep -q "^dnf" "${LOG}" || grep -q "^elev dnf upgrade" "${LOG}"'
        ;;
    update-no-flatpak-flag)
        distro-update --no-flatpak; rc=$?
        check "--no-flatpak: succeeds" '[ ${rc} -eq 0 ]'
        check "--no-flatpak: flatpak not called" '! logged "^flatpak"'
        check "--no-flatpak: dnf still ran" 'logged "^dnf upgrade"'
        ;;
    update-no-flatpak-installed)
        distro-update; rc=$?
        check "no flatpak installed: succeeds" '[ ${rc} -eq 0 ]'
        check "no flatpak installed: flatpak is never called" '! logged "^flatpak"'
        ;;
    update-upgrade-fails)
        distro-update; rc=$?
        check "failed dnf upgrade: non-zero status" '[ ${rc} -ne 0 ]'
        check "failed dnf upgrade: no autoremove" '! logged "autoremove"'
        check "failed dnf upgrade: no flatpak update" '! logged "^flatpak"'
        ;;
    update-flatpak-fails)
        distro-update; rc=$?
        check "flatpak failure: packages were updated, so still succeeds" '[ ${rc} -eq 0 ]'
        check "flatpak failure: warns" 'out_has "WARN: distro-update: flatpak update failed"'
        ;;
    update-reboot-advice)
        distro-update; rc=$?
        check "reboot needed: says so" 'out_has "WARN: distro-update: a reboot is recommended"'
        check "reboot needed: still succeeds" '[ ${rc} -eq 0 ]'
        ;;
    update-ask)
        dnf-update --ask; rc=$?
        check "--ask: succeeds" '[ ${rc} -eq 0 ]'
        check "--ask: upgrade without -y" 'logged "^dnf upgrade --refresh$"'
        check "--ask: autoremove without -y" 'logged "^dnf autoremove$"'
        ;;
    update-clean)
        dnf-update --clean; rc=$?
        check "--clean: dnf clean packages runs after autoremove" 'line_before "^dnf autoremove" "^dnf clean packages$"'
        ;;
    update-bad-option)
        dnf-update --bogus; rc1=$?
        distro-update --bogus; rc2=$?
        apt-update --bogus 2>/dev/null; rc3=$?
        check "unknown option: dnf-update exits 2" '[ ${rc1} -eq 2 ]'
        check "unknown option: distro-update exits 2" '[ ${rc2} -eq 2 ]'
        check "unknown option: nothing ran" 'ran_nothing'
        ;;
    update-ostree)
        dnf-update; rc=$?
        check "rpm-ostree: refused" '[ ${rc} -ne 0 ]'
        check "rpm-ostree: points at rpm-ostree upgrade" 'out_has "rpm-ostree upgrade"'
        check "rpm-ostree: no dnf call" '! logged "^dnf"'
        ;;
    update-debian)
        distro-update; rc=$?
        check "debian: succeeds" '[ ${rc} -eq 0 ]'
        check "debian: apt-get update, upgrade, autoremove, autoclean in order" 'line_before "^apt-get update$" "^apt-get upgrade -y$" && line_before "^apt-get upgrade -y$" "^apt-get autoremove -y$" && line_before "^apt-get autoremove -y$" "^apt-get autoclean -y$"'
        check "debian: apt, not apt-get's unstable front-end, is never called" '! logged "^apt "'
        ;;
    update-debian-full)
        apt-update --full; rc=$?
        check "--full: full-upgrade instead of upgrade" 'logged "^apt-get full-upgrade -y$" && ! logged "^apt-get upgrade"'
        ;;
    update-debian-ask)
        apt-update --ask; rc=$?
        check "--ask: no -y anywhere" '! logged " -y"'
        ;;
    update-debian-fails)
        distro-update; rc=$?
        check "failed apt-get upgrade: non-zero, no autoremove" '[ ${rc} -ne 0 ] && ! logged "autoremove"'
        ;;
    update-arch)
        pacman-update; rc=$?
        check "arch: pacman -Syu --noconfirm" 'logged "^pacman -Syu --noconfirm$"'
        check "arch: paccache runs after the upgrade" 'line_before "^pacman -Syu" "^paccache -r$"'
        ;;
    update-arch-no-paccache)
        pacman-update; rc=$?
        check "arch without pacman-contrib: still succeeds" '[ ${rc} -eq 0 ]'
        check "arch without pacman-contrib: no paccache call" '! logged "paccache"'
        ;;
    update-arch-ask)
        pacman-update --ask; rc=$?
        check "arch --ask: no --noconfirm" 'logged "^pacman -Syu$"'
        ;;
    update-arch-aur)
        yay-update; paru-update
        check "yay: yay -Syu --noconfirm, unelevated" 'logged "^yay -Syu --noconfirm$" && ! logged "^elev yay"'
        check "paru: paru -Syu --noconfirm, unelevated" 'logged "^paru -Syu --noconfirm$" && ! logged "^elev paru"'
        ;;
    update-arch-fails)
        distro-update; rc=$?
        check "failed pacman upgrade: non-zero, no paccache, no flatpak" '[ ${rc} -ne 0 ] && ! logged "paccache" && ! logged "flatpak"'
        ;;
    update-omarchy)
        pacman-update; r1=$?
        yay-update;    r2=$?
        paru-update;   r3=$?
        check "omarchy: the Omarchy updater ran for each of the three" '[ "$(grep -c "^omarchy-update" "${LOG}")" = "3" ]'
        check "omarchy: pacman, yay and paru were not run" '! logged "^pacman" && ! logged "^yay" && ! logged "^paru"'
        check "omarchy: says it is handing over" 'out_has "handing over to .omarchy-update"'
        check "omarchy: returns the updater status" '[ ${r1} -eq 0 ] && [ ${r2} -eq 0 ] && [ ${r3} -eq 0 ]'
        ;;
    update-omarchy-fails)
        pacman-update; rc=$?
        check "omarchy updater failing: its status is returned" '[ ${rc} -ne 0 ]'
        ;;
    update-suse-leap)
        zypper-update; rc=$?
        check "leap: non-interactive refresh" 'logged "^zypper --non-interactive refresh$"'
        check "leap: zypper update, not dup" 'logged "^zypper --non-interactive update$" && ! logged " dup"'
        ;;
    update-suse-tumbleweed)
        zypper-update --clean; rc=$?
        check "tumbleweed: zypper dup" 'logged "^zypper --non-interactive dup$" && ! logged " update$"'
        check "tumbleweed --clean: zypper clean -a" 'line_before " dup$" "^zypper clean -a$"'
        ;;
    update-suse-ask)
        zypper-update --ask; rc=$?
        check "suse --ask: no --non-interactive" '! logged "non-interactive" && logged "^zypper refresh$"'
        ;;

    # ── distro-upgrade ──────────────────────────────────────────────────────
    upgrade-dispatch)
        fedora-release-upgrade()   { echo "CALLED fedora $*" >> "${LOG}"; }
        debian-release-upgrade()   { echo "CALLED debian $*" >> "${LOG}"; }
        ubuntu-release-upgrade()   { echo "CALLED ubuntu $*" >> "${LOG}"; }
        pop-release-upgrade()      { echo "CALLED pop $*" >> "${LOG}"; }
        opensuse-release-upgrade() { echo "CALLED opensuse-leap $*" >> "${LOG}"; }
        for id in fedora debian ubuntu pop opensuse-leap; do
            WORKBENCH_DISTRO_ID="${id}" distro-upgrade 45
        done
        check "dispatch: fedora with its argument" 'logged "^CALLED fedora 45$"'
        check "dispatch: debian" 'logged "^CALLED debian 45$"'
        check "dispatch: ubuntu" 'logged "^CALLED ubuntu 45$"'
        check "dispatch: pop" 'logged "^CALLED pop 45$"'
        check "dispatch: opensuse-leap" 'logged "^CALLED opensuse-leap 45$"'
        ;;
    upgrade-rolling)
        okrc=0
        for id in arch manjaro endeavouros garuda opensuse-tumbleweed opensuse-slowroll; do
            : > "${OUT}"
            WORKBENCH_DISTRO_ID="${id}" distro-upgrade || okrc=1
            out_has "rolling release" || okrc=1
        done
        check "rolling: each of six rolling IDs says so and returns 0" '[ ${okrc} -eq 0 ]'
        check "rolling: nothing ran" 'ran_nothing'
        ;;
    upgrade-not-handled)
        WORKBENCH_DISTRO_ID=rocky distro-upgrade; rc=$?
        check "rocky: refused" '[ ${rc} -ne 0 ]'
        check "rocky: says it is not handled" 'out_has "aren.t handled by workbench"'
        WORKBENCH_DISTRO_ID=nixos distro-upgrade; rc=$?
        check "unknown ID: refused" '[ ${rc} -ne 0 ] && out_has "aren.t supported on .nixos"'
        ;;
    upgrade-not-loaded)
        WORKBENCH_DISTRO_ID=fedora distro-upgrade; rc=$?
        check "target not loaded: says to start a new shell" '[ ${rc} -ne 0 ] && out_has "isn.t loaded in this shell"'
        ;;

    # ── containers and WSL ──────────────────────────────────────────────────
    wsl-not-container)
        WORKBENCH_WSL=true
        _distro_in_container; rc=$?
        check "WSL: never a container, even when systemd-detect-virt says so" '[ ${rc} -ne 0 ]'
        ;;
    container-by-virt)
        WORKBENCH_WSL=false
        _distro_in_container; rc=$?
        check "outside WSL, systemd-detect-virt reporting a container counts" '[ ${rc} -eq 0 ]'
        ;;

    # ── distro-reboot-required ──────────────────────────────────────────────
    reboot-debian-yes)
        printf 'libc6\n' > "${HOME}/reboot-required.pkgs"
        : > "${HOME}/reboot-required"
        _DISTRO_REBOOT_REQUIRED_FILE="${HOME}/reboot-required"
        out="$(distro-reboot-required)"; rc=$?
        check "debian, file present: exit 0 and yes" '[ ${rc} -eq 0 ] && case "${out}" in yes*) true ;; *) false ;; esac'
        check "debian, file present: lists the packages" 'case "${out}" in *libc6*) true ;; *) false ;; esac'
        ;;
    reboot-debian-no)
        _DISTRO_REBOOT_REQUIRED_FILE="${HOME}/absent"
        out="$(distro-reboot-required)"; rc=$?
        check "debian, no file: exit 1 and no" '[ ${rc} -eq 1 ] && [ "${out}" = "no" ]'
        ;;
    reboot-rhel-dnf5)
        NR_RC=1 distro-reboot-required; r1=$?
        check "rhel DNF 5, needs-restarting exits 1: reboot (exit 0)" '[ ${r1} -eq 0 ]'
        check "rhel DNF 5: plain needs-restarting, unelevated" 'logged "^dnf needs-restarting$" && ! logged "elev"'
        : > "${LOG}"
        NR_RC=0 distro-reboot-required; r2=$?
        check "rhel DNF 5, needs-restarting exits 0: no reboot (exit 1)" '[ ${r2} -eq 1 ]'
        out="$(NR_RC=2 distro-reboot-required)"; r3=$?
        check "rhel DNF 5, needs-restarting fails: can't tell (exit 2), names dnf5-plugins" '[ ${r3} -eq 2 ] && case "${out}" in *dnf5-plugins*) true ;; *) false ;; esac'
        ;;
    reboot-rhel-dnf4)
        NR_RC=1 distro-reboot-required; r1=$?
        check "rhel DNF 4: needs-restarting -r, exit 1 means reboot" '[ ${r1} -eq 0 ] && logged "^dnf needs-restarting -r$"'
        out="$(NR_RC=3 distro-reboot-required)"; r2=$?
        check "rhel DNF 4, plugin missing: can't tell, names dnf-plugins-core" '[ ${r2} -eq 2 ] && case "${out}" in *dnf-plugins-core*) true ;; *) false ;; esac'
        ;;
    reboot-rhel-ostree)
        distro-reboot-required >/dev/null; rc=$?
        check "rhel on rpm-ostree: can't tell" '[ ${rc} -eq 2 ]'
        ;;
    reboot-arch)
        _DISTRO_MODULES_DIR="${WORK_MODULES_MISSING}"
        distro-reboot-required >/dev/null; r1=$?
        check "arch, running kernel's modules gone: reboot" '[ ${r1} -eq 0 ]'
        mkdir -p "${HOME}/modules/$(uname -r)"
        _DISTRO_MODULES_DIR="${HOME}/modules"
        distro-reboot-required >/dev/null; r2=$?
        check "arch, running kernel's modules present: no reboot" '[ ${r2} -eq 1 ]'
        _DISTRO_MODULES_DIR="${WORK_MODULES_MISSING}"
        WORKBENCH_WSL=true distro-reboot-required >/dev/null; r3=$?
        check "arch on WSL: the kernel belongs to Windows, so no reboot" '[ ${r3} -eq 1 ]'
        ;;
    reboot-suse)
        ZYPPER_NEEDS_REBOOTING_RC=102 distro-reboot-required >/dev/null; r1=$?
        ZYPPER_NEEDS_REBOOTING_RC=0 distro-reboot-required >/dev/null;   r2=$?
        ZYPPER_NEEDS_REBOOTING_RC=7 distro-reboot-required >/dev/null;   r3=$?
        check "suse: exit 102 is a reboot (0)" '[ ${r1} -eq 0 ]'
        check "suse: exit 0 is no reboot (1)" '[ ${r2} -eq 1 ]'
        check "suse: any other exit is can't tell (2)" '[ ${r3} -eq 2 ]'
        ;;
    reboot-unknown)
        out="$(distro-reboot-required)"; rc=$?
        check "unsupported system: can't tell" '[ ${rc} -eq 2 ]'
        ;;
    reboot-never-elevates)
        NR_RC=1 distro-reboot-required >/dev/null
        check "reboot check never calls the elevation command" '! logged "^elev"'
        ;;

    # ── distro-info ─────────────────────────────────────────────────────────
    info-fedora)
        out="$(distro-info)"; rc=$?
        check "info: succeeds" '[ ${rc} -eq 0 ]'
        check "info: family" 'case "${out}" in *"family: rhel"*) true ;; *) false ;; esac'
        check "info: ID" 'case "${out}" in *"id: fedora"*) true ;; *) false ;; esac'
        check "info: VERSION_ID" 'case "${out}" in *"version_id: 44"*) true ;; *) false ;; esac'
        check "info: VARIANT_ID when set" 'case "${out}" in *"variant_id: workstation"*) true ;; *) false ;; esac'
        check "info: no codename line when unset" 'case "${out}" in *version_codename*) false ;; *) true ;; esac'
        check "info: WSL, container and rpm-ostree answered" 'case "${out}" in *"wsl: no"*"rpm-ostree: no"*) true ;; *) false ;; esac'
        check "info: DNF generation on rhel" 'case "${out}" in *"dnf: 5"*) true ;; *) false ;; esac'
        check "info: ran nothing elevated" '! logged "^elev"'
        ;;
    info-debian-wsl)
        out="$(distro-info)"
        check "info: codename when set" 'case "${out}" in *"version_codename: bookworm"*) true ;; *) false ;; esac'
        check "info: WSL yes with its name" 'case "${out}" in *"wsl: yes"*"wsl_distro_name: Debian"*) true ;; *) false ;; esac'
        check "info: no dnf line off the rhel family" 'case "${out}" in *"dnf:"*) false ;; *) true ;; esac'
        ;;

    # ── Shell start stays silent ────────────────────────────────────────────
    silent)
        bad=""
        for f in shell/distro.sh shell/distro/rhel.sh shell/distro/fedora.sh shell/distro/debian.sh shell/distro/ubuntu.sh shell/distro/pop.sh shell/distro/arch.sh shell/distro/suse.sh shell/distro/opensuse-leap.sh shell/installers.sh; do
            printed="$(. "${R}/${f}" 2>&1)"
            [ -z "${printed}" ] || bad="${bad} ${f}"
        done
        check "sourcing every file prints nothing${bad:+ (printed:${bad})}" '[ -z "${bad}" ]'
        ;;
esac
EOF

# run <shell> <scenario> <files> [VAR=value ...] — one scenario, reported.
run() {
    local shell="$1" name="$2" files="$3"
    shift 3
    report_scenario "${shell}" "" "$(run_scenario "${shell}" "${WORK}/scenario.sh" "${name}" FILES="${files}" "$@")"
}

# ostree marker and module directories for the scenarios that need them
OSTREE="_DISTRO_OSTREE_MARKER=${WORK}/ostree-booted"
NO_OSTREE="_DISTRO_OSTREE_MARKER=${WORK}/does-not-exist"
FEDORA="WORKBENCH_DISTRO=rhel WORKBENCH_DISTRO_ID=fedora _DISTRO_OS_RELEASE=${OSREL}/fedora"
DEBIAN="WORKBENCH_DISTRO=debian WORKBENCH_DISTRO_ID=debian _DISTRO_OS_RELEASE=${OSREL}/debian"

for shell in $(test_shells); do
    # shellcheck disable=SC2086  # the *_ENV words are VAR=value lists on purpose
    {
        run "${shell}" update-rhel "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} NR_RC=0
        run "${shell}" update-no-flatpak-flag "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE}
        run "${shell}" update-no-flatpak-installed "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} WITHOUT=flatpak
        run "${shell}" update-upgrade-fails "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} FAIL_ON='^dnf upgrade'
        run "${shell}" update-flatpak-fails "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} FAIL_ON='^flatpak'
        run "${shell}" update-reboot-advice "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} NR_RC=1
        run "${shell}" update-ask "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE}
        run "${shell}" update-clean "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE}
        run "${shell}" update-bad-option "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE}
        run "${shell}" update-ostree "${RHEL_FILES}" ${FEDORA} ${OSTREE}

        run "${shell}" update-debian "${DEBIAN_FILES}" ${DEBIAN}
        run "${shell}" update-debian-full "${DEBIAN_FILES}" ${DEBIAN}
        run "${shell}" update-debian-ask "${DEBIAN_FILES}" ${DEBIAN}
        run "${shell}" update-debian-fails "${DEBIAN_FILES}" ${DEBIAN} FAIL_ON='^apt-get upgrade'

        run "${shell}" update-arch "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch WITHOUT="omarchy-update flatpak"
        run "${shell}" update-arch-no-paccache "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch WITHOUT="omarchy-update flatpak paccache"
        run "${shell}" update-arch-ask "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch WITHOUT="omarchy-update flatpak"
        run "${shell}" update-arch-aur "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch WITHOUT="omarchy-update flatpak"
        run "${shell}" update-arch-fails "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch WITHOUT="omarchy-update" FAIL_ON='^pacman'
        run "${shell}" update-omarchy "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch
        run "${shell}" update-omarchy-fails "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch FAIL_ON='^omarchy-update'

        run "${shell}" update-suse-leap "${SUSE_FILES}" WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap
        run "${shell}" update-suse-tumbleweed "${SUSE_FILES}" WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-tumbleweed
        run "${shell}" update-suse-ask "${SUSE_FILES}" WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap

        run "${shell}" upgrade-dispatch "${RHEL_FILES}" ${FEDORA}
        run "${shell}" upgrade-rolling "${RHEL_FILES}" ${FEDORA}
        run "${shell}" upgrade-not-handled "${RHEL_FILES}" ${FEDORA}
        run "${shell}" upgrade-not-loaded "shell/distro.sh" ${FEDORA}

        run "${shell}" wsl-not-container "shell/distro.sh" ${FEDORA} SDV_RC=0
        run "${shell}" container-by-virt "shell/distro.sh" ${FEDORA} SDV_RC=0

        run "${shell}" reboot-debian-yes "${DEBIAN_FILES}" ${DEBIAN}
        run "${shell}" reboot-debian-no "${DEBIAN_FILES}" ${DEBIAN}
        run "${shell}" reboot-rhel-dnf5 "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} DNF_GEN=5
        run "${shell}" reboot-rhel-dnf4 "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} DNF_GEN=4
        run "${shell}" reboot-rhel-ostree "${RHEL_FILES}" ${FEDORA} ${OSTREE}
        run "${shell}" reboot-arch "${ARCH_FILES}" WORKBENCH_DISTRO=arch WORKBENCH_DISTRO_ID=arch WORK_MODULES_MISSING="${WORK}/modules-missing"
        run "${shell}" reboot-suse "${SUSE_FILES}" WORKBENCH_DISTRO=suse WORKBENCH_DISTRO_ID=opensuse-leap
        run "${shell}" reboot-unknown "shell/distro.sh" WORKBENCH_DISTRO=unknown WORKBENCH_DISTRO_ID=unknown
        run "${shell}" reboot-never-elevates "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE} NR_RC=1

        run "${shell}" info-fedora "${RHEL_FILES}" ${FEDORA} ${NO_OSTREE}
        run "${shell}" info-debian-wsl "${DEBIAN_FILES}" ${DEBIAN} WORKBENCH_WSL=true WSL_DISTRO_NAME=Debian
        run "${shell}" silent "${RHEL_FILES}" ${FEDORA}
    }
done

finish
