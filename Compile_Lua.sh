#!/usr/bin/env bash
# compile_and_push.sh
# Usage: ./compile_and_push.sh
# Optionally override:
#   LATEXMK_CMD (default: "latexmk -pdflua")
#   LOG_FILE (default: "compile_log.txt")
#
# Behaviors:
#  - runs the latexmk command
#  - times the run
#  - git add -A, commit (with GIT_AUTHOR_DATE / GIT_COMMITTER_DATE set to compile time) and push if there are staged changes
#  - if nothing changed, skips commit & push
#  - appends a one-line log to LOG_FILE with date/time, seconds, human duration, status, commit-hash/skip
#  - prints last 10 log lines and average compile time
set -euo pipefail

# ---------- Config ----------
LATEXMK_CMD="${LATEXMK_CMD:-latexmk -pdflua}"
LOG_FILE="${LOG_FILE:-compile_log.txt}"
# ---------- Helpers ----------
timestamp_iso() { date +"%Y-%m-%dT%H:%M:%S%z"; }    # e.g. 2025-11-28T13:17:03+0900
timestamp_human() { date +"%Y-%m-%d %H:%M:%S"; }   # e.g. 2025-11-28 13:17:03
secs_to_hms() {
  local s=$1
  printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

# ---------- Start ----------
echo "🧭 Repo root: $(git rev-parse --show-toplevel 2>/dev/null || pwd)"
start_epoch=$(date +%s)
start_human="$(timestamp_human)"
start_iso="$(timestamp_iso)"

echo -e "🚀  Starting compile — $start_human\n📦  Command: $LATEXMK_CMD\n"

# Run compile, capture output (still show on stdout)
echo "⏳  Running LaTeX compile..."
compile_stdout="$(mktemp)"
compile_stderr="$(mktemp)"
set +e
# Run command and tee both stdout and stderr, also capture exit code
bash -c "$LATEXMK_CMD" 2> >(tee "$compile_stderr" >&2) | tee "$compile_stdout"
compile_exit=$?
set -e

end_epoch=$(date +%s)
duration=$((end_epoch - start_epoch))
duration_hms="$(secs_to_hms $duration)"

if [ "$compile_exit" -eq 0 ]; then
  compile_status="✅ success"
  echo -e "\n🎉  Compile finished successfully in ${duration_hms} (${duration}s)."
else
  compile_status="❌ failure (exit ${compile_exit})"
  echo -e "\n⚠️  Compile returned non-zero (${compile_exit}) after ${duration_hms} (${duration}s)."
fi

# ---------- Git operations ----------
echo "🔎  Checking git status..."
# stage everything
git add -A

# check if there is anything staged
if git diff --cached --quiet --exit-code; then
  # no changes staged
  git_action="SKIPPED (no changes)"
  commit_hash="SKIP"
  echo "💤  Nothing to commit — skipping git commit & push."
else
  # There are staged changes -> commit with timestamp
  # Use compile start time as commit time (ISO8601)
  commit_time_iso="$start_iso"
  commit_msg="Auto-compile: ${start_human}"
  # get current branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

  echo "✍️  Committing changes with commit date = ${commit_time_iso} ..."
  # set author and committer date exactly
  GIT_AUTHOR_DATE="$commit_time_iso" GIT_COMMITTER_DATE="$commit_time_iso" \
    git commit -m "$commit_msg" --no-verify

  commit_hash="$(git rev-parse --short HEAD || echo unknown)"
  echo "📌  Created commit ${commit_hash} on branch ${branch}."

  # Push — if no upstream set, push with -u
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
# Log format:
# YYYY-MM-DD HH:MM:SS | duration_sec=123 | duration_hms=0:02:03 | status=✅ success | commit=abcd12 | msg="Auto-compile..."
log_line="$(timestamp_human) | duration_sec=${duration} | duration_hms=${duration_hms} | status=${compile_status} | commit=${commit_hash} | git_action=${git_action} | cmd='${LATEXMK_CMD}'"

# Append to log file
echo "$log_line" >> "$LOG_FILE"
echo -e "\n📝  Appended log to ${LOG_FILE}:"
echo "    $log_line"

# ---------- Summary (last 10 runs + average) ----------
echo -e "\n📊  Recent runs (last 10):"
tail -n 10 "$LOG_FILE" || true

# Compute average compile time (seconds) from the log file
avg_info=$(awk -F'duration_sec=' '
  { if (NF>1) { split($2,a," "); n++; sum+=a[1]; last=a[1]; } }
  END {
    if(n>0){
      avg=sum/n;
      # print n,sum,avg
      printf "%d runs, total %d s, average %.2f s\n", n, sum, avg;
    } else {
      print "no timing records";
    }
  }
' "$LOG_FILE")
echo -e "\n⏱️  Compile stats: ${avg_info}"

# If compile failed, show last stderr lines for quick debugging
if [ "$compile_exit" -ne 0 ]; then
  echo -e "\n📎 Last 20 lines of compiler stderr (quick peek):"
  tail -n 20 "$compile_stderr" || true
  echo -e "\n🔎 Full logs saved in temporary files:"
  echo "  stdout: $compile_stdout"
  echo "  stderr: $compile_stderr"
  echo "💡 Tip: remove temp files when you no longer need them."
else
  # cleanup temp files
  rm -f "$compile_stdout" "$compile_stderr"
fi

echo -e "\n✨ Done. Have a great day! 🌞\n"
