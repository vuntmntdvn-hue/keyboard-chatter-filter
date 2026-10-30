#!/usr/bin/env bash
# Installs the keyboard chatter filter on macOS as a LaunchAgent (starts now and at every login).
#   ./install-macos.sh [--threshold MS] [--keys E,L]
#   ./install-macos.sh --uninstall
# Re-running it with different options replaces the settings and restarts the filter.
# Runs as your user, not root: an event tap belongs to the login session.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label=com.chatter-filter
bin="$HOME/.local/bin/chatter-filter-macos"
plist="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/chatter-filter.log"
domain="gui/$(id -u)"

uninstall() {
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist" "$bin"
    echo "Uninstalled. Also remove chatter-filter-macos from System Settings > Privacy & Security > Accessibility."
}

threshold=40
opts=()
while (($#)); do
    case "$1" in
        --uninstall) uninstall; exit 0 ;;
        --threshold) threshold="$2"; shift 2 ;;
        --keys) opts+=("$1" "$2"); shift 2 ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$dir/chatter-filter-macos.swift" ]]; then
    echo "chatter-filter-macos.swift is missing from $dir" >&2
    exit 1
fi
if ! command -v swiftc >/dev/null; then
    echo "swiftc is missing. Install the command line tools: xcode-select --install" >&2
    exit 1
fi

# 1. Build. The binary is replaced only when it changed: macOS ties the Accessibility
#    permission to this exact binary, so a new one has to be allowed again.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Building..."
swiftc -O -o "$tmp/chatter-filter-macos" "$dir/chatter-filter-macos.swift"
mkdir -p "$(dirname "$bin")"
if ! cmp -s "$tmp/chatter-filter-macos" "$bin"; then
    install -m 755 "$tmp/chatter-filter-macos" "$bin"
    rebuilt=1
fi

# 2. The LaunchAgent.
args=(--threshold "$threshold" ${opts[@]+"${opts[@]}"})
mkdir -p "$(dirname "$plist")" "$(dirname "$logfile")"
{
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$bin</string>
EOF
    for a in "${args[@]}"; do echo "        <string>$a</string>"; done
    cat <<EOF
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>$logfile</string>
    <key>StandardErrorPath</key><string>$logfile</string>
</dict>
</plist>
EOF
} > "$plist"

launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist"
sleep 2

# 3. Report.
if ! ioreg -p IOUSB -l -w0 | grep -q '"idVendor" = 13998'; then
    echo "Note: the SDCX keyboard (36ae:fe9c) isn't connected right now. That's fine: every keyboard is filtered."
fi
if ! launchctl print "$domain/$label" 2>/dev/null | grep -q 'state = running'; then
    echo "The filter did not stay running. Recent log:" >&2
    tail -n 20 "$logfile" >&2
    exit 1
fi
echo "Filter is running (${args[*]}). It starts automatically at every login."
if [[ -n "${rebuilt:-}" ]] || tail -n 3 "$logfile" | grep -q 'waiting for Accessibility'; then
    echo "If it isn't allowed yet: System Settings > Privacy & Security > Accessibility,"
    echo "turn on chatter-filter-macos (remove an old entry with the same name first)."
fi
echo "Watch it:  tail -f $logfile"
