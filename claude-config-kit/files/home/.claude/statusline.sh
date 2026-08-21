#!/bin/sh
#
# Claude Code status line. Reads the session JSON on stdin, prints two or three
# lines.
#
# Most variables here are assigned by the `eval` further down rather than by a
# literal assignment, which shellcheck cannot see through, so SC2154 would fire
# on every one of them.
# shellcheck disable=SC2154

input=$(cat)

# Real ESC bytes so color codes can be embedded directly in strings.
ESC=$(printf '\033')
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
RED="${ESC}[31m"
RESET="${ESC}[0m"

# --- helpers ------------------------------------------------------------

# 64016 -> 64k, 1500000 -> 1.5m
humanize() {
  awk -v t="$1" 'BEGIN {
    if (t >= 1000000) printf "%.1fm", t/1000000;
    else if (t >= 1000) printf "%.0fk", t/1000;
    else printf "%d", t;
  }'
}

# max context window: 1000000 -> 1M, 200000 -> 200k
fmt_max() {
  awk -v t="$1" 'BEGIN {
    if (t >= 1000000) printf "%gM", t/1000000;
    else printf "%gk", t/1000;
  }'
}

pick_color() {
  p="$1"
  if   [ "$p" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 70 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$GREEN"
  fi
}

# higher is better (cache hit rate): green when high, red when low
pick_color_good() {
  p="$1"
  if   [ "$p" -ge 90 ]; then printf '%s' "$GREEN"
  elif [ "$p" -ge 70 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$RED"
  fi
}

make_bar() {
  pct="$1"
  width=16
  filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  bar=""
  i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  while [ $i -lt $width ];  do bar="${bar}░"; i=$(( i + 1 )); done
  printf "%s" "$bar"
}

# format_rl <pct> <reset_epoch> <label> <date_fmt>
format_rl() {
  pct="$1"; reset_ts="$2"; label="$3"; datefmt="$4"
  [ -z "$pct" ] && return
  pct_int=$(printf '%.0f' "$pct" 2>/dev/null)
  [ -z "$pct_int" ] && return
  c=$(pick_color "$pct_int")
  reset_time=""
  if [ -n "$reset_ts" ]; then
    reset_time=$(date -r "$reset_ts" "$datefmt" 2>/dev/null || date -d "@$reset_ts" "$datefmt" 2>/dev/null)
  fi
  bar=$(make_bar "$pct_int")
  # Color only the bar + percentage; label and reset time stay neutral.
  if [ -n "$reset_time" ]; then
    printf '%s %s%s %s%%%s ⟳ %s' "$label" "$c" "$bar" "$pct_int" "$RESET" "$reset_time"
  else
    printf '%s %s%s %s%%%s' "$label" "$c" "$bar" "$pct_int" "$RESET"
  fi
}

# --- parse input (single jq call) ---------------------------------------
#
# Errors are silenced because this runs as a status line: anything jq writes to
# stderr on malformed input would surface as noise rather than a diagnostic.
# Every field below has a // fallback, so an empty eval degrades to the same
# "--" placeholders as a payload with nothing in it.

eval "$(echo "$input" | jq -r '
  "model="        + ((.model.display_name // "Unknown Model") | tostring | @sh),
  "effort="       + ((.effort.level // "") | tostring | @sh),
  "thinking="     + ((.thinking.enabled // false) | tostring | @sh),
  "output_style=" + ((.output_style.name // "") | tostring | @sh),
  "used_pct="     + ((.context_window.used_percentage // "") | tostring | @sh),
  "total_in="     + ((.context_window.total_input_tokens // "") | tostring | @sh),
  "ctx_size="     + ((.context_window.context_window_size // "") | tostring | @sh),
  "cache_read="   + ((.context_window.current_usage.cache_read_input_tokens // "") | tostring | @sh),
  "total_cost="   + ((.cost.total_cost_usd // "") | tostring | @sh),
  "rl5_pct="      + ((.rate_limits.five_hour.used_percentage // "") | tostring | @sh),
  "rl5_reset="    + ((.rate_limits.five_hour.resets_at // "") | tostring | @sh),
  "rl7_pct="      + ((.rate_limits.seven_day.used_percentage // "") | tostring | @sh),
  "rl7_reset="    + ((.rate_limits.seven_day.resets_at // "") | tostring | @sh),
  "current_dir="  + ((.workspace.current_dir // .cwd // .worktree.original_cwd // "") | tostring | @sh)
' 2>/dev/null)"

# Strip the " (1M context)" suffix Claude Code appends to the model name.
model="${model%% (*}"

# --- line 1: model | effort 💭 | [style] | context cache | cost ----------

cfg="🤖 ${model}"
[ -n "$effort" ] && cfg="${cfg} (${effort})"
[ "$thinking" = "true" ] && cfg="${cfg} 💭"
[ -n "$output_style" ] && [ "$output_style" != "default" ] && cfg="${cfg} | 🎨 ${output_style}"

if [ -n "$total_in" ]; then
  used_h=$(humanize "$total_in")
  if [ -n "$ctx_size" ]; then max_h=$(fmt_max "$ctx_size"); else max_h="?"; fi
  if [ -n "$used_pct" ]; then
    used_int=$(printf '%.0f' "$used_pct" 2>/dev/null)
    cc=$(pick_color "$used_int")
    ctx_str="🧠 ${used_h}/${max_h} (${cc}${used_int}%${RESET})"
  else
    ctx_str="🧠 ${used_h}/${max_h}"
  fi
else
  ctx_str="🧠 --"
fi

if [ -n "$cache_read" ] && [ -n "$total_in" ] && [ "$total_in" -gt 0 ] 2>/dev/null; then
  cache_pct=$(awk -v r="$cache_read" -v t="$total_in" 'BEGIN { printf "%.0f", r/t*100 }')
  ccache=$(pick_color_good "$cache_pct")
  cache_str="🎯 ${ccache}${cache_pct}%${RESET}"
else
  cache_str="🎯 --"
fi

if [ -n "$total_cost" ]; then
  cost_h=$(awk -v c="$total_cost" 'BEGIN { printf "%.2f", c }')
else
  cost_h="0.00"
fi
cost_str="💰 \$${cost_h}"

line1="${cfg} | ${ctx_str} · ${cache_str} | ${cost_str}"

# --- line 2: dir | worktree | git --------------------------------------
# One rev-parse fetches main repo root, worktree root, and branch in a single
# process. (--path-format=absolute requires git >= 2.31.)

git_common=""; top_level=""; branch=""
if git_info=$(git -C "$current_dir" rev-parse --path-format=absolute \
                --git-common-dir --show-toplevel --abbrev-ref HEAD 2>/dev/null); then
  {
    IFS= read -r git_common
    IFS= read -r top_level
    IFS= read -r branch
  } <<EOF
$git_info
EOF
fi

if [ -n "$top_level" ]; then
  main_root="${git_common%/*}"          # parent of the common .git dir
  dir_display="${main_root##*/}"
  # Linked worktree iff its toplevel differs from the main repo root.
  if [ "$main_root" != "$top_level" ]; then
    worktree_str="${top_level##*/}"
  else
    worktree_str="--"
  fi

  # Single working-tree scan. Count staged from the X column, modified from Y.
  counts=$(git -C "$current_dir" status --porcelain=v1 --untracked-files=no 2>/dev/null | awk '
    { x = substr($0, 1, 1); y = substr($0, 2, 1)
      if (x != " " && x != "?") s++
      if (y != " " && y != "?") m++ }
    END { printf "%d %d", s + 0, m + 0 }')
  staged="${counts%% *}"
  modified="${counts##* }"

  # --abbrev-ref reports the literal string "HEAD" when the checkout is
  # detached, which renders as a branch named HEAD. Show the commit instead.
  # The extra process runs only in the detached case, so the common path is
  # still the one rev-parse above.
  if [ "$branch" = "HEAD" ]; then
    short=$(git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)
    [ -n "$short" ] && branch="detached@${short}"
  fi

  git_str="$branch"
  [ "$staged" -gt 0 ]   2>/dev/null && git_str="${git_str} ${GREEN}+${staged}${RESET}"
  [ "$modified" -gt 0 ] 2>/dev/null && git_str="${git_str} ${YELLOW}~${modified}${RESET}"
else
  dir_display="${current_dir##*/}"
  worktree_str="--"
  git_str="no branch"
fi

line2="📁 ${dir_display} | 🌳 ${worktree_str} | 🌿 ${git_str}"

# --- line 3: rate limits (5h | 7d) -------------------------------------

rl5=$(format_rl "$rl5_pct" "$rl5_reset" "5h" "+%-I:%M%p")
rl7=$(format_rl "$rl7_pct" "$rl7_reset" "7d" "+%b %-d")
rl_line=""
[ -n "$rl5" ] && rl_line="$rl5"
if [ -n "$rl7" ]; then
  [ -n "$rl_line" ] && rl_line="${rl_line} | ${rl7}" || rl_line="$rl7"
fi

# --- emit ---------------------------------------------------------------

if [ -n "$rl_line" ]; then
  printf '%s\n%s\n%s' "$line2" "$line1" "$rl_line"
else
  printf '%s\n%s' "$line2" "$line1"
fi
