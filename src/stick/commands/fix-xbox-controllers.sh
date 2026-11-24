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
# After each step, and when the stick goes in while the window waits, the
# week's logs and reports and this window's text go to steambox-info/ on the
# stick.
# setup.sh copies this to ~/fix-xbox-controllers.sh.

# A quit in Steam sends SIGINT. The trap keeps the window open when Ctrl+C
# stops a restart countdown, and ends the closing wait.
quit=""
trap 'quit=1' INT
unset LD_PRELOAD LD_LIBRARY_PATH
cd "$HOME" || exit 1
lib="$HOME/.local/share/steambox"
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$lib"

# This window's text, kept across the restart into the updated copy. tee
# ignores SIGINT so that a quit in Steam cannot cut the window off.
if [ -z "${STEAMBOX_FIX_LOG:-}" ]; then
  export STEAMBOX_FIX_LOG="$lib/fix-$stamp.log"
  export PYTHONUNBUFFERED=1
  exec > >(trap '' INT; exec tee -a "$STEAMBOX_FIX_LOG") 2>&1
  export STEAMBOX_TEE=$!
fi
find "$lib" -maxdepth 1 -name 'fix-*.log' -mtime +30 -delete 2>/dev/null

dev=$(readlink -f /dev/disk/by-label/SHARE 2>/dev/null)
stick=""
if [ -b "$dev" ]; then
  stick=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
  if [ -z "$stick" ] && udisksctl mount -b "$dev" >/dev/null 2>&1; then
    stick=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
    export STEAMBOX_UNMOUNT=1
  fi
fi

# Copies the logs and reports of the last 7 days that the stick lacks, or
# holds an older copy of, to steambox-info/ on it, with the kernel log of the
# last day. A stick nothing had mounted is mounted for the copy only.
logs_to_stick() {
  local d target was f dest n=0
  d=$(readlink -f /dev/disk/by-label/SHARE 2>/dev/null)
  [ -b "$d" ] || return 1
  was=$(lsblk -no MOUNTPOINT "$d" 2>/dev/null)
  target=$was
  if [ -z "$target" ] && udisksctl mount -b "$d" >/dev/null 2>&1; then
    target=$(lsblk -no MOUNTPOINT "$d" 2>/dev/null)
  fi
  [ -n "$target" ] || return 1
  if mkdir -p "$target/steambox-info/padlog"; then
    while IFS= read -r f; do
      dest="$target/steambox-info/${f#"$lib"/}"
      [ -f "$dest" ] && [ "$(stat -c %s "$f")" = "$(stat -c %s "$dest")" ] &&
        continue
      cp -- "$f" "$dest" && n=$((n + 1))
    done < <(
      find "$lib" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.log' \) \
        -mtime -7 2>/dev/null
      find "$lib/padlog" -maxdepth 1 -type f -name 'events-*.log' -mtime -7 \
        2>/dev/null
    )
    journalctl -k -q --no-pager -o short-precise --since '24 hours ago' \
      >"$target/steambox-info/kernel-$stamp.log" 2>/dev/null
    sync
    echo "Copied $n logs and the kernel log to the stick at $(date +%T)."
  fi
  if [ -z "$was" ]; then
    udisksctl unmount -b "$d" >/dev/null 2>&1
    echo "The stick can come out now."
  fi
  return 0
}

# Steam counts Fix as running until every process started from it has ended,
# such as a job's keyboard request, so those end here. Only when this program
# leads its own process group, as Konsole starts it, never a shell's.
end_leftovers() {
  local p
  [ "$(ps -o pgid= -p $$ | tr -d ' ')" = "$$" ] || return 0
  for p in $(pgrep -g $$); do
    [ "$p" = "$$" ] || [ "$p" = "${STEAMBOX_TEE:-}" ] || kill "$p" 2>/dev/null
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
  local end plugged
  end_leftovers
  echo
  logs_to_stick | grep -v 'can come out'
  if [ -n "${STEAMBOX_UNMOUNT:-}" ]; then
    sync
    udisksctl unmount -b "$dev" >/dev/null 2>&1
  fi
  [ -e /dev/disk/by-label/SHARE ] && echo "The stick can come out now."
  if [ "$1" -ge 60 ]; then
    echo "This window closes by itself in $(($1 / 60)) minutes, or when you quit it in Steam."
    [ -e /dev/disk/by-label/SHARE ] ||
      echo "Plug in the stick meanwhile and the logs go on it."
  else
    echo "This window closes by itself in $1 seconds."
  fi
  end=$((SECONDS + $1))
  plugged=$([ -e /dev/disk/by-label/SHARE ] && echo 1)
  while [ -z "$quit" ] && [ $SECONDS -lt $end ]; do
    sleep 1
    if [ -e /dev/disk/by-label/SHARE ]; then
      if [ -z "$plugged" ]; then
        # udisks may still be busy with the stick that just went in.
        sleep 2
        logs_to_stick && plugged=1
      fi
    else
      plugged=""
    fi
  done
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
logs_to_stick >/dev/null

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
logs_to_stick >/dev/null
"$HOME/install-xone.sh" || finish 600
echo

if [ $library -eq 3 ]; then
  logs_to_stick >/dev/null
  echo "The library entries change as the Steam Machine starts."
  restart
fi

if [ -f "$lib/xone-debug.sh" ]; then
  bash "$lib/xone-debug.sh" && finish 5
  finish 600
fi
finish 5
