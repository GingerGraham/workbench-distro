#!/usr/bin/env bash
# tests/check-debian-sources-rewrite.sh — workbench-distro
# _debian_sources_rewrite (shell/distro/debian.sh) against fixtures under
# tests/fixtures/apt/. Each fixture directory holds one input (in.list or
# in.sources) and, byte-compared:
#
#   expected, expected-report [, expected-stderr]
#       the plain run
#   expected-disabled, expected-report-disabled [, expected-stderr-disabled]
#       the --disable-third-party run; absent when it would be identical
#
# The awk is run under the host's default awk, and again under mawk and
# gawk when they are installed: Debian's default awk is mawk.
set -uo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib/harness.sh"

FIXTURES="${REPO_ROOT}/tests/fixtures/apt"

# One awk implementation per run: a directory with an "awk" link first on PATH.
AWKS="${WORK}/awks"
mkdir -p "${AWKS}"
awk_runs="default"
for _impl in mawk gawk; do
    if command -v "${_impl}" >/dev/null 2>&1; then
        mkdir -p "${AWKS}/${_impl}"
        ln -s "$(command -v "${_impl}")" "${AWKS}/${_impl}/awk"
        awk_runs="${awk_runs} ${_impl}"
    else
        skip "${_impl} is not installed — the fixtures were not run under it"
    fi
done

cat > "${WORK}/rewrite-one.sh" <<'EOF'
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }
_wb_declare_availability() { :; }
_wb_alias_availability() { :; }
. "${REPO_ROOT}/shell/distro/debian.sh"
cd "${FIXTURE}" || exit 1
infile="$(ls in.* | head -n 1)"
_debian_sources_rewrite "${infile}" "${OUTFILE}" bookworm trixie "${DISABLE}" > "${REPORT}" 2> "${ERRORS}"
echo "RC=$?"
EOF

# compare <label> <expected-file> <actual-file>
compare() {
    local label="$1" expected="$2" actual="$3"
    if cmp -s "${expected}" "${actual}"; then
        ok "${label}"
    else
        fail "${label}"
        diff -u "${expected}" "${actual}" | sed 's/^/        /'
    fi
}

run_fixture() {
    local awk_name="$1" shell="$2" dir="$3" disable="$4" suffix="$5" path_prefix="" name
    name="$(basename "${dir}")"
    if [[ "${awk_name}" != "default" ]]; then
        path_prefix="${AWKS}/${awk_name}:"
    fi
    local out="${WORK}/out-${awk_name}-${shell}-${name}-${disable}"
    mkdir -p "${out}"
    local rc_line
    rc_line="$(env -i HOME="${WORK}" PATH="${path_prefix}${HOSTBIN}" \
        REPO_ROOT="${REPO_ROOT}" FIXTURE="${dir}" DISABLE="${disable}" \
        OUTFILE="${out}/out" REPORT="${out}/report" ERRORS="${out}/errors" \
        "$(command -v "${shell}")" "$(shell_flags "${shell}")" "${WORK}/rewrite-one.sh" 2>&1 </dev/null)"
    local label="${awk_name} awk, ${shell}: ${name}${suffix:+ ($suffix)}"
    if [[ "${rc_line}" != "RC=0" ]]; then
        fail "${label}: rewrite returned '${rc_line}'"
        return
    fi
    local want_out="expected" want_report="expected-report" want_err="expected-stderr"
    if [[ "${disable}" == "true" ]]; then
        want_out="expected-disabled"
        want_report="expected-report-disabled"
        want_err="expected-stderr-disabled"
        # No separate disabled expectations: the run must match the plain one.
        [[ -f "${dir}/${want_out}" ]] || { want_out="expected"; want_report="expected-report"; want_err="expected-stderr"; }
    fi
    compare "${label}: file" "${dir}/${want_out}" "${out}/out"
    compare "${label}: report" "${dir}/${want_report}" "${out}/report"
    if [[ -f "${dir}/${want_err}" ]]; then
        compare "${label}: warnings" "${dir}/${want_err}" "${out}/errors"
    elif [[ -s "${out}/errors" ]]; then
        fail "${label}: unexpected warnings: $(cat "${out}/errors")"
    fi
}

for awk_name in ${awk_runs}; do
    for shell in $(test_shells); do
        for dir in "${FIXTURES}"/*/; do
            dir="${dir%/}"
            run_fixture "${awk_name}" "${shell}" "${dir}" false ""
            run_fixture "${awk_name}" "${shell}" "${dir}" true "--disable-third-party"
        done
    done
done

# ── Checks that don't need a fixture ────────────────────────────────────────

cat > "${WORK}/misc.sh" <<'EOF'
log_info()  { :; }
_wb_declare_availability() { :; }
_wb_alias_availability() { :; }
. "${REPO_ROOT}/shell/distro/debian.sh"
cd "${WORK}" || exit 1
printf 'deb http://deb.debian.org/debian bookworm main\n' > in.list
_debian_sources_rewrite in.list out.list 'bad name' trixie false >/dev/null 2>&1; echo "badold=$?"
_debian_sources_rewrite in.list out.list bookworm '' false >/dev/null 2>&1; echo "badnew=$?"
_debian_sources_rewrite in.list out.list bookworm trixie maybe >/dev/null 2>&1; echo "baddisable=$?"
_debian_sources_rewrite missing.list out.list bookworm trixie false >/dev/null 2>&1; echo "missing=$?"
# A command named in the output of the real run must not be needed: the
# rewrite never calls apt, dpkg or curl.
_debian_codename_lookup trixie; echo "lookup-name=$?"
_debian_codename_lookup 13; echo "lookup-number=$?"
_debian_codename_lookup sid; echo "lookup-none=$?"
EOF
for shell in $(test_shells); do
    out="$(env -i HOME="${WORK}" PATH="${HOSTBIN}" REPO_ROOT="${REPO_ROOT}" WORK="${WORK}" "$(command -v "${shell}")" "$(shell_flags "${shell}")" "${WORK}/misc.sh" 2>&1 </dev/null)"
    want="$(printf '%s\n' 'badold=2' 'badnew=2' 'baddisable=2' 'missing=1' '13 trixie' 'lookup-name=0' '13 trixie' 'lookup-number=0' 'lookup-none=1')"
    if [[ "${out}" == "${want}" ]]; then
        ok "${shell}: bad arguments are refused (2), a missing file is 1, the codename table resolves names and numbers"
    else
        fail "${shell}: argument and codename-table checks"
        printf '%s\n' "${out}" | sed 's/^/        /'
    fi
done

finish
