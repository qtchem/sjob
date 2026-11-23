# batch.sh -- reading batch_*.txt files and mapping their paths.
#
# A batch file has one case per line:  <source_dir> <destination_dir>
# (blank lines and #comments ignored, CRLF tolerated). destination_dir lives
# under DEST_ROOT on the cluster; CASE_ROOT is where that tree is found now
# (the same, unless it was moved/copied, e.g. for testing).

batch_name() { local n; n=$(basename "$1"); printf '%s' "${n%.txt}"; }

# batch_cases FILE  -> "<src>\t<dest>" per line. Dies on a malformed line.
batch_cases() {
    local line src dest extra
    while IFS= read -r line || [[ -n $line ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || $line == \#* ]] && continue
        read -r src dest extra <<<"$line"
        if [[ -z "${src:-}" || -z "${dest:-}" || -n "${extra:-}" ]]; then
            die "invalid batch entry in $1: $line"
        fi
        printf '%s\t%s\n' "$src" "$dest"
    done <"$1"
}

# Reject source paths that could escape the transfer root.
validate_src() {
    local s="$1"
    if [[ $s == /* || $s == ".." || $s == ../* || $s == */../* || $s == */.. ]]; then
        die "unsafe source path: $s"
    fi
}

# dest_rel DEST -> path relative to DEST_ROOT (no trailing slash)
dest_rel() {
    local d="$1"
    case "$d" in
        "$DEST_ROOT"/*) d="${d#"$DEST_ROOT"/}"; printf '%s' "${d%/}" ;;
        *) die "destination outside DEST_ROOT ($DEST_ROOT): $d" ;;
    esac
}

# dest_to_case_dir DEST -> where the case directory is found now
dest_to_case_dir() { printf '%s/%s' "$CASE_ROOT" "$(dest_rel "$1")"; }

# batch_case_dirs FILE -> one case directory (CASE_ROOT-mapped) per line
batch_case_dirs() {
    local src dest
    while IFS=$'\t' read -r src dest; do
        dest_to_case_dir "$dest"; printf '\n'
    done < <(batch_cases "$1")
}

# case_name SRC -> x/y/z/ becomes x_y_z
case_name() {
    local n="${1%/}"
    while [[ $n == */ ]]; do n="${n%/}"; done
    printf '%s' "${n//\//_}"
}

# list_batches -> all batch_*.txt in BATCH_DIR, version-sorted
list_batches() {
    local f
    shopt -s nullglob
    local -a fs=("$BATCH_DIR"/batch_*.txt)
    shopt -u nullglob
    ((${#fs[@]})) || return 0
    printf '%s\n' "${fs[@]}" | sort -V
}

# Common selection flags, shared by the per-batch commands:
#   SEL_FILES (array), SEL_ALL. Call sel_opt "$@" in an option loop; it returns
#   the number of args consumed (0 = not a selection flag).
SEL_FILES=(); SEL_ALL=0
sel_opt() {
    case "$1" in
        --batch) [[ $# -ge 2 ]] || die "--batch needs a file"; SEL_FILES+=("$2"); return 2 ;;
        --all)   SEL_ALL=1; return 1 ;;
    esac
    return 0
}

# select_batches -> SEL_BATCHES array (explicit files + --all), de-duplicated
select_batches() {
    SEL_BATCHES=()
    local f
    if ((SEL_ALL)); then
        while IFS= read -r f; do [[ -n $f ]] && SEL_BATCHES+=("$f"); done < <(list_batches)
    fi
    for f in "${SEL_FILES[@]}"; do SEL_BATCHES+=("$f"); done
    ((${#SEL_BATCHES[@]})) || die "no batches selected: give --batch FILE or --all (BATCH_DIR=$BATCH_DIR)"
    local -A seen=(); local -a uniq=()
    for f in "${SEL_BATCHES[@]}"; do
        [[ -f $f ]] || die "batch file not found: $f"
        [[ -n ${seen[$f]:-} ]] || { seen[$f]=1; uniq+=("$f"); }
    done
    SEL_BATCHES=("${uniq[@]}")
}
