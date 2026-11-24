#!/usr/bin/env bash
# shell/distro/debian.sh — workbench-distro (distro tier, debian family)
# Loads on Debian, Ubuntu, Pop!_OS and Mint. debian-release-upgrade is for
# Debian itself and guards on WORKBENCH_DISTRO_ID (workbench-core D126: a
# file named after a family loads for the whole family).

# ── Overridable for tests only ────────────────────────────────────────────────
_DISTRO_APT_DIR="${_DISTRO_APT_DIR:-/etc/apt}"
_DISTRO_BACKUP_ROOT="${_DISTRO_BACKUP_ROOT:-/var/backups/workbench-distro}"
_DISTRO_DEBIAN_VERSION_FILE="${_DISTRO_DEBIAN_VERSION_FILE:-/etc/debian_version}"

# Release number and codename, as one string table (no arrays: bash 3.2 and
# zsh). Add a pair when Debian publishes the next release.
_DEBIAN_CODENAMES="12:bookworm 13:trixie 14:forky 15:duke"

_wb_declare_availability apt-get apt-update

# ── apt-update ────────────────────────────────────────────────────────────────

apt-update() {
    local assume="-y" upgrade_verb="upgrade" arg elev
    for arg in "$@"; do
        case "${arg}" in
            --ask)  assume="" ;;
            --full) upgrade_verb="full-upgrade" ;;
            -h|--help)
                printf '%s\n' "Usage: apt-update [--ask] [--full]" \
                    "apt-get update, upgrade, autoremove, autoclean. --full uses full-upgrade, which may install or remove packages to resolve dependencies. --ask confirms each step."
                return 0
                ;;
            *) log_error "apt-update: unknown option '${arg}'"; return 2 ;;
        esac
    done
    elev="$(_distro_elev)" || return 1

    log_info "apt-update: refreshing package lists"
    # shellcheck disable=SC2086
    ${elev} apt-get update || { log_error "apt-update: update failed; nothing was upgraded"; return 1; }
    log_info "apt-update: ${upgrade_verb}"
    # shellcheck disable=SC2086
    ${elev} apt-get ${upgrade_verb} ${assume} || { log_error "apt-update: ${upgrade_verb} failed; autoremove skipped"; return 1; }
    log_info "apt-update: removing packages nothing needs any more"
    # shellcheck disable=SC2086
    ${elev} apt-get autoremove ${assume} || return 1
    # shellcheck disable=SC2086
    ${elev} apt-get autoclean ${assume} || return 1
    return 0
}

# ── Sources rewrite (pure, testable) ──────────────────────────────────────────
#
# _debian_sources_rewrite <in-file> <out-file> <old> <new> <disable-third-party:true|false>
#
# Writes <out-file> and prints one report line per entry it touched or
# skipped, to stdout:
#     rewritten|<file>|<line>   an official entry moved from <old> to <new>
#     thirdparty|<file>|<line>  a third-party entry naming <old>, left alone
#     disabled|<file>|<line>    the same, disabled (--disable-third-party)
#     alias|<file>|<line>       an official entry using stable/oldstable
#     cdrom|<file>|<line>       a cdrom: entry, left alone
# <line> is the 1-based line the entry starts on. A deb822 stanza that mixes
# official and other URIs is treated as third-party; that warning goes to
# stderr as "warning|<file>|<line>|<text>".
#
# An entry is official when every URI is http or https and its path is
# /debian or /debian-security (optional trailing slash), or the same behind
# a caching proxy: /<name>.debian.org/debian[-security]. A path that merely
# ends in /debian is not enough: download.docker.com/linux/debian and
# pkgs.tailscale.com/stable/debian are vendors, not the Debian archive.
#
# The awk is POSIX: Debian's default awk is mawk, so no gawk extensions, no
# regex intervals, no length(array), and no variable named "func".

_debian_sources_awk_program() {
    cat <<'AWK_PROGRAM'
function is_official_uri(u,   rest, slash, path, seg) {
    if (u !~ /^https?:\/\//) return 0
    rest = u
    sub(/^https?:\/\//, "", rest)
    slash = index(rest, "/")
    if (slash == 0) return 0
    path = substr(rest, slash)
    sub(/\/+$/, "", path)
    if (path == "/debian" || path == "/debian-security") return 1
    if (path ~ /^\/[^\/]+\/debian(-security)?$/) {
        seg = substr(path, 2)
        sub(/\/.*$/, "", seg)
        if (seg ~ /(^|\.)debian\.org$/) return 1
    }
    return 0
}

function names_old(tok) {
    return (tok == OLD || index(tok, OLD "-") == 1 || index(tok, OLD "/") == 1)
}

function map_suite(tok,   suffix) {
    if (tok == OLD) return NEW
    if (index(tok, OLD "-") == 1) {
        suffix = substr(tok, length(OLD) + 1)
        if (suffix == "-updates" || suffix == "-security" || suffix == "-backports" || suffix == "-proposed-updates") {
            return NEW suffix
        }
    }
    return tok
}

function is_alias(tok) {
    return (tok ~ /^(old|oldold)?stable(-updates|-security|-backports|-proposed-updates)?$/)
}

function report(kind, ln) {
    print kind "|" LABEL "|" ln
}

# Rewrites every whitespace-separated token that maps to NEW, keeping the
# spacing exactly as it was. Sets CHANGED when anything moved.
function rewrite_tokens(s,   out, rest, start, len, tok, mapped) {
    out = ""
    rest = s
    while (match(rest, /[^ \t]+/)) {
        start = RSTART
        len = RLENGTH
        tok = substr(rest, start, len)
        mapped = map_suite(tok)
        if (mapped != tok) CHANGED = 1
        out = out substr(rest, 1, start - 1) mapped
        rest = substr(rest, start + len)
    }
    return out rest
}

# Sets NAMES_OLD and SAW_ALIAS from a string of suites.
function scan_suites(s,   rest, tok) {
    rest = s
    while (match(rest, /[^ \t]+/)) {
        tok = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (names_old(tok)) NAMES_OLD = 1
        if (is_alias(tok)) SAW_ALIAS = 1
    }
}

# Sets TOK, TOK_START and TOK_END (absolute, 1-based) for the first token
# after offset off. Returns 0 when there is none or it starts a comment.
function next_token(s, off,   t) {
    t = substr(s, off + 1)
    if (!match(t, /[^ \t]+/)) return 0
    TOK_START = off + RSTART
    TOK_END = off + RSTART + RLENGTH - 1
    TOK = substr(t, RSTART, RLENGTH)
    if (substr(TOK, 1, 1) == "#") return 0
    return 1
}

# ── One-line format ──────────────────────────────────────────────────────────
function handle_oneline(line, ln,   off, t, p, uri, uri_end, suite, suite_start, suite_end, mapped) {
    if (line !~ /^[ \t]*(deb-src|deb)([ \t]|\[|$)/) {
        print line > OUT
        return
    }
    match(line, /^[ \t]*(deb-src|deb)/)
    off = RLENGTH
    # Optional [ options ]: may hold spaces and may touch its neighbours.
    t = substr(line, off + 1)
    if (match(t, /^[ \t]*\[/)) {
        p = index(t, "]")
        if (p == 0) {
            print line > OUT
            return
        }
        off = off + p
    }
    if (!next_token(line, off)) {
        print line > OUT
        return
    }
    uri = TOK
    uri_end = TOK_END
    if (uri ~ /^cdrom:/) {
        report("cdrom", ln)
        print line > OUT
        return
    }
    if (!next_token(line, uri_end)) {
        print line > OUT
        return
    }
    suite = TOK
    suite_start = TOK_START
    suite_end = TOK_END

    if (is_official_uri(uri)) {
        if (LISTURI == "true") print "officialuri|" uri
        mapped = map_suite(suite)
        if (mapped != suite) {
            report("rewritten", ln)
            print substr(line, 1, suite_start - 1) mapped substr(line, suite_end + 1) > OUT
            return
        }
        if (is_alias(suite)) report("alias", ln)
        print line > OUT
        return
    }
    if (names_old(suite)) {
        if (DISABLE == "true") {
            report("disabled", ln)
            print PREFIX line > OUT
        } else {
            report("thirdparty", ln)
            print line > OUT
        }
        return
    }
    print line > OUT
}

# ── deb822 format ────────────────────────────────────────────────────────────
function rewrite_field_line(line) {
    if (line ~ /^[ \t]/) return rewrite_tokens(line)
    match(line, /^[^ \t:#][^:]*:/)
    return substr(line, 1, RLENGTH) rewrite_tokens(substr(line, RLENGTH + 1))
}

function emit_stanza(   i, last) {
    last = nl + extra
    for (i = 1; i <= last; i++) print NLN[i] > OUT
    nl = 0
    extra = 0
}

function flush_stanza(   i, line, name, val, cur, uris, suites, en_idx, first_ln, rest, tok, n_off, n_third) {
    if (nl == 0) return
    cur = ""
    uris = ""
    suites = ""
    en_idx = 0
    first_ln = 0
    for (i = 1; i <= nl; i++) {
        line = SL[i]
        NLN[i] = line
        SF[i] = ""
        if (line ~ /^#/) continue
        if (line ~ /^[ \t]/) {
            SF[i] = cur
            val = line
        } else if (match(line, /^[^ \t:#][^:]*:/)) {
            name = tolower(substr(line, 1, RLENGTH - 1))
            val = substr(line, RLENGTH + 1)
            sub(/[ \t]+$/, "", name)
            cur = name
            SF[i] = name
            if (first_ln == 0) first_ln = SN[i]
            if (name == "enabled") en_idx = i
        } else {
            cur = ""
            continue
        }
        if (SF[i] == "uris") uris = uris " " val
        else if (SF[i] == "suites") suites = suites " " val
    }
    if (first_ln == 0) first_ln = SN[1]

    if (index(uris, "cdrom:") > 0) {
        report("cdrom", first_ln)
        emit_stanza()
        return
    }
    n_off = 0
    n_third = 0
    rest = uris
    while (match(rest, /[^ \t]+/)) {
        tok = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (is_official_uri(tok)) {
            n_off++
            if (LISTURI == "true") print "officialuri|" tok
        } else {
            n_third++
        }
    }
    if (n_off + n_third == 0 || suites ~ /^[ \t]*$/) {
        emit_stanza()
        return
    }

    NAMES_OLD = 0
    SAW_ALIAS = 0
    scan_suites(suites)
    if (n_third == 0) {
        CHANGED = 0
        for (i = 1; i <= nl; i++) {
            if (SF[i] == "suites") NLN[i] = rewrite_field_line(SL[i])
        }
        if (CHANGED) report("rewritten", first_ln)
        else if (SAW_ALIAS) report("alias", first_ln)
    } else {
        if (n_off > 0) {
            print "warning|" LABEL "|" first_ln "|stanza mixes official and other URIs; treated as third-party"
        }
        if (NAMES_OLD) {
            if (DISABLE == "true") {
                if (en_idx > 0) {
                    NLN[en_idx] = "Enabled: no"
                } else {
                    NLN[nl + 1] = "Enabled: no"
                    extra = 1
                }
                report("disabled", first_ln)
            } else {
                report("thirdparty", first_ln)
            }
        }
    }
    emit_stanza()
}

BEGIN {
    OUT = ENVIRON["DISTRO_REWRITE_OUT"]
    LABEL = ENVIRON["DISTRO_REWRITE_LABEL"]
    PREFIX = ENVIRON["DISTRO_DISABLE_PREFIX"]
    nl = 0
    extra = 0
    if (FMT != "oneline" && FMT != "deb822") exit 2
    printf "" > OUT
}

{
    if (FMT == "oneline") {
        handle_oneline($0, NR)
    } else if ($0 ~ /^[ \t]*$/) {
        flush_stanza()
        print $0 > OUT
    } else {
        nl++
        SL[nl] = $0
        SN[nl] = NR
    }
}

END {
    if (FMT == "deb822") flush_stanza()
    close(OUT)
}
AWK_PROGRAM
}

# _debian_sources_run <in> <out> <old> <new> <disable> <list-uris> — the
# shared awk run. Reports and officialuri lines go to stdout, warnings to
# stderr.
_debian_sources_run() {
    local in_file="$1" out_file="$2" old="$3" new="$4" disable="$5" listuri="$6"
    local fmt report line
    case "${old}" in ''|*[!a-z0-9]*) return 2 ;; esac
    case "${new}" in ''|*[!a-z0-9]*) return 2 ;; esac
    case "${disable}" in true|false) ;; *) return 2 ;; esac
    [[ -r "${in_file}" ]] || return 1
    case "${in_file}" in
        *.sources) fmt="deb822" ;;
        *)         fmt="oneline" ;;
    esac
    report="$(
        DISTRO_REWRITE_OUT="${out_file}" \
        DISTRO_REWRITE_LABEL="${in_file}" \
        DISTRO_DISABLE_PREFIX="# disabled by workbench-distro (${old}→${new}): " \
        awk -v OLD="${old}" -v NEW="${new}" -v DISABLE="${disable}" \
            -v FMT="${fmt}" -v LISTURI="${listuri}" \
            "$(_debian_sources_awk_program)" "${in_file}"
    )" || return $?
    if [[ -n "${report}" ]]; then
        while IFS= read -r line; do
            case "${line}" in
                warning\|*) printf '%s\n' "${line}" >&2 ;;
                *)          printf '%s\n' "${line}" ;;
            esac
        done <<EOF
${report}
EOF
    fi
    return 0
}

_debian_sources_rewrite() {
    _debian_sources_run "$1" "$2" "$3" "$4" "${5:-false}" "false"
}

# _debian_sources_files — every apt sources file, one per line: sources.list,
# then sources.list.d/*.list and *.sources in name order. find, not a glob:
# a glob that matches nothing is an error in zsh, and a Debian 12 host with
# only .sources files has no *.list.
_debian_sources_files() {
    if [[ -f "${_DISTRO_APT_DIR}/sources.list" ]]; then
        printf '%s\n' "${_DISTRO_APT_DIR}/sources.list"
    fi
    if [[ -d "${_DISTRO_APT_DIR}/sources.list.d" ]]; then
        find "${_DISTRO_APT_DIR}/sources.list.d" -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) | sort
    fi
    return 0
}

# _debian_first_official_uri — the first official archive URI, for fetching
# a Release file. Prints nothing when there is none.
_debian_first_official_uri() {
    local file line
    while IFS= read -r file; do
        line="$(_debian_sources_run "${file}" /dev/null x y false true 2>/dev/null \
            | sed -n 's/^officialuri|//p' | head -n 1)"
        if [[ -n "${line}" ]]; then
            printf '%s\n' "${line%/}"
            return 0
        fi
    done <<EOF
$(_debian_sources_files)
EOF
    return 0
}

# ── debian-release-upgrade ────────────────────────────────────────────────────

_distro_is_debian_proper() {
    [[ "${WORKBENCH_DISTRO_ID:-}" == "debian" ]]
}
_wb_alias_availability --needs "Debian itself (Ubuntu: ubuntu-release-upgrade, Pop!_OS: pop-release-upgrade)" \
    _distro_is_debian_proper debian-release-upgrade

# _debian_codename_lookup <number|codename> — prints "<number> <codename>".
_debian_codename_lookup() {
    local key="$1" rest="${_DEBIAN_CODENAMES}" pair number name
    while [[ -n "${rest}" ]]; do
        pair="${rest%% *}"
        if [[ "${rest}" == *" "* ]]; then
            rest="${rest#* }"
        else
            rest=""
        fi
        number="${pair%%:*}"
        name="${pair#*:}"
        if [[ "${key}" == "${number}" || "${key}" == "${name}" ]]; then
            printf '%s %s\n' "${number}" "${name}"
            return 0
        fi
    done
    return 1
}

# _debian_current_release — prints "<number> <codename>", or fails.
_debian_current_release() {
    local codename version major
    codename="$(_distro_os_release VERSION_CODENAME)"
    if [[ -n "${codename}" ]]; then
        _debian_codename_lookup "${codename}" && return 0
    fi
    if [[ -r "${_DISTRO_DEBIAN_VERSION_FILE}" ]]; then
        IFS= read -r version < "${_DISTRO_DEBIAN_VERSION_FILE}"
        major="${version%%.*}"
        case "${major}" in
            ''|*[!0-9]*) return 1 ;;
        esac
        _debian_codename_lookup "${major}" && return 0
    fi
    return 1
}

# _debian_file_mode <file> — octal mode, GNU or BSD stat.
_debian_file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

_debian_release_upgrade_usage() {
    printf '%s\n' \
        "Usage: debian-release-upgrade <codename|number> [--disable-third-party]" \
        "       e.g. debian-release-upgrade trixie" \
        "" \
        "Upgrades Debian to the next release. Rewrites only the official Debian" \
        "archive entries in /etc/apt, after showing the diff and asking you to type" \
        "'upgrade'. Third-party and cdrom entries are reported and left alone;" \
        "--disable-third-party disables the third-party entries that name the old release." \
        "Backups go to ${_DISTRO_BACKUP_ROOT}/."
}

# _debian_release_upgrade_failed <restore-file> <elev> — what to do next.
_debian_release_upgrade_failed() {
    local restore="$1" elev="$2"
    log_error "The upgrade stopped part-way. Nothing was restored automatically: old sources under a half-upgraded system make things worse."
    log_info "To resume: ${elev:+${elev} }apt-get -f install, then ${elev:+${elev} }apt-get full-upgrade"
    log_info "To put the old sources back anyway, see ${restore}"
}

debian-release-upgrade() {
    local target_arg="" disable="false" arg
    for arg in "$@"; do
        case "${arg}" in
            -h|--help)               _debian_release_upgrade_usage; return 0 ;;
            --disable-third-party)   disable="true" ;;
            -*)                      log_error "debian-release-upgrade: unknown option '${arg}'"; return 2 ;;
            *)
                if [[ -n "${target_arg}" ]]; then
                    log_error "debian-release-upgrade: give one target release"
                    return 2
                fi
                target_arg="${arg}"
                ;;
        esac
    done

    if ! _distro_is_debian_proper; then
        case "${WORKBENCH_DISTRO_ID:-unknown}" in
            ubuntu) log_error "debian-release-upgrade: this is Ubuntu. Use 'ubuntu-release-upgrade'." ;;
            pop)    log_error "debian-release-upgrade: this is Pop!_OS. Use 'pop-release-upgrade'." ;;
            *)      log_error "debian-release-upgrade: this is for Debian itself, not '${WORKBENCH_DISTRO_ID:-unknown}'." ;;
        esac
        return 1
    fi
    if [[ -z "${target_arg}" ]]; then
        log_error "debian-release-upgrade: give the release to upgrade to, e.g. 'debian-release-upgrade trixie'"
        return 2
    fi

    local current current_number current_name target target_number target_name
    current="$(_debian_current_release)" || {
        log_error "debian-release-upgrade: couldn't tell which Debian release this is. testing and sid aren't handled."
        return 1
    }
    current_number="${current%% *}"
    current_name="${current#* }"
    if (( current_number < 12 )); then
        log_error "debian-release-upgrade: ${current_name} is too old to start from. Debian 12 (bookworm) is the oldest release this supports."
        return 1
    fi
    target="$(_debian_codename_lookup "${target_arg}")" || {
        log_error "debian-release-upgrade: '${target_arg}' isn't a release this module knows (${_DEBIAN_CODENAMES})"
        return 2
    }
    target_number="${target%% *}"
    target_name="${target#* }"
    if (( target_number != current_number + 1 )); then
        log_error "debian-release-upgrade: Debian doesn't support skipping releases. From ${current_name} the next release is $(_debian_codename_lookup "$((current_number + 1))" | cut -d' ' -f2)."
        return 2
    fi

    if _distro_in_container; then
        log_error "debian-release-upgrade: this is a container. Recreate it from a Debian ${target_number} image instead."
        return 1
    fi
    if ! _distro_have_tty; then
        log_error "debian-release-upgrade: needs a terminal, to confirm before anything is changed."
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log_error "debian-release-upgrade: curl is needed to check that ${target_name} is released. Install it, then try again."
        return 1
    fi
    if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" ]]; then
        log_warn "This is an SSH session outside tmux or screen. A dropped connection mid-upgrade is the commonest way to break one."
    fi

    local archive_uri release_text
    archive_uri="$(_debian_first_official_uri)"
    if [[ -z "${archive_uri}" ]]; then
        log_error "debian-release-upgrade: found no official Debian archive entry in ${_DISTRO_APT_DIR}, so there is nothing to rewrite."
        return 1
    fi
    release_text="$(curl -fsSL "${archive_uri}/dists/${target_name}/Release" 2>/dev/null)" || {
        log_error "debian-release-upgrade: couldn't fetch ${archive_uri}/dists/${target_name}/Release, so can't tell whether ${target_name} is released."
        return 1
    }
    if ! printf '%s\n' "${release_text}" | grep -q '^Suite: stable[[:space:]]*$'; then
        log_error "debian-release-upgrade: ${target_name} isn't the stable release yet (its Suite isn't 'stable'). Try again on release day."
        return 1
    fi

    local elev
    elev="$(_distro_elev)" || return 1

    log_info "Preflight 1/4: bring ${current_name} up to its latest point release"
    # shellcheck disable=SC2086
    ${elev} apt-get update || { log_error "apt-get update failed. Nothing was changed."; return 1; }
    # shellcheck disable=SC2086
    ${elev} apt-get upgrade -y || { log_error "apt-get upgrade failed. Nothing was changed."; return 1; }

    log_info "Preflight 2/4: check that no reboot is pending"
    if distro-reboot-required >/dev/null 2>&1; then
        log_error "A reboot is pending: $(_distro_reboot_word), then run 'debian-release-upgrade ${target_name}' again."
        return 1
    fi

    log_info "Preflight 3/4: check for broken packages"
    local problems
    problems="$(dpkg --audit 2>&1)"
    if [[ -n "${problems}" ]]; then
        log_error "dpkg reports packages in a bad state. Fix these first:"
        printf '%s\n' "${problems}" >&2
        return 1
    fi

    log_info "Preflight 4/4: check for held packages"
    local holds
    holds="$(apt-mark showhold 2>&1)"
    if [[ -n "${holds}" ]]; then
        log_error "These packages are held back. Release them with 'apt-mark unhold', then try again:"
        printf '%s\n' "${holds}" >&2
        return 1
    fi

    # ── Rewrite into a scratch directory first ──
    local scratch file relative out changed_list="" report all_reports=""
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/debian-release-upgrade.XXXXXX")" || return 1
    while IFS= read -r file; do
        relative="${file#"${_DISTRO_APT_DIR}"/}"
        out="${scratch}/${relative}"
        mkdir -p "$(dirname "${out}")" || { rm -rf "${scratch}"; return 1; }
        report="$(_debian_sources_rewrite "${file}" "${out}" "${current_name}" "${target_name}" "${disable}")" || {
            log_error "debian-release-upgrade: couldn't process ${file}"
            rm -rf "${scratch}"
            return 1
        }
        if [[ -n "${report}" ]]; then
            all_reports="${all_reports}${report}"$'\n'
        fi
        if ! cmp -s "${file}" "${out}"; then
            changed_list="${changed_list}${relative}"$'\n'
        fi
    done <<EOF
$(_debian_sources_files)
EOF

    if [[ -z "${changed_list}" ]]; then
        log_error "debian-release-upgrade: no official Debian entry names ${current_name}, so there is nothing to rewrite."
        rm -rf "${scratch}"
        return 1
    fi

    log_info "These files will change:"
    while IFS= read -r relative; do
        [[ -n "${relative}" ]] || continue
        diff -u "${_DISTRO_APT_DIR}/${relative}" "${scratch}/${relative}"
    done <<EOF
${changed_list}
EOF
    _debian_print_source_report "${all_reports}" "${current_name}" "${target_name}"

    if ! _distro_confirm_word "upgrade" "Rewrite these files and upgrade to ${target_name}?"; then
        log_info "Nothing was changed."
        rm -rf "${scratch}"
        return 0
    fi

    # ── Back up, then install ──
    local stamp backup restore_file mode
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="${_DISTRO_BACKUP_ROOT}/apt-sources-${current_name}-to-${target_name}-${stamp}"
    restore_file="${backup}/RESTORE.txt"
    # shellcheck disable=SC2086
    ${elev} mkdir -p "${backup}" || { rm -rf "${scratch}"; return 1; }
    : > "${scratch}/RESTORE.txt"
    printf '%s\n' "# Restore the apt sources as they were before debian-release-upgrade ${target_name}." \
        >> "${scratch}/RESTORE.txt"
    while IFS= read -r relative; do
        [[ -n "${relative}" ]] || continue
        # shellcheck disable=SC2086
        ${elev} mkdir -p "$(dirname "${backup}/${relative}")" || { rm -rf "${scratch}"; return 1; }
        # shellcheck disable=SC2086
        ${elev} cp -p "${_DISTRO_APT_DIR}/${relative}" "${backup}/${relative}" || {
            log_error "Couldn't back up ${relative}. Nothing was changed."
            rm -rf "${scratch}"
            return 1
        }
        printf "cp -p '%s' '%s'\n" "${backup}/${relative}" "${_DISTRO_APT_DIR}/${relative}" >> "${scratch}/RESTORE.txt"
    done <<EOF
${changed_list}
EOF
    # shellcheck disable=SC2086
    ${elev} install -m 0644 "${scratch}/RESTORE.txt" "${restore_file}" || { rm -rf "${scratch}"; return 1; }

    while IFS= read -r relative; do
        [[ -n "${relative}" ]] || continue
        mode="$(_debian_file_mode "${_DISTRO_APT_DIR}/${relative}")"
        # shellcheck disable=SC2086
        ${elev} install -m "${mode:-0644}" -o root -g root "${scratch}/${relative}" "${_DISTRO_APT_DIR}/${relative}" || {
            log_error "Couldn't write ${_DISTRO_APT_DIR}/${relative}. Restore with the commands in ${restore_file}"
            rm -rf "${scratch}"
            return 1
        }
    done <<EOF
${changed_list}
EOF
    rm -rf "${scratch}"

    log_info "Backups and the restore commands are in ${backup}/ (see RESTORE.txt)"
    log_info "Debian's release notes suggest recording the session: run 'script' first next time if you want a log."
    log_info "Step 1/3: apt-get update"
    # shellcheck disable=SC2086
    ${elev} apt-get update || { _debian_release_upgrade_failed "${restore_file}" "${elev}"; return 1; }
    # apt-get upgrade never installs new packages, which is what Debian's
    # release notes mean by "apt upgrade --without-new-pkgs" (that flag
    # belongs to the apt front-end, not apt-get).
    log_info "Step 2/3: minimal upgrade (no new packages)"
    # shellcheck disable=SC2086
    ${elev} apt-get upgrade || { _debian_release_upgrade_failed "${restore_file}" "${elev}"; return 1; }
    log_info "Step 3/3: full upgrade"
    # shellcheck disable=SC2086
    ${elev} apt-get full-upgrade || { _debian_release_upgrade_failed "${restore_file}" "${elev}"; return 1; }

    log_info "Removing packages nothing needs any more"
    # shellcheck disable=SC2086
    ${elev} apt-get autoremove || log_warn "autoremove didn't finish; run it again later"
    log_info "Packages no longer in any repository (review, remove what you don't need):"
    apt list '?obsolete' 2>/dev/null
    log_info "Debian ${target_number} (${target_name}) is installed. Now $(_distro_reboot_word)."
    return 0
}

# _debian_print_source_report <report lines> <old> <new> — what was left alone.
_debian_print_source_report() {
    local reports="$1" old="$2" new="$3" line kind file ln
    [[ -n "${reports}" ]] || return 0
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        kind="${line%%|*}"
        file="${line#*|}"
        ln="${file##*|}"
        file="${file%|*}"
        case "${kind}" in
            rewritten)  : ;;
            thirdparty) log_warn "Third-party entry names ${old} and was left unchanged: ${file} line ${ln}. Check that its vendor publishes ${new}, or re-run with --disable-third-party." ;;
            disabled)   log_info "Disabled third-party entry that names ${old}: ${file} line ${ln}" ;;
            alias)      log_info "Entry uses stable/oldstable and follows the archive on its own: ${file} line ${ln}" ;;
            cdrom)      log_warn "cdrom entry left unchanged: ${file} line ${ln}" ;;
        esac
    done <<EOF
${reports}
EOF
}
