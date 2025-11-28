#!/usr/bin/env bash
# compile_and_push.sh - sectioned, pretty latexmk compile + git + logging
set -euo pipefail

# ---------- Config ----------
LATEXMK_CMD="${LATEXMK_CMD:-latexmk -pdflua -interaction=nonstopmode -file-line-error}"
LOG_FILE="${LOG_FILE:-compile_log.txt}"
EXCERPT_LINES="${EXCERPT_LINES:-20}"

# ---------- Helpers ----------
timestamp_human() { date +"%Y-%m-%d %H:%M:%S"; }
timestamp_iso()   { date +"%Y-%m-%dT%H:%M:%S%z"; }
secs_to_hms() { local s=$1; printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); }

# Colors
bold="\033[1m"; dim="\033[2m"; red="\033[31m"; green="\033[32m"
yellow="\033[33m"; magenta="\033[35m"; reset="\033[0m"

# Temp files
compile_out="$(mktemp --suffix=_compile.txt)"
compile_log="$(mktemp --suffix=_compile_log.txt)"

# ---------- Start ----------
echo -e "${bold}📦 LaTeX Compilation Start${reset}"
echo "⏱ $(timestamp_human)"
echo "📝 Command: $LATEXMK_CMD"

start_epoch=$(date +%s)

# Run LaTeX
set +e
bash -lc "$LATEXMK_CMD" > >(tee "$compile_out") 2> >(tee "$compile_log" >&2)
compile_exit=${PIPESTATUS[0]:-0}
set -e

end_epoch=$(date +%s)
duration=$((end_epoch - start_epoch))
duration_hms=$(secs_to_hms $duration)

# ---------- Sections ----------
echo -e "\n${bold}⚠️ Warnings${reset}"
warnings=$(grep -E "LaTeX Warning|Warning:" "$compile_out" || true)
if [ -n "$warnings" ]; then
    echo "$warnings" | tail -n $EXCERPT_LINES | sed 's/^/    /'
else
    echo "    None"
fi

echo -e "\n${bold}❌ Errors${reset}"
errors=$(grep -E '^!|Error:|Fatal' "$compile_out" || true)
if [ -n "$errors" ]; then
    echo "$errors" | tail -n $EXCERPT_LINES | sed 's/^/    /'
else
    echo "    None"
fi

echo -e "\n${bold}📐 Overfull / Underfull Boxes${reset}"
overfull=$(grep "Overfull \\\\hbox" "$compile_out" || true)
underfull=$(grep "Underfull \\\\hbox" "$compile_out" || true)
if [ -n "$overfull" ]; then
    echo -e "${yellow}Overfull:${reset}"
    echo "$overfull" | tail -n $EXCERPT_LINES | sed 's/^/    /'
fi
if [ -n "$underfull" ]; then
    echo -e "${magenta}Underfull:${reset}"
    echo "$underfull" | tail -n $EXCERPT_LINES | sed 's/^/    /'
fi
if [ -z "$overfull$underfull" ]; then
    echo "    None"
fi

# PDF Info
pdf_file=$(ls -t *.pdf 2>/dev/null | head -n1 || true)
if [ -n "$pdf_file" ]; then
    pdf_size=$(stat -c%s "$pdf_file" 2>/dev/null || echo 0)
    human_size=$(numfmt --to=iec --format="%.1f" "$pdf_size" 2>/dev/null || echo "${pdf_size} B")
    echo -e "\n${bold}📄 PDF Output:${reset} $pdf_file — $human_size"
else
    echo -e "\n${bold}📄 PDF Output:${reset} None"
fi

# ---------- Git operations ----------
echo -e "\n${bold}🔎 Git Operations${reset}"
git add -A
if git diff --cached --quiet --exit-code; then
    git_action="SKIPPED (no changes)"
    commit_hash="SKIP"
    echo "💤 Nothing to commit"
else
    commit_time=$(timestamp_iso)
    commit_msg="Auto-compile: $(timestamp_human)"
    GIT_AUTHOR_DATE="$commit_time" GIT_COMMITTER_DATE="$commit_time" git commit -m "$commit_msg" --no-verify
    commit_hash=$(git rev-parse --short HEAD)
    echo "✍️ Created commit $commit_hash"
    if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
        git push && git_action="pushed" || git_action="push_failed"
    else
        git push -u origin HEAD && git_action="pushed (set-upstream)" || git_action="push_failed"
    fi
fi

# ---------- Logging ----------
log_line="$(timestamp_human) | duration=${duration}s | status=$compile_exit | commit=$commit_hash | git_action=$git_action"
echo "$log_line" >> "$LOG_FILE"
echo -e "\n📝 Log appended: $log_line"

# ---------- Summary ----------
echo -e "\n${bold}⏱ Total Duration:${reset} ${duration_hms} (${duration}s)"
[ "$compile_exit" -ne 0 ] && echo -e "${red}❌ Compile failed${reset}" || echo -e "${green}✅ Compile success${reset}"

# Cleanup temp
rm -f "$compile_out" "$compile_log"

exit "$compile_exit"
