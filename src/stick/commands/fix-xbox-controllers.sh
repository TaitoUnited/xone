#!/usr/bin/env bash
# Fix Xbox controllers in the Steam library starts this in Konsole. It needs
# no keyboard: when it asks for the deck password, Steam's on-screen keyboard
# opens for the pad.
# 1. With the SHARE stick plugged in, it updates the scripts from the stick's
#    commands/ folder and runs each .sh or .py file in the stick's run/ folder
#    once, moving it to run/done/ with its output.
# 2. padlog.py reports on the Xbox pads that dropped in the last 7 days.
# 3. library.py checks the library entry. When it is missing or hidden, it
#    comes back by a restart.
# 4. It puts xone back after a SteamOS update, which ends in a restart.
# 5. xone-debug.sh checks the adapter and has it plugged back in.
# setup.sh copies this to ~/fix-xbox-controllers.sh.

# The trap keeps the window open when Ctrl+C stops a restart countdown.
trap : INT
unset LD_PRELOAD LD_LIBRARY_PATH
cd "$HOME" || exit 1
lib="$HOME/.local/share/steambox"
stamp=$(date +%Y%m%d-%H%M%S)

dev=$(readlink -f /dev/disk/by-label/SHARE 2>/dev/null)
stick=""
if [ -b "$dev" ]; then
  stick=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
  if [ -z "$stick" ] && udisksctl mount -b "$dev" >/dev/null 2>&1; then
    stick=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
    export STEAMBOX_UNMOUNT=1
  fi
fi

# Steam counts Fix as running until every process started from it has ended,
# such as a job's keyboard request, so those end here. Only when this program
# leads its own process group, as Konsole starts it, never a shell's.
end_leftovers() {
  local p
  [ "$(ps -o pgid= -p $$ | tr -d ' ')" = "$$" ] || return 0
  for p in $(pgrep -g $$); do
    [ "$p" = "$$" ] || kill "$p" 2>/dev/null
  done
}

# fix-end.sh, as a user unit outside what Steam tracks, ends what is left
# under Steam's reaper once this program has ended, such as the podman pause
# process that Konsole's container check starts.
end_after_exit() {
  local reaper
  [ -f "$lib/fix-end.sh" ] || return 0
  reaper=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
  case $(ps -o args= -p "$reaper" 2>/dev/null) in
    *"reaper SteamLaunch"*) ;;
    *) return 0 ;;
  esac
  systemd-run --user --quiet --collect bash "$lib/fix-end.sh" "$$" "$reaper" \
    >/dev/null 2>&1
}

# $1 is how many seconds the window stays open.
finish() {
  end_leftovers
  if [ -n "${STEAMBOX_UNMOUNT:-}" ]; then
    sync
    udisksctl unmount -b "$dev" >/dev/null 2>&1
  fi
  echo
  if [ "$1" -ge 60 ]; then
    echo "This window closes by itself in $(($1 / 60)) minutes, or when you quit it in Steam."
  else
    echo "This window closes by itself in $1 seconds."
  fi
  sleep "$1"
  end_after_exit
  exit 0
}

restart() {
  sync
  echo "Restarting the Steam Machine in 30 seconds."
  sleep 30
  systemctl reboot && exec sleep 60
  echo "The restart did not start. Restart the Steam Machine yourself."
  finish 600
}

if [ -n "$stick" ] && [ "${1:-}" != --updated ] &&
  [ -f "$stick/commands/setup.sh" ]; then
  echo "Updating the scripts from the stick..."
  before=$(cksum <"$0")
  if bash "$stick/commands/setup.sh" --update; then
    # setup.sh replaced this file; carry on with the new one.
    [ "$(cksum <"$0")" = "$before" ] || exec bash "$0" --updated
  else
    echo "The update from the stick failed, see above."
  fi
  echo
fi

if [ -n "$stick" ] && [ -d "$stick/run" ]; then
  for job in "$stick"/run/*; do
    name=${job##*/}
    case $name in
      ._*) continue ;;
      *.sh | *.py) [ -f "$job" ] || continue ;;
      *) continue ;;
    esac
    mkdir -p "$stick/run/done" || break
    # Moved before it runs, so a job that restarts the machine runs once.
    done_job="$stick/run/done/$stamp-$name"
    mv -f -- "$job" "$done_job" || continue
    echo "Running $name from the stick..."
    case $name in
      *.py) python3 "$done_job" ;;
      *) bash "$done_job" ;;
    esac 2>&1 | tee "$done_job.log"
    echo "$name ended with exit status ${PIPESTATUS[0]}." | tee -a "$done_job.log"
    sync
    echo
  done
fi

if [ -f "$lib/padlog.py" ]; then
  python3 "$lib/padlog.py" report
  echo
fi

python3 "$lib/library.py" --fix
library=$?
echo

sync
"$HOME/install-xone.sh" || finish 600
echo

if [ $library -eq 3 ]; then
  echo "The library entries change as the Steam Machine starts."
  restart
fi

if [ -f "$lib/xone-debug.sh" ]; then
  bash "$lib/xone-debug.sh" && finish 5
  finish 600
fi
finish 5
