#!/usr/bin/env bash
# tests/lib/harness.sh — shared by tests/check-*.sh in workbench-distro.
# Plain bash, numbered OK:/FAIL: checks, no framework. Sourced, not run.
#
# Provides ok/fail/skip counters, a scratch directory, a way to build fake
# commands that log what they were called with, and a way to run one test
# scenario in a clean bash or zsh with those fakes first on PATH.

# shellcheck disable=SC2016  # the fakes are written from single-quoted scripts on purpose
SCRIPT_DIR="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(builtin cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

# shell_flags <shell> — zsh skips its rc files with -f; bash needs nothing
# (and -f would switch off globbing).
shell_flags() {
    if [[ "$1" == "zsh" ]]; then
        echo "-f"
    else
        echo "--noprofile"
    fi
}

# The shells a scenario runs under: bash always, zsh when installed.
test_shells() {
    echo bash
    if command -v zsh >/dev/null 2>&1; then
        echo zsh
    fi
}

finish() {
    echo
    if [[ "${FAILED}" -eq 0 ]]; then
        echo "All ${check_no} checks passed."
        exit 0
    fi
    echo "${FAILED} of ${check_no} checks FAILED."
    exit 1
}

# ── Fakes ─────────────────────────────────────────────────────────────────────
# Host tools the module's code calls, linked into one directory so a scenario's
# PATH can leave out everything else (the real host may have dnf, apt or
# flatpak). Nothing that writes or deletes is linked.
HOSTBIN="${WORK}/hostbin"
FAKES="${WORK}/fakes"
mkdir -p "${HOSTBIN}" "${FAKES}"
for _t in find stat ls cat cut grep head sed awk tr basename dirname sort date uname id mkdir mktemp rm cp cmp diff wc tail env; do
    # The real binary, not a wrapper that happens to be first on this PATH.
    _p=""
    for _dir in /usr/bin /bin; do
        if [[ -x "${_dir}/${_t}" ]]; then
            _p="${_dir}/${_t}"
            break
        fi
    done
    [[ -n "${_p}" ]] || _p="$(command -v "${_t}")" || continue
    case "${_p}" in
        /*) ln -s "${_p}" "${HOSTBIN}/${_t}" 2>/dev/null ;;
    esac
done

# fake <name> [<sh to run after logging, before the default exit 0>]
# Every fake appends "<name> <args>" to $LOG and exits 1 when its arguments
# match the extended regex in $FAIL_ON.
fake() {
    {
        printf '#!/bin/sh\n'
        printf 'echo "%s${*:+ $*}" >> "$LOG"\n' "$1"
        printf '[ -n "$FAIL_ON" ] && echo "%s${*:+ $*}" | grep -Eq -e "$FAIL_ON" && exit 1\n' "$1"
        printf '%s\n' "${2:-}"
        printf 'exit 0\n'
    } > "${FAKES}/$1"
    chmod +x "${FAKES}/$1"
}

# A command that must never run as root-only: "elev" just runs its argument.
printf '#!/bin/sh\necho "elev $*" >> "$LOG"\nexec "$@"\n' > "${FAKES}/elev"
chmod +x "${FAKES}/elev"

# run_scenario <shell> <scenario-file> <scenario-name> [VAR=value ...]
# Runs the scenario file in a clean shell. Prints its PASS:/BAD: lines.
# WITHOUT="cmd cmd" among the VAR=value arguments leaves those fakes out of
# the scenario's PATH, to test a command that isn't installed.
run_scenario() {
    local shell="$1" file="$2" name="$3"
    shift 3
    local home="${WORK}/home-${shell}-${name}" bindir without="" arg fake_name skip_it excluded
    mkdir -p "${home}"
    for arg in "$@"; do
        case "${arg}" in
            WITHOUT=*) without="${arg#WITHOUT=}" ;;
        esac
    done
    bindir="${home}/bin"
    rm -rf "${bindir}"
    mkdir -p "${bindir}"
    for fake_name in $(ls "${FAKES}"); do
        skip_it="no"
        for excluded in ${without}; do
            [[ "${excluded}" == "${fake_name}" ]] && skip_it="yes"
        done
        [[ "${skip_it}" == "yes" ]] || ln -s "${FAKES}/${fake_name}" "${bindir}/${fake_name}"
    done
    env -i HOME="${home}" PATH="${bindir}:${HOSTBIN}" TERM=dumb \
        LOG="${home}/calls.log" FAIL_ON="" REPO_ROOT="${REPO_ROOT}" SCENARIO="${name}" \
        "$@" "$(command -v "${shell}")" "$(shell_flags "${shell}")" "${file}" 2>&1 </dev/null
}

# report_scenario <shell> <label-prefix> <output of run_scenario>
# Turns PASS:/BAD: lines into ok/fail. Anything else is shown only if there
# was no PASS/BAD line at all (the scenario itself broke).
report_scenario() {
    local shell="$1" prefix="$2" out="$3" line seen=0
    while IFS= read -r line; do
        case "${line}" in
            PASS:*) seen=1; ok "${shell}: ${prefix}${line#PASS:}" ;;
            BAD:*)  seen=1; fail "${shell}: ${prefix}${line#BAD:}" ;;
        esac
    done <<EOF
${out}
EOF
    if [[ "${seen}" -eq 0 ]]; then
        fail "${shell}: ${prefix}scenario printed no checks"
        printf '%s\n' "${out}" | sed 's/^/        /'
    fi
}
