#!/usr/bin/env bash
# Set up the Steam Machine's commands, all in the home folder, which SteamOS
# updates keep:
# - fix runs ~/install-xone.sh, which puts xone back after a SteamOS update,
#   and each new terminal says so.
# - mount with no arguments mounts the stick named SHARE and lists the
#   commands in its commands folder. Entering one of their names runs it,
#   mounting the stick first when needed.
# - ~/fix-xbox-controllers.sh, copied from fix-xbox-controllers.sh, is what
#   Fix Xbox controllers in the Steam library runs: it takes updates and
#   run/ jobs from the stick, checks the library entries, puts xone back and
#   checks the adapter. steambox-library.service changes the entries as the
#   Steam Machine starts, while Steam is not running.
# - steambox-padlog.service runs padlog.py watch all the time, which notes
#   each Xbox pad that drops, and Fix Xbox controllers reports on them.
# - library.py, xone-debug.sh, adapter-wake.sh, padlog.py, fix-end.sh and
#   the art are copied to ~/.local/share/steambox, and library.py then puts
#   Fix Xbox controllers in the library where missing, which closes Steam.
# - Konsole opens by itself in Desktop Mode.
# Running it again replaces what an earlier run added. With --update, which
# Fix Xbox controllers passes in Gaming Mode, it leaves the library alone.

update=false
[ "${1:-}" = --update ] && update=true
here=$(cd "$(dirname "$0")" && pwd)
cp "$here/install-xone.sh" "$HOME/install-xone.sh" &&
  chmod +x "$HOME/install-xone.sh" || exit 1

lib="$HOME/.local/share/steambox"
mkdir -p "$lib" &&
  cp "$here/library.py" "$here/xone-debug.sh" "$here/adapter-wake.sh" \
    "$here/padlog.py" "$here/fix-end.sh" "$lib/" &&
  chmod +x "$lib/xone-debug.sh" &&
  cp -r "$here/fix-art" "$lib/" || exit 1

# A new file in place of the old, so a running Fix Xbox controllers keeps
# reading the old one.
wrapper="$HOME/fix-xbox-controllers.sh"
tmp=$(mktemp "$wrapper.XXXXXX") && cp "$here/fix-xbox-controllers.sh" "$tmp" &&
  chmod +x "$tmp" && mv -f -- "$tmp" "$wrapper" || exit 1

rc="$HOME/.bashrc"
touch "$rc" || exit 1
tmp=$(mktemp) || exit 1
awk '/^# >>> (Xbox controller fix|Steam Machine commands) >>>$/ {skip = 1}
  !skip {print}
  /^# <<< (Xbox controller fix|Steam Machine commands) <<<$/ {skip = 0}' \
  "$rc" >"$tmp" && cat "$tmp" >"$rc"
rm -f -- "$tmp"
if [ -s "$rc" ] && [ -n "$(tail -c 1 "$rc")" ]; then
  echo >>"$rc"
fi
cat >>"$rc" <<'EOF'
# >>> Steam Machine commands >>>
alias fix='~/install-xone.sh'
stick_dev() { readlink -f /dev/disk/by-label/SHARE; }
stick_mount() {
  local dev target
  dev=$(stick_dev) && [ -b "$dev" ] || return 1
  target=$(lsblk -no MOUNTPOINT "$dev")
  if [ -z "$target" ]; then
    udisksctl mount -b "$dev" >/dev/null || return 1
    target=$(lsblk -no MOUNTPOINT "$dev")
  fi
  [ -n "$target" ] && echo "$target"
}
mount() {
  if [ $# -gt 0 ]; then
    command mount "$@"
    return
  fi
  local target
  if ! target=$(stick_mount); then
    echo "No stick named SHARE is plugged in."
    return 1
  fi
  echo "The stick is at $target. Enter one of its commands:"
  ls "$target/commands" | sed -nE 's/\.(sh|py)$//p' | sort -u | tr '\n' ' '
  echo
}
# Bash calls this for a command it cannot find: run the stick's script of that
# name, and unmount the stick afterwards when it was not mounted before.
command_not_found_handle() {
  local dev was target script status
  if dev=$(stick_dev) && [ -b "$dev" ]; then
    was=$(lsblk -no MOUNTPOINT "$dev")
    target=$(stick_mount 2>/dev/null)
    for script in "$target/commands/$1.sh" "$target/commands/$1.py"; do
      [ -n "$target" ] && [ -f "$script" ] || continue
      shift
      case $script in
        *.py) python3 "$script" "$@" ;;
        *) bash "$script" "$@" ;;
      esac
      status=$?
      [ -n "$was" ] || udisksctl unmount -b "$dev" >/dev/null 2>&1
      return "$status"
    done
    [ -n "$was" ] || udisksctl unmount -b "$dev" >/dev/null 2>&1
  fi
  echo "bash: $1: command not found" >&2
  return 127
}
if [[ $- == *i* ]]; then
  if ! modinfo xone_dongle >/dev/null 2>&1; then
    echo "The Xbox controller driver is missing, as after a SteamOS update."
  fi
  echo "To fix Xbox controllers, enter fix"
  echo "To list the commands on the SHARE stick, enter mount"
fi
# <<< Steam Machine commands <<<
EOF

# Steam reads shortcuts.vdf after it starts, so a unit of the user's systemd,
# which starts before Steam, can add an entry back in time.
units="$HOME/.config/systemd/user"
mkdir -p "$units/default.target.wants" || exit 1
cat >"$units/steambox-library.service" <<'EOF'
[Unit]
Description=Change the Steam library entries that Fix Xbox controllers found
ConditionPathExists=%h/.local/share/steambox/restore-on-boot

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 %h/.local/share/steambox/library.py --boot

[Install]
WantedBy=default.target
EOF
ln -sf ../steambox-library.service \
  "$units/default.target.wants/steambox-library.service" || exit 1

cat >"$units/steambox-padlog.service" <<'EOF'
[Unit]
Description=Note when Xbox pads drop off the Xbox Wireless Adapter

[Service]
ExecStart=/usr/bin/python3 %h/.local/share/steambox/padlog.py watch
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
ln -sf ../steambox-padlog.service \
  "$units/default.target.wants/steambox-padlog.service" || exit 1
systemctl --user daemon-reload 2>/dev/null
# A restart, so the logger runs the padlog.py just copied.
systemctl --user restart steambox-padlog.service 2>/dev/null

mkdir -p "$HOME/.config/autostart" || exit 1
cat >"$HOME/.config/autostart/org.kde.konsole.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Konsole
Exec=konsole
Icon=utilities-terminal
OnlyShowIn=KDE;
EOF

if $update; then
  echo "Updated the Steam Machine's scripts from the stick."
  exit 0
fi

python3 "$lib/library.py"
echo
echo "Done. Fix Xbox controllers in the library also checks the Xbox adapter,"
echo "and with the stick plugged in it takes the newest scripts from it and"
echo "runs what its run folder holds. In every new terminal:"
echo "  fix    puts the Xbox controller driver back after a SteamOS update."
echo "  mount  mounts the SHARE stick and lists the commands on it."
echo "  A stick command, such as xone-debug, runs when you enter its name and"
echo "  mounts the stick first when needed."
echo "Open a new Konsole tab with Ctrl+Shift+T to use them."
