#!/usr/bin/env bash
# Fix Xbox controllers starts this as a user unit as it ends, outside the
# processes Steam tracks for it. Steam counts Fix as running while anything
# under its reaper runs. Konsole runs distrobox list as it starts, which leaves
# podman's pause process, catatonit -P, there. So once Fix has ended this notes
# in fix-end.log what is still there, ends it, and copies the log to the SHARE
# stick when it is plugged in. $1 is Fix's process, $2 Steam's reaper.
fix=$1 reaper=$2
log="$HOME/.local/share/steambox/fix-end.log"

under() {
  local c
  for c in $(pgrep -P "$1"); do
    echo "$c"
    under "$c"
  done
}

for _ in $(seq 30); do
  kill -0 "$fix" 2>/dev/null || break
  sleep 1
done
sleep 5
left=$(under "$reaper")
{
  echo "$(date '+%F %T') Fix Xbox controllers ended (process $fix, Steam's reaper $reaper)."
  if [ -n "$left" ]; then
    echo "Still running 5 s later, so ended here:"
    ps -o pid=,ppid=,pgid=,etime=,stat=,args= -p "$(echo $left | tr ' ' ,)" | cut -c1-200
    kill $left 2>/dev/null
    sleep 3
    left=$(under "$reaper")
    if [ -n "$left" ]; then
      echo "Still there after SIGTERM, so killed:"
      ps -o pid=,args= -p "$(echo $left | tr ' ' ,)" | cut -c1-200
      kill -9 $left 2>/dev/null
    fi
  elif kill -0 "$reaper" 2>/dev/null; then
    echo "Steam's reaper still runs, with nothing under it."
  else
    echo "Nothing was left: it ended by itself."
  fi
} >>"$log" 2>&1

dev=$(readlink -f /dev/disk/by-label/SHARE 2>/dev/null)
[ -b "$dev" ] || exit 0
was=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
target=$was
if [ -z "$target" ] && udisksctl mount -b "$dev" >/dev/null 2>&1; then
  target=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
fi
[ -n "$target" ] && mkdir -p "$target/steambox-info" &&
  cp "$log" "$target/steambox-info/fix-end.log"
sync
[ -z "$was" ] && udisksctl unmount -b "$dev" >/dev/null 2>&1
exit 0
