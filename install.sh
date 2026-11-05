#!/usr/bin/env bash
# clod: your Claude Code setup, kept in this repo and installed into
# Claude Code's config dir ($CLAUDE_CONFIG_DIR, else ~/.claude).
#
#   ./install.sh [install]   copy rules, skills, agents and commands in, merge
#                            settings.json, add MCP servers, link `clod`
#   clod status              what clod put here
#   clod uninstall           take it back out (settings stay; see README)
#
# Options: --yes (never ask), --dry-run (say what would change, change
# nothing). Needs bash 3.2+ and jq; `claude` for MCP servers.

set -uo pipefail

resolve_self() {
	local src=$1 dir target
	while [ -L "$src" ]; do
		dir=$(cd -P "$(dirname "$src")" && pwd)
		target=$(readlink "$src")
		case $target in
		/*) src=$target ;;
		*) src=$dir/$target ;;
		esac
	done
	cd -P "$(dirname "$src")" && pwd
}

REPO=$(resolve_self "${BASH_SOURCE[0]}")
SRC="$REPO/claude"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/clod"
MANIFEST="$STATE_DIR/manifest.tsv"
BIN_LINK="$HOME/.local/bin/clod"
CLAUDE_BIN="${CLOD_CLAUDE:-claude}"

DRY=0
YES=0
CMD=install
# the manifest this run builds, moved over MANIFEST once it's done
NEW=$(mktemp "${TMPDIR:-/tmp}/clod.XXXXXX") || exit 1
trap 'rm -f "$NEW"' EXIT

say() { printf '%s\n' "$*"; }
warn() { printf 'clod: %s\n' "$*" >&2; }
die() {
	warn "$*"
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1; }

usage() {
	sed -n '2,11p' "$REPO/install.sh" | sed 's/^# \{0,1\}//'
}

# run does what it's given, or says it would under --dry-run
run() {
	if [ "$DRY" = 1 ]; then
		say "  would: $*"
		return 0
	fi
	"$@"
}

# manifest lines are "kind<TAB>value": file <path>, mcp <name>
remember() {
	printf '%s\t%s\n' "$1" "$2" >>"$NEW"
}

owned() {
	[ -f "$MANIFEST" ] && grep -qxF "$(printf '%s\t%s' "$1" "$2")" "$MANIFEST"
}

# copy_tree copies every file under $SRC/$1 to $CLAUDE_DIR/$2, keeping the
# layout. A file clod didn't write is someone's own: it's left alone
copy_tree() {
	local from="$SRC/$1" to="$CLAUDE_DIR/$2" rel dest
	[ -d "$from" ] || return 0
	while IFS= read -r rel; do
		rel=${rel#./}
		dest="$to/$rel"
		if [ -e "$dest" ] && ! owned file "$dest"; then
			warn "$dest is yours, not clod's; left it alone"
			continue
		fi
		if [ -f "$dest" ] && cmp -s "$from/$rel" "$dest"; then
			remember file "$dest"
			continue
		fi
		say "  $dest"
		run mkdir -p "$(dirname "$dest")"
		run cp "$from/$rel" "$dest"
		remember file "$dest"
	done < <(cd "$from" && find . -type f ! -name '.gitkeep' | LC_ALL=C sort)
}

# merge_settings merges claude/settings.json into Claude Code's: objects
# merge key by key, lists are joined without repeats, and clod's value wins
# anywhere else
merge_settings() {
	local ours="$SRC/settings.json" theirs="$CLAUDE_DIR/settings.json" current='{}' merged
	[ -f "$ours" ] || return 0
	jq empty "$ours" 2>/dev/null || die "$ours isn't valid JSON"
	if [ -f "$theirs" ]; then
		current=$(jq . "$theirs" 2>/dev/null) || die "$theirs isn't valid JSON; fix it, then run clod apply"
	fi
	merged=$(jq -n --argjson a "$current" --slurpfile b "$ours" '
		def merge(a; b):
			if (a | type) == "object" and (b | type) == "object" then
				reduce (b | keys_unsorted[]) as $k (a; .[$k] = merge(a[$k]; b[$k]))
			elif (a | type) == "array" and (b | type) == "array" then
				a + [b[] | select(. as $x | a | index([$x]) | not)]
			else b end;
		merge($a; $b[0] | del(."$schema"))
	') || die "couldn't merge $ours into $theirs"
	if [ -f "$theirs" ] && [ "$merged" = "$current" ]; then
		return 0
	fi
	say "  $theirs (merged)"
	if [ "$DRY" = 0 ]; then
		mkdir -p "$CLAUDE_DIR"
		printf '%s\n' "$merged" >"$theirs.tmp" && mv "$theirs.tmp" "$theirs"
	fi
}

# add_mcp adds each server in claude/mcp.json at user scope through claude.
# One you already have is left as it is
add_mcp() {
	local file="$SRC/mcp.json" name json
	[ -f "$file" ] || return 0
	jq empty "$file" 2>/dev/null || die "$file isn't valid JSON"
	[ "$(jq '.servers // {} | length' "$file")" = 0 ] && return 0
	if ! need "$CLAUDE_BIN"; then
		warn "claude isn't installed, so the MCP servers were skipped; run 'clod apply' once it is"
		return 0
	fi
	while IFS= read -r name; do
		if "$CLAUDE_BIN" mcp get "$name" >/dev/null 2>&1; then
			owned mcp "$name" && remember mcp "$name"
			continue
		fi
		json=$(jq -c --arg n "$name" '.servers[$n]' "$file")
		say "  MCP server $name"
		run "$CLAUDE_BIN" mcp add-json --scope user "$name" "$json" >/dev/null || die "claude mcp add-json $name failed"
		remember mcp "$name"
	done < <(jq -r '.servers // {} | keys[]' "$file")
}

link_bin() {
	if [ -L "$BIN_LINK" ] && [ "$(readlink "$BIN_LINK")" = "$REPO/install.sh" ]; then
		return 0
	fi
	if [ -e "$BIN_LINK" ] || [ -L "$BIN_LINK" ]; then
		warn "$BIN_LINK exists and isn't clod's; left it alone"
		return 0
	fi
	say "  $BIN_LINK"
	run mkdir -p "$(dirname "$BIN_LINK")"
	run ln -s "$REPO/install.sh" "$BIN_LINK"
}

# forget_stale removes what an earlier run installed and this one didn't
forget_stale() {
	[ -f "$MANIFEST" ] || return 0
	local kind value
	while IFS="$(printf '\t')" read -r kind value; do
		grep -qxF "$(printf '%s\t%s' "$kind" "$value")" "$NEW" && continue
		case $kind in
		file)
			say "  removed $value"
			run rm -f "$value"
			;;
		mcp)
			say "  removed MCP server $value"
			run "$CLAUDE_BIN" mcp remove --scope user "$value" >/dev/null 2>&1
			;;
		esac
	done <"$MANIFEST"
}

install() {
	need jq || die "jq is required (macOS 15+ ships it; otherwise brew install jq, apt install jq or pacman -S jq)"
	if [ "$YES" = 0 ] && [ -t 0 ] && [ "$DRY" = 0 ]; then
		printf 'Install clod into %s? [Y/n] ' "$CLAUDE_DIR"
		IFS= read -r ans || ans=""
		case $ans in [nN]*) say "Nothing changed."; return 0 ;; esac
	fi
	say "clod -> $CLAUDE_DIR"
	copy_tree rules rules/clod
	copy_tree skills skills
	copy_tree agents agents
	copy_tree commands commands
	merge_settings
	add_mcp
	forget_stale
	link_bin
	if [ "$DRY" = 0 ]; then
		mkdir -p "$STATE_DIR"
		cp "$NEW" "$MANIFEST"
	fi
	say "Done."
}

status() {
	say "Claude Code config: $CLAUDE_DIR"
	if [ ! -s "$MANIFEST" ]; then
		say "clod hasn't installed anything here; run install.sh"
		return 0
	fi
	local kind value
	while IFS="$(printf '\t')" read -r kind value; do
		case $kind in
		file) [ -f "$value" ] && say "  $value" || say "  $value (missing)" ;;
		mcp) say "  MCP server $value" ;;
		esac
	done <"$MANIFEST"
}

uninstall() {
	if [ -f "$MANIFEST" ]; then
		forget_stale
		[ "$DRY" = 0 ] && rm -f "$MANIFEST"
	fi
	if [ -L "$BIN_LINK" ] && [ "$(readlink "$BIN_LINK")" = "$REPO/install.sh" ]; then
		run rm -f "$BIN_LINK"
	fi
	say "Took clod out. settings.json keeps what it merged in; edit it if you want that gone too."
}

while [ $# -gt 0 ]; do
	case $1 in
	install | apply) CMD=install ;;
	status | uninstall) CMD=$1 ;;
	--yes | -y) YES=1 ;;
	--dry-run) DRY=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		warn "unknown argument: $1"
		usage >&2
		exit 2
		;;
	esac
	shift
done

"$CMD"
