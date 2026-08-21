#!/usr/bin/env bash
# brew-upgrade-safe: upgrade formulae freely, gate casks by release age.
#
# Builds the full upgrade plan first, shows it, and asks for confirmation
# before changing anything.
#
# Targets bash 3.2, the version macOS ships. That means no mapfile, no
# associative arrays, and no bare "${arr[@]}" on a possibly-empty array
# (bash 3.2 treats that as an unbound variable under set -u).
set -euo pipefail

COOLDOWN_DAYS="${COOLDOWN_DAYS:-5}"
ASSUME_YES=0
DRY_RUN=0
GREEDY=0

# Formulae you still want gated (security-sensitive or cask-like binaries)
GATED_FORMULAE=(
  # add any here you want treated like casks, e.g.:
  # docker
  # some-vendor-binary-formula
)

# Packages to never hold back, formulae or casks alike. The cooldown protects
# you from a bad release; for these, a delayed security patch is the bigger
# risk. Browsers belong here: they are the most exposed attack surface on the
# machine and the most likely target of an actively exploited zero-day.
#
# Entries that are not installed via Homebrew are simply inert, since they
# never show up in `brew outdated`. On a stock macOS setup curl and git come
# from Apple (/usr/bin), and Homebrew's curl is keg-only so it stays off PATH
# even when some other formula pulls it in as a dependency. They are listed
# here to cover the case where you later install them with brew directly.
#
# claude-code is here for a different reason: it is already gated upstream.
# The cask follows npm's "stable" dist-tag, which Anthropic promotes roughly a
# week after "latest", so a version reaches Homebrew having already soaked.
# Gating it again would put installs ~2 weeks behind upstream for no extra
# safety, because the cooldown clock below starts at the tap commit and cannot
# see the earlier npm publish date.
NEVER_GATE=(
  google-chrome
  ca-certificates
  openssl@3
  curl
  git
  claude-code
)

usage() {
  cat <<'EOF'
Usage: brew-upgrade-safe [options]

Upgrades outdated formulae immediately, and holds back casks (plus any
explicitly gated formulae) until their definition has been published
upstream for at least the cooldown window.

Options:
  -y, --yes               Skip the confirmation prompt.
  -n, --dry-run           Show the plan and exit without upgrading.
  -d, --cooldown-days N   Cooldown window in days (default 5).
  -g, --greedy            Also consider casks that update themselves. Off by
                          default: for those apps Homebrew compares against a
                          stale install receipt rather than the version on
                          disk, so they show up as outdated when they are not.
  -h, --help              Show this help.

Environment:
  COOLDOWN_DAYS           Same as --cooldown-days.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -y|--yes)           ASSUME_YES=1 ;;
    -n|--dry-run)       DRY_RUN=1 ;;
    -g|--greedy)        GREEDY=1 ;;
    # Check for the value before consuming it. Without this, the trailing
    # shift below runs with no arguments left, fails, and set -e kills the
    # script before the validation underneath can report anything.
    -d|--cooldown-days)
      if (( $# < 2 )); then
        printf '%s requires a value\n\n' "$1" >&2; usage >&2; exit 2
      fi
      COOLDOWN_DAYS="$2"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! [[ "$COOLDOWN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "Cooldown days must be a non-negative integer (got: '$COOLDOWN_DAYS')" >&2
  exit 2
fi

for tool in brew jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool not found: $tool" >&2; exit 1; }
done

# gh gives an authenticated GitHub API rate limit (5000/hr vs 60/hr anonymous),
# which matters because we make one API call per gated package.
HAVE_GH=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  HAVE_GH=1
fi

now=$(date -u +%s)
cooldown_secs=$(( COOLDOWN_DAYS * 86400 ))
TAB=$'\t'

in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

iso_to_epoch() {
  local d="$1"
  # BSD date (macOS) first, GNU date as a fallback. Both need an explicit UTC
  # flag: the input carries a trailing Z, but neither reads it, so without -u
  # they parse the timestamp in the local zone and every age comes out short
  # by the UTC offset.
  date -ujf "%Y-%m-%dT%H:%M:%SZ" "$d" +%s 2>/dev/null \
    || date -u -d "$d" +%s 2>/dev/null \
    || true
}

# Newest commit that published $version of the package whose definition lives
# at $path. Echoes an ISO 8601 date, or nothing.
#
# The newest commit touching the file is NOT a usable answer on its own.
# Homebrew periodically sweeps casks for style, arch and metadata fixes, and
# such a commit landing after a version bump would reset the cooldown clock on
# a version that has been in the tap for days. So prefer the newest commit
# whose subject mentions the version (bump commits are titled "<name> <ver>"),
# and fall back to the newest commit when nothing matches.
github_last_commit_date() {
  local repo="$1" path="$2" version="$3" json

  if (( HAVE_GH )); then
    json=$(gh api "repos/${repo}/commits?path=${path}&per_page=30" 2>/dev/null || true)
  else
    json=$(curl -fsSL "https://api.github.com/repos/${repo}/commits?path=${path}&per_page=30" 2>/dev/null || true)
  fi
  [[ -z "$json" ]] && return 0

  printf '%s' "$json" | jq -r --arg v "$version" '
    ([.[]? | select(.commit.message | contains($v))][0] // .[0]?)
    | .commit.committer.date // empty' 2>/dev/null || true
}

# When did this version of the package land in its tap?
# Echoes a unix timestamp, or nothing if it cannot be determined.
#
# This asks about the package's own .rb file. The tap's HEAD commit is NOT a
# usable substitute: it is the same value for every package in the tap and it
# is refreshed by `brew update`, so it would report every package as brand new
# and hold everything back forever.
#
# Note this measures packaging, not the upstream release. For a cask whose
# livecheck follows a delayed release channel, the version can be weeks old
# upstream by the time Homebrew first sees it, and the clock still starts here.
# NEVER_GATE is the escape hatch for those.
package_released_at() {
  local name="$1" kind="$2" version="$3"
  local info tap path repo date_str

  if [[ "$kind" == "cask" ]]; then
    info=$(brew info --json=v2 --cask "$name" 2>/dev/null \
      | jq -r '.casks[0] | [(.tap // ""), (.ruby_source_path // "")] | @tsv' 2>/dev/null || true)
  else
    info=$(brew info --json=v2 --formula "$name" 2>/dev/null \
      | jq -r '.formulae[0] | [(.tap // ""), (.ruby_source_path // "")] | @tsv' 2>/dev/null || true)
  fi
  [[ -z "$info" ]] && return 0

  tap="${info%%"$TAB"*}"
  path="${info#*"$TAB"}"
  [[ -z "$tap" || -z "$path" || "$path" == "$info" ]] && return 0

  # Tap "homebrew/core" lives at github.com/homebrew/homebrew-core, and
  # "homebrew/cask" at homebrew/homebrew-cask. Casks are not in core, so
  # deriving the repo from the tap is what keeps cask lookups working.
  repo="${tap%%/*}/homebrew-${tap#*/}"

  date_str=$(github_last_commit_date "$repo" "$path" "$version")
  [[ -z "$date_str" ]] && return 0

  iso_to_epoch "$date_str"
}

# The version a cask reports as installed comes from Homebrew's install
# receipt, which records the version at install time and is never refreshed
# when an app updates itself. For a self-updating app that receipt can be many
# releases stale, which would make the plan overstate how far behind you are.
# Read the version out of the app bundle instead when we can find it.
# Echoes nothing if the cask has no readable .app artifact (pkg-based casks,
# binaries, custom install targets).
cask_disk_version() {
  local name="$1" app dir plist v
  app=$(brew info --json=v2 --cask "$name" </dev/null 2>/dev/null \
    | jq -r '.casks[0].artifacts[]? | .app[]? | select(type == "string")' 2>/dev/null \
    | head -1)
  [[ -z "$app" ]] && return 0

  for dir in /Applications "$HOME/Applications"; do
    plist="$dir/$app/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
      v=$(defaults read "$plist" CFBundleShortVersionString 2>/dev/null || true)
      [[ -n "$v" ]] && printf '%s' "$v"
      return 0
    fi
  done
}

short_ver() {
  local v="${1:-?}"
  if (( ${#v} > 22 )); then printf '%s...' "${v:0:19}"; else printf '%s' "$v"; fi
}

echo "==> Running brew update" >&2
brew update >/dev/null

# --- Collect outdated packages, with versions, before touching anything ---
# Entries are TSV: name <TAB> installed <TAB> current
# Pinned packages are filtered out because `brew upgrade` will not move them.

outdated_formulae=()
while IFS= read -r line; do
  [[ -n "$line" ]] && outdated_formulae+=("$line")
done < <(brew outdated --json=v2 --formula 2>/dev/null \
  | jq -r '.formulae[]? | select(.pinned | not)
           | [.name, (.installed_versions // [] | join(", ")), (.current_version // "")] | @tsv')

# Plain `brew outdated --cask` compares a self-updating app against the version
# actually on disk. --greedy-auto-updates compares against Homebrew's install
# receipt instead, which goes stale the moment the app updates itself, so apps
# that are already current get reported as many versions behind. Opt in only.
cask_args=(--json=v2 --cask)
(( GREEDY )) && cask_args+=(--greedy-auto-updates)

outdated_casks=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  IFS="$TAB" read -r cname cinstalled ccurrent <<< "$line"
  cdisk=$(cask_disk_version "$cname")
  [[ -n "$cdisk" ]] && cinstalled="$cdisk"
  outdated_casks+=("$cname$TAB$cinstalled$TAB$ccurrent")
done < <(brew outdated "${cask_args[@]}" 2>/dev/null \
  | jq -r '.casks[]? | [.name, (.installed_versions // [] | join(", ")), (.current_version // "")] | @tsv')

# --- Classify ---
# Every bucket below holds TSV: kind <TAB> name <TAB> installed <TAB> current
#
# free:       upgrade immediately, no cooldown
# candidates: subject to the cooldown check
free=()
candidates=()

# Formulae upgrade freely unless explicitly gated. NEVER_GATE overrides that,
# so a formula listed in both still upgrades immediately.
for entry in ${outdated_formulae[@]+"${outdated_formulae[@]}"}; do
  name="${entry%%"$TAB"*}"
  if in_list "$name" ${NEVER_GATE[@]+"${NEVER_GATE[@]}"}; then
    free+=("formula$TAB$entry")
  elif in_list "$name" ${GATED_FORMULAE[@]+"${GATED_FORMULAE[@]}"}; then
    candidates+=("formula$TAB$entry")
  else
    free+=("formula$TAB$entry")
  fi
done

# Casks are gated by default, but NEVER_GATE applies to them too so that
# security-critical apps are not left sitting on a known-vulnerable version.
for entry in ${outdated_casks[@]+"${outdated_casks[@]}"}; do
  name="${entry%%"$TAB"*}"
  if in_list "$name" ${NEVER_GATE[@]+"${NEVER_GATE[@]}"}; then
    free+=("cask$TAB$entry")
  else
    candidates+=("cask$TAB$entry")
  fi
done

ready=()    # kind <TAB> name <TAB> installed <TAB> current <TAB> age_days
holding=()  # kind <TAB> name <TAB> installed <TAB> current <TAB> reason

total=${#candidates[@]}
checked=0
for entry in ${candidates[@]+"${candidates[@]}"}; do
  IFS="$TAB" read -r kind name installed current <<< "$entry"
  checked=$(( checked + 1 ))
  printf '\r==> Checking release age (%d/%d): %-30.30s' "$checked" "$total" "$name" >&2

  pushed=$(package_released_at "$name" "$kind" "$current")
  if [[ -z "$pushed" ]]; then
    holding+=("$kind$TAB$name$TAB$installed$TAB$current${TAB}release date unknown")
    continue
  fi
  age=$(( now - pushed ))
  (( age < 0 )) && age=0
  days=$(( age / 86400 ))
  if (( age >= cooldown_secs )); then
    ready+=("$kind$TAB$name$TAB$installed$TAB$current$TAB$days")
  else
    holding+=("$kind$TAB$name$TAB$installed$TAB$current$TAB${days}d old")
  fi
done
(( total > 0 )) && printf '\r%-70s\r' '' >&2

# --- Show the plan ---
if (( ${#free[@]} == 0 && ${#ready[@]} == 0 && ${#holding[@]} == 0 )); then
  echo "==> Everything is up to date."
  exit 0
fi

# Align the name column across every section.
namew=4
for entry in ${free[@]+"${free[@]}"} ${ready[@]+"${ready[@]}"} ${holding[@]+"${holding[@]}"}; do
  rest="${entry#*"$TAB"}"; n="${rest%%"$TAB"*}"; (( ${#n} > namew )) && namew=${#n}
done

echo "==> Upgrade plan"
echo

if (( ${#free[@]} > 0 )); then
  printf '  No cooldown (%d)\n' "${#free[@]}"
  for entry in "${free[@]}"; do
    IFS="$TAB" read -r kind name installed current <<< "$entry"
    note="$kind"
    in_list "$name" ${NEVER_GATE[@]+"${NEVER_GATE[@]}"} && note="$kind, never gated"
    printf '    %-*s  %s -> %s  [%s]\n' \
      "$namew" "$name" "$(short_ver "$installed")" "$(short_ver "$current")" "$note"
  done
  echo
fi

if (( ${#ready[@]} > 0 )); then
  printf '  Past cooldown, >= %d days (%d)\n' "$COOLDOWN_DAYS" "${#ready[@]}"
  for entry in "${ready[@]}"; do
    IFS="$TAB" read -r kind name installed current days <<< "$entry"
    printf '    %-*s  %s -> %s  [%s, %sd old]\n' \
      "$namew" "$name" "$(short_ver "$installed")" "$(short_ver "$current")" "$kind" "$days"
  done
  echo
fi

if (( ${#holding[@]} > 0 )); then
  printf '  Holding back, < %d days (%d)\n' "$COOLDOWN_DAYS" "${#holding[@]}"
  for entry in "${holding[@]}"; do
    IFS="$TAB" read -r kind name installed current reason <<< "$entry"
    printf '    %-*s  %s -> %s  [%s, %s]\n' \
      "$namew" "$name" "$(short_ver "$installed")" "$(short_ver "$current")" "$kind" "$reason"
  done
  echo
fi

upgrade_count=$(( ${#free[@]} + ${#ready[@]} ))
if (( upgrade_count == 0 )); then
  echo "Nothing to upgrade right now; everything outdated is still in cooldown."
  exit 0
fi

if (( DRY_RUN )); then
  echo "Dry run: no changes made."
  exit 0
fi

# --- Confirm ---
if (( ! ASSUME_YES )); then
  if [[ ! -t 0 ]]; then
    echo "Not running interactively. Re-run with --yes to apply. Nothing upgraded." >&2
    exit 1
  fi
  printf 'Upgrade these %d package(s)? [y/N] ' "$upgrade_count"
  reply=""
  read -r reply || true
  case "$reply" in
    y|Y|yes|YES|Yes) ;;
    *) echo "Aborted. Nothing upgraded."; exit 1 ;;
  esac
  echo
fi

# --- Execute ---
# Formulae and casks go in separate `brew upgrade` calls because the two need
# different flags, and splitting them keeps one failure from blocking the rest.
# That isolation needs the `|| failed=1` on each call: without it set -e would
# abort on the first non-zero brew and skip every later group.
failed=0
if (( ${#free[@]} > 0 )); then
  free_formulae=()
  free_casks=()
  for entry in "${free[@]}"; do
    IFS="$TAB" read -r kind name installed current <<< "$entry"
    if [[ "$kind" == "cask" ]]; then free_casks+=("$name"); else free_formulae+=("$name"); fi
  done
  if (( ${#free_formulae[@]} > 0 )); then
    echo "==> Upgrading formulae: ${free_formulae[*]}"
    brew upgrade --formula "${free_formulae[@]}" || failed=1
  fi
  if (( ${#free_casks[@]} > 0 )); then
    echo "==> Upgrading casks, cooldown bypassed: ${free_casks[*]}"
    brew upgrade --cask "${free_casks[@]}" || failed=1
  fi
fi

if (( ${#ready[@]} > 0 )); then
  ready_formulae=()
  ready_casks=()
  for entry in "${ready[@]}"; do
    IFS="$TAB" read -r kind name installed current days <<< "$entry"
    if [[ "$kind" == "cask" ]]; then ready_casks+=("$name"); else ready_formulae+=("$name"); fi
  done
  if (( ${#ready_formulae[@]} > 0 )); then
    echo "==> Upgrading gated formulae past cooldown: ${ready_formulae[*]}"
    brew upgrade --formula "${ready_formulae[@]}" || failed=1
  fi
  if (( ${#ready_casks[@]} > 0 )); then
    echo "==> Upgrading casks past cooldown: ${ready_casks[*]}"
    brew upgrade --cask "${ready_casks[@]}" || failed=1
  fi
fi

if (( failed )); then
  echo "==> Done, but at least one brew upgrade failed. See the output above." >&2
  exit 1
fi

echo "==> Done."
