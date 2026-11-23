# report.sh -- summary of everything collected so far (reads status/*.tsv).

cmd_report() {
    case "${1:-}" in -h|--help)
        echo "Usage: spartflow report   (counts by state, failure reason, dataset)" >&2; return 0 ;;
    esac
    shopt -s nullglob
    local -a files=("$STATUS_DIR"/*.tsv)
    shopt -u nullglob
    ((${#files[@]})) || die "no status files in $STATUS_DIR (run 'spartflow collect --apply' first)"
    cat "${files[@]}" | awk -F'\t' '
        /^#/ || NF < 3 { next }
        {
            n++; split($1, p, "/"); ds = p[1]
            st[$2]++; ds_st[ds SUBSEP $2]++; dss[ds] = 1
            if ($2 == "FAILED") rs[$3]++
        }
        END {
            printf "cases recorded: %d\n\nby state:\n", n
            for (s in st) printf "  %-8s %d\n", s, st[s]
            printf "\nfailures by reason:\n"
            for (r in rs) printf "  %-24s %d\n", r, rs[r]
            printf "\nby dataset:\n  %-24s %8s %8s\n", "dataset", "DONE", "FAILED"
            for (d in dss) printf "  %-24s %8d %8d\n", d, ds_st[d SUBSEP "DONE"], ds_st[d SUBSEP "FAILED"]
        }'
}
