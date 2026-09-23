#!/bin/bash
# Report helpers for the phase scripts. Sourced after common.sh, not executed.
# Phases write HTML fragments; generate_index.py wraps them and supplies CSS.

# Args: file title
html_init() {
  {
    echo "    <h2>$2</h2>"
    echo "    <p><strong>Generated:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>"
  } >"$1"
}

# Args: file html
html_note() {
  printf '    <div class="section">\n        <p>%s</p>\n    </div>\n' "$2" >>"$1"
}

# Append '|'-separated rows (the first is the header) as a table, under an
# optional <h2>. PASS/FAIL/SKIP cells get their status class and bracketed
# furiosa-hal-bench metrics ("[...]") get val-text.
# Args: file title header row...
html_table() {
  local file=$1 title=$2 header=$3 row cell cls
  local -a cells
  shift 3
  {
    echo '    <div class="section">'
    if [[ -n "$title" ]]; then echo "        <h2>$title</h2>"; fi
    echo '        <table>'
    IFS='|' read -ra cells <<<"$header"
    echo "            <tr>$(printf '<th>%s</th>' "${cells[@]}")</tr>"
    for row; do
      IFS='|' read -ra cells <<<"$row"
      printf '            <tr>'
      for cell in "${cells[@]}"; do
        case "$cell" in
          PASS) cls=pass ;;
          FAIL) cls=fail ;;
          SKIP) cls=skip ;;
          \[*\]) cls=val-text ;;
          *) cls="" ;;
        esac
        printf '<td%s>%s</td>' "${cls:+ class=\"$cls\"}" "$cell"
      done
      echo '</tr>'
    done
    echo '        </table>'
    echo '    </div>'
  } >>"$file"
}

# Write <out_dir>/PF_result.log (also shown) and PF_result.html for a phase
# whose rows end in a PASS/FAIL/SKIP column, timed by $SECONDS. Returns 1 if any
# row FAILed, 75 (SKIP) if none ran, else 0.
# Args: out_dir title widths header row...
write_status_report() {
  local out=$1 title=$2 widths=$3 header=$4 row rc=75 duration
  shift 4
  for row; do
    case "${row##*|}" in
      FAIL)
        rc=1
        break
        ;;
      PASS) rc=0 ;;
    esac
  done
  local -A result=([0]="All tests PASSED" [1]="Some tests FAILED" [75]="All tests SKIPPED")
  local -A cls=([0]=pass [1]=fail [75]=skip)
  local -A color=([0]="$GREEN" [1]="$RED" [75]="$YELLOW")
  duration=$(format_duration "$SECONDS")

  {
    print_summary "${title^^}" "$widths" "$header" "$@"
    echo "Total Duration: $duration"
    echo -e "${color[$rc]}${BOLD}${result[$rc]}${NC}"
  } | tee "$out/PF_result.log"

  local html="$out/PF_result.html"
  html_init "$html" "Furiosa $title"
  echo "    <p><strong>Total Duration:</strong> $duration</p>" >>"$html"
  html_table "$html" "" "$header" "$@"
  echo "    <div class=\"footer\"><span class='${cls[$rc]}'>RESULT: ${result[$rc]}</span></div>" >>"$html"
  echo -e "HTML report saved to: ${YELLOW}$html${NC}"
  return "$rc"
}
