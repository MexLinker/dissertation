#!/usr/bin/env bash
# compile_and_push.sh - prettier latexmk wrapper + git commit/push + run history
# Usage: ./compile_and_push.sh
# Override:
#   LATEXMK_CMD   default: "latexmk -pdflua -silent -quiet"
#   LOG_FILE      default: "compile_log.txt"
#   SHOW_FULL_LOG show full raw compile output on success (default: false)
#
# Notes:
#  - Runs LATEXMK_CMD and times it.
#  - Produces a concise, colorized summary with counts of warnings/errors/overfull/underfull.
#  - Shows a short, cleaned excerpt of the compiler output (or last lines on failures).
#  - Performs git add -A, commits with commit date set to the compile start time, and pushes.
#  - Appends one-line summary to LOG_FILE.
#  - Prints last 10 log lines and average compile time.
set -euo pipefail

# ---------- Config ----------
LATEXMK_CMD="${LATEXMK_CMD:-latexmk -pdflua -silent -quiet}"
LOG_FILE="${LOG_FILE:-compile_log.txt}"
SHOW_FULL_LOG="${SHOW_FULL_LOG:-false}"
EXCERPT_LINES="${EXCERPT_LINES:-30}"   # number of lines to show in condensed excerpt
# ---------- Helpers ----------
timestamp_iso() { date +"%Y-%m-%dT%H:%M:%S%z"; }    # e.g. 2025-11-28T13:17:03+0900
timestamp_human() { date +"%Y-%m-%d %H:%M:%S"; }   # e.g. 2025-11-28 13:17:03
secs_to_hms() {
  local s=$1
  printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

# colors (if terminal supports)
if tput &>/dev/null; then
  bold="$(tput bold)"
  dim="$(tput dim)"
  red="$(tput setaf 1)"
  green="$(tput setaf 2)"
  yellow="$(tput setaf 3)"
  blue="$(tput setaf 4)"
  magenta="$(tput setaf 5)"
  cyan="$(tput setaf 6)"
  reset="$(tput sgr0)"
else
  bold=""; dim=""; red=""; green=""; yellow=""; blue=""; magenta=""; cyan=""; reset=""
fi

print_header() {
  printf "\n${bold}🧭 Repo root:${reset} %s\n" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf "%s  Starting compile — %s\n" "🚀" "$(timestamp_human)"
  printf "📦  Command: %s\n\n" "$LATEXMK_CMD"
}

print_compact_line() {
  printf "%s\n" "$1"
}

# safe temp files
compile_stdout="$(mktemp --suffix=_latex_stdout.txt)"
compile_stderr="$(mktemp --suffix=_latex_stderr.txt)"
combined_out="$(mktemp --suffix=_latex_combined.txt)"

# ---------- Start ----------
print_header
start_epoch=$(date +%s)
start_human="$(timestamp_human)"
start_iso="$(timestamp_iso)"

echo "⏳  Running LaTeX compile..."
set +e
# Run command, tee stdout+stderr separately and also combined. Use sh -c so LATEXMK_CMD expansions work.
bash -lc "$LATEXMK_CMD" > >(tee "$compile_stdout" >> "$combined_out") 2> >(tee "$compile_stderr" >> "$combined_out" >&2)
compile_exit=${PIPESTATUS[0]:-0}
set -e
end_epoch=$(date +%s)
duration=$((end_epoch - start_epoch))
duration_hms="$(secs_to_hms $duration)"

if [ "$compile_exit" -eq 0 ]; then
  compile_status="${green}✅ success${reset}"
  echo -e "\n${green}🎉  Compile finished successfully${reset} in ${duration_hms} (${duration}s)."
else
  compile_status="${red}❌ failure (exit ${compile_exit})${reset}"
  echo -e "\n${red}⚠️  Compile returned non-zero (${compile_exit}) after ${duration_hms} (${duration}s).${reset}"
fi

# ---------- Analyze logs ----------
# Prefer primary .log file(s) produced by LaTeX; fall back to combined_out
# find newest .log in cwd (excluding latexmk's own logfiles like latexmk.log)
logfile="$(ls -t *.log 2>/dev/null | grep -v '^latexmk' | head -n1 || true)"
analysis_source="$combined_out"
if [ -n "$logfile" ] && [ -s "$logfile" ]; then
  analysis_source="$logfile"
fi

# counts
count_warnings=$(grep -E -c "LaTeX Warning|Warning:|warning:" "$analysis_source" || true)
# Errors: lines that start with "!" in .log typically denote TeX errors; also search for "Fatal" or "Error"
count_tex_errors=$(grep -E -c '^\!|^! LaTeX|^!.*Error|^(\s*)! ' "$analysis_source" || true)
count_errors_other=$(grep -E -c 'Fatal|ERROR|Error:' "$analysis_source" || true)
# Overfull / Underfull boxes
count_overfull=$(grep -c "Overfull \\\\hbox" "$analysis_source" || true)
count_underfull=$(grep -c "Underfull \\\\hbox" "$analysis_source" || true)

# extract unique Overfull/Underfull lines for a peek
overfull_lines="$(grep "Overfull \\\\hbox" "$analysis_source" | sed -n '1,10p' || true)"
underfull_lines="$(grep "Underfull \\\\hbox" "$analysis_source" | sed -n '1,10p' || true)"

# find produced PDF (newest .pdf)
pdf_file="$(ls -t *.pdf 2>/dev/null | head -n1 || true)"
pdf_info=""
if [ -n "$pdf_file" ]; then
  pdf_size_bytes=$(stat -c%s "$pdf_file" 2>/dev/null || stat -f%z "$pdf_file" 2>/dev/null || echo 0)
  # human-friendly size
  human_size="$(numfmt --to=iec --format="%.1f" "$pdf_size_bytes" 2>/dev/null || awk 'function human(x){s="B KB MB GB TB"; while(x>=1024 && length(s)){x/=1024; split(s,a," "); s=substr(s,index(s," ")+1)} printf "%.1f %s", x, a[1]} END{}' <<<"$pdf_size_bytes")"
  # pages if pdfinfo available
  if command -v pdfinfo >/dev/null 2>&1; then
    pages="$(pdfinfo "$pdf_file" 2>/dev/null | awk -F: '/^Pages:/ {gsub(/ /,"",$2); print $2}')"
    if [ -n "${pages:-}" ]; then
      pdf_info="${pdf_file} — ${human_size}, ${pages} pages"
    else
      pdf_info="${pdf_file} — ${human_size}"
    fi
  else
    pdf_info="${pdf_file} — ${human_size}"
  fi
else
  pdf_info="(no PDF produced)"
fi

# ---------- Present condensed summary ----------
echo -e "\n${bold}🧾 Compile summary${reset}"
printf "  %s Start: %s\n" "⏱" "$start_human"
printf "  %s Duration: %s (%ds)\n" "⏳" "${duration_hms}" "${duration}"
printf "  %s Result: %b\n" "📌" "$compile_status"
printf "  %s PDF: %s\n" "📄" "$pdf_info"
printf "  %s Warnings: %s    Errors: %s\n" "⚠️" "${yellow}${count_warnings}${reset}" "${red}$((count_tex_errors + count_errors_other))${reset}"
printf "  %s Overfull: %s    Underfull: %s\n" "📐" "${count_overfull}" "${count_underfull}"

# show short examples (if exist)
if [ -n "$overfull_lines" ]; then
  echo -e "\n${dim}Example Overfull/Underfull:${reset}"
  echo "$overfull_lines" | sed 's/^/    /'
fi
if [ -n "$underfull_lines" ]; then
  echo -e "\n${dim}Example Underfull:${reset}"
  echo "$underfull_lines" | sed 's/^/    /'
fi

# ---------- Short, cleaned excerpt of compiler output ----------
echo -e "\n${bold}🔎  Condensed compiler output (last ${EXCERPT_LINES} lines, filtered):${reset}"
# crude filter to remove very repetitive latexmk housekeeping lines:
sed -n "$((EXCERPT_LINES * 3)),$ p" "$combined_out" 2>/dev/null || true \
  | sed '/^Latexmk:/d' \
  | sed '/^===*/d' \
  | sed '/^Rule.* -> /d' \
  | sed '/^Used: /d' \
  | sed '/^Collected input files:/d' \
  | sed '/^This is /d' \
  | sed '/^Transcript written on /d' \
  | tail -n "$EXCERPT_LINES" \
  | sed -E \
      -e "s/Overfull (\\\\hbox.*)/${yellow}\1${reset}/" \
      -e "s/Underfull (\\\\hbox.*)/${magenta}\1${reset}/" \
      -e "s/^! (.*)/${red}! \1${reset}/" \
      -e "s/LaTeX Warning: (.*)/${yellow}LaTeX Warning: \1${reset}/" \
      -e "s/Warning: (.*)/${yellow}Warning: \1${reset}/" \
      -e "s/Error: (.*)/${red}Error: \1${reset}/" \
      || true

# show full raw tail if compile failed (helpful)
if [ "$compile_exit" -ne 0 ]; then
  echo -e "\n${bold}${red}🔧 Last 200 lines of combined raw output (for debugging)${reset}"
  tail -n 200 "$combined_out" || true
else
  if [ "$SHOW_FULL_LOG" = "true" ]; then
    echo -e "\n${dim}Full compile output (stdout/stderr combined):${reset}"
    cat "$combined_out"
  fi
fi

# ---------- Git operations ----------
echo -e "\n${bold}🔎  Git actions${reset}"
# stage everything
git add -A

if git diff --cached --quiet --exit-code; then
  git_action="SKIPPED (no changes)"
  commit_hash="SKIP"
  echo "💤  Nothing to commit — skipping git commit & push."
else
  commit_time_iso="$start_iso"
  commit_msg="Auto-compile: ${start_human}"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

  echo "✍️  Committing changes with commit date = ${commit_time_iso} ..."
  GIT_AUTHOR_DATE="$commit_time_iso" GIT_COMMITTER_DATE="$commit_time_iso" \
    git commit -m "$commit_msg" --no-verify

  commit_hash="$(git rev-parse --short HEAD || echo unknown)"
  echo "📌  Created commit ${commit_hash} on branch ${branch}."

  if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    echo "📤  Pushing to remote..."
    if git push; then
      git_action="pushed"
      echo "✅  Push OK."
    else
      git_action="push_failed"
      echo "❗  Push failed."
    fi
  else
    echo "📤  No upstream for ${branch}; pushing and setting upstream..."
    if git push -u origin "$branch"; then
      git_action="pushed (set-upstream)"
      echo "✅  Push OK and upstream set."
    else
      git_action="push_failed"
      echo "❗  Push failed."
    fi
  fi
fi

# ---------- Logging ----------
# sanitize commit and cmd for log
safe_cmd="${LATEXMK_CMD//|/\\|}"
log_line="$(timestamp_human) | duration_sec=${duration} | duration_hms=${duration_hms} | status=$(echo "$compile_status" | sed 's/\x1b\[[0-9;]*m//g') | commit=${commit_hash} | git_action=${git_action} | warnings=${count_warnings} | errors=$((count_tex_errors + count_errors_other)) | pdf='${pdf_file}' | cmd='${safe_cmd}'"
echo "$log_line" >> "$LOG_FILE"
echo -e "\n📝  Appended log to ${LOG_FILE}:"
echo "    $log_line"

# ---------- Summary (last 10 runs + average) ----------
echo -e "\n📊  Recent runs (last 10):"
tail -n 10 "$LOG_FILE" || true

avg_info=$(awk -F'duration_sec=' '
  { if (NF>1) { split($2,a," "); n++; sum+=a[1]; last=a[1]; } }
  END {
    if(n>0){
      avg=sum/n;
      printf "%d runs, total %d s, average %.2f s\n", n, sum, avg;
    } else {
      print "no timing records";
    }
  }
' "$LOG_FILE")
echo -e "\n⏱️  Compile stats: ${avg_info}"

# cleanup: keep combined and individual tmp files only if failed (helpful), else remove
if [ "$compile_exit" -ne 0 ]; then
  echo -e "\n📎 Combined output saved at: ${combined_out}"
  echo "    stdout: ${compile_stdout}"
  echo "    stderr: ${compile_stderr}"
  echo "💡 Tip: remove these temp files manually when you no longer need them."
else
  rm -f "$compile_stdout" "$compile_stderr" "$combined_out" || true
fi

echo -e "\n✨ Done. Have a great day! 🌞\n"

# exit with the same code as latexmk so CI can detect failure
exit "$compile_exit"
