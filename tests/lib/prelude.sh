# tests/lib/prelude.sh — sourced at the top of a scenario, inside the clean
# bash or zsh that run_scenario starts. Stubs workbench-core's API, loads the
# module files named in $FILES, and defines the check helpers.
# Needs: REPO_ROOT, HOME, LOG, FILES (space-separated paths under the repo).
#
# Written for bash 3.2 and zsh alike: no word splitting on unquoted
# variables, no arrays.
# shellcheck shell=bash

R="${REPO_ROOT}"
OUT="${HOME}/out.log"
: > "${LOG}"
: > "${OUT}"

log_info()  { echo "INFO: $*"  >> "${OUT}"; }
log_warn()  { echo "WARN: $*"  >> "${OUT}"; }
log_error() { echo "ERROR: $*" >> "${OUT}"; }
get-elevation-command() { echo elev; }
_read_prompt() { echo "PROMPT: $1" >> "${OUT}"; eval "$2=\${ANSWER:-}"; }
_wb_declare_availability() { :; }
_wb_alias_availability() { :; }

WORKBENCH_OS="${WORKBENCH_OS:-Linux}"
WORKBENCH_WSL="${WORKBENCH_WSL:-false}"
export WORKBENCH_OS WORKBENCH_WSL

# _prelude_source_files — sources each path in $FILES, in order.
_prelude_source_files() {
    local rest="${FILES:-}" file
    while [ -n "${rest}" ]; do
        file="${rest%% *}"
        case "${rest}" in
            *" "*) rest="${rest#* }" ;;
            *)     rest="" ;;
        esac
        . "${R}/${file}"
    done
}
_prelude_source_files

# Scenario knobs, applied after the module files so they win.
_distro_have_tty() { [ "${HAVE_TTY:-1}" = "1" ]; }
_distro_elev()     { echo elev; }

logged()   { grep -q -- "$1" "${LOG}"; }
out_has()  { grep -q -- "$1" "${OUT}"; }
# line_before <earlier> <later>: both logged, earlier first
line_before() {
    local a b
    a="$(grep -n -- "$1" "${LOG}" | head -n 1 | cut -d: -f1)"
    b="$(grep -n -- "$2" "${LOG}" | head -n 1 | cut -d: -f1)"
    [ -n "${a}" ] && [ -n "${b}" ] && [ "${a}" -lt "${b}" ]
}
# ran_nothing: no external command was called at all
ran_nothing() { [ ! -s "${LOG}" ]; }
check() { if eval "$2"; then echo "PASS:$1"; else echo "BAD:$1"; fi; }
