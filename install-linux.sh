#!/usr/bin/env bash
# Installs the keyboard chatter filter on Linux as a systemd service (starts now and at boot).
#   sudo ./install-linux.sh [--threshold MS] [--keys E,L] [--vid 36ae --pid fe9c]
#   sudo ./install-linux.sh --uninstall
# Re-running it with different options replaces the settings and restarts the filter.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin=/usr/local/bin/chatter-filter-linux.py
unit=/etc/systemd/system/chatter-filter.service
modconf=/etc/modules-load.d/chatter-filter-uinput.conf

uninstall() {
    systemctl disable --now chatter-filter 2>/dev/null || true
    rm -f "$unit" "$bin" "$modconf"
    systemctl daemon-reload
    echo "Uninstalled. This folder was left as is."
}

threshold=40
opts=()
while (($#)); do
    case "$1" in
        --uninstall) uninstall; exit 0 ;;
        --threshold) threshold="$2"; shift 2 ;;
        --keys|--vid|--pid) opts+=("$1" "$2"); shift 2 ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$dir/chatter-filter-linux.py" ]]; then
    echo "chatter-filter-linux.py is missing from $dir" >&2
    exit 1
fi

# 1. python-evdev from the distro (the service runs with the system Python).
if ! python3 -c 'import evdev' 2>/dev/null; then
    echo "Installing python-evdev..."
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) apt-get update -q && apt-get install -y python3-evdev ;;
        *" fedora "*|*" rhel "*|*" centos "*) dnf install -y python3-evdev ;;
        *" arch "*) pacman -S --noconfirm --needed python-evdev ;;
        *suse*) zypper install -y python3-evdev ;;
        *) echo "Unknown distro '${ID:-?}': install python evdev for python3 yourself, then re-run." >&2; exit 1 ;;
    esac
    python3 -c 'import evdev'
fi

# 2. uinput (the virtual keyboard), now and at boot.
modprobe uinput
echo uinput > "$modconf"

# 3. The script, with Windows line endings stripped in case it was copied from Windows.
sed 's/\r$//' "$dir/chatter-filter-linux.py" > "$bin"
chmod 755 "$bin"

# 4. The service.
python=$(command -v python3)
args="--threshold $threshold ${opts[*]:-}"
cat > "$unit" <<EOF
[Unit]
Description=Keyboard chatter filter (per-key debounce)

[Service]
ExecStart=$python $bin ${args% }
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chatter-filter >/dev/null
systemctl restart chatter-filter
sleep 2

# 5. Report.
vid=36ae; pid=fe9c
for ((i = 0; i < ${#opts[@]}; i += 2)); do
    case "${opts[i]}" in
        --vid) vid="${opts[i+1],,}" ;;
        --pid) pid="${opts[i+1],,}" ;;
    esac
done
if ! "$python" "$bin" --list 2>/dev/null | grep -q "$vid:$pid"; then
    echo "Note: no keyboard with ID $vid:$pid is connected right now. The filter waits and attaches when it is plugged in."
fi

if systemctl is-active --quiet chatter-filter; then
    echo "Filter is running ($args). It starts automatically at every boot."
    echo "Watch it:  journalctl -u chatter-filter -f"
else
    echo "The filter did not stay running. Recent log:" >&2
    journalctl -u chatter-filter -n 20 --no-pager >&2
    exit 1
fi
