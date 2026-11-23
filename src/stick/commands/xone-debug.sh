#!/usr/bin/env bash
# Find out why the Xbox Wireless Adapter does not work, as when its light
# stays off. Reads only and changes nothing. It checks xone, the firmware and
# the adapter on USB. Unless a pad is connected, it then asks for the adapter
# to be plugged back in and watches xone start it and a pad connect. It needs
# no keyboard. Fix Xbox controllers in the Steam library runs it last.
# The report goes to ~/.local/share/steambox and, when the SHARE stick is
# plugged in, to steambox-info/ on it for Claude Code on another computer.
# Exits with 0 when a pad is connected or nothing is wrong, else with 1.

# Steam's own library paths can break system tools started from the library.
if [ -n "${LD_PRELOAD:-}${LD_LIBRARY_PATH:-}" ]; then
  exec env -u LD_PRELOAD -u LD_LIBRARY_PATH bash "$0" "$@"
fi

from_steam=false
[ "${1:-}" = --from-steam ] && from_steam=true

stamp=$(date +%Y%m%d-%H%M%S)
state="$HOME/.local/share/steambox"
mkdir -p "$state" || exit 1
report="$state/xone-debug-$stamp.txt"
watch="$state/xone-debug-$stamp.kernel"
exec 3>"$report"

out() { printf '%s\n' "$*"; printf '%s\n' "$*" >&3; }
ok() { out "[ok] $*"; }
bad() { out "[!!] $*"; }
more() { out "     $*"; }
# Kernel log lines, shortened and without the date and host.
short() {
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && out "     $(cut -c1-120 <<<"${l#* kernel: }")"
  done <<<"$1"
}
run() { printf '\n$ %s\n' "$*" >&3; "$@" >&3 2>&1; }
todo=()
step() { todo+=("$*"); }

plug_re='idVendor=045e, idProduct=(02e6|02fe|02f9|091e)'
fail_re='xone.*(failed|error|timed out)|Direct firmware load for xone'
benign_re='module verification failed'
link_re='over-current|device descriptor read|unable to enumerate'
link_re="$link_re|device not accepting address|cannot reset|Cannot enable"

find_adapter() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] || continue
    [ "$(<"$d/idVendor")" = 045e ] || continue
    case $(<"$d/idProduct") in
      02e6 | 02fe | 02f9 | 091e) echo "$d" && return 0 ;;
    esac
  done
  return 1
}
iface() { echo "$1/${1##*/}:1.0"; }
driver_of() {
  local link
  link=$(readlink -f "$(iface "$1")/driver" 2>/dev/null) && echo "${link##*/}"
}
devnum_of() { cat "$1/devnum" 2>/dev/null; }
pairing_of() { cat "$(iface "$1")/pairing" 2>/dev/null; }
clients_of() {
  sed -n 's/^Active clients: //p' "$(iface "$1")/active_clients" 2>/dev/null
}
errno_of() { grep -oE -- '-[0-9]+' <<<"$1" | tail -n 1; }
meaning() {
  case $1 in
    -71) echo "a USB transfer error" ;;
    -110) echo "the adapter did not answer in time" ;;
    -19) echo "the adapter went away" ;;
    -2) echo "a firmware file is missing" ;;
    -32) echo "the adapter refused a USB command" ;;
    -5) echo "an input or output error" ;;
    *) echo "error ${1:-without a number}" ;;
  esac
}
secs() { date -d "$(awk '{print $1, $2, $3}' <<<"$1")" +%s 2>/dev/null; }

out "Xbox adapter check, $(date '+%Y-%m-%d %H:%M')"
out ""

# --- SteamOS and the kernel
kernel=$(uname -r)
os=$(. /etc/os-release 2>/dev/null && echo "$NAME $VERSION_ID, build $BUILD_ID")
ok "$os, kernel $kernel, up since $(uptime -s 2>/dev/null)"
run cat /etc/os-release
run journalctl --list-boots --no-pager -q

# --- xone and its firmware
installed=true
if modinfo xone_dongle >/dev/null 2>&1; then
  ok "xone $(modinfo -F version xone_dongle 2>/dev/null) is installed for this kernel."
else
  installed=false
  bad "xone is not installed for this kernel, as after a SteamOS update."
  others=$(ls -d /usr/lib/modules/*/updates/dkms/xone_dongle.ko* 2>/dev/null |
    cut -d/ -f5 | sort -u | tr '\n' ' ')
  [ -n "$others" ] && more "It is built for another kernel: $others"
  step "Start Fix Xbox controllers in the library. It installs xone again" \
    "and restarts the Steam Machine."
fi
run modinfo xone_dongle
run modinfo xpad_noone
run pacman -Q xone-dkms xone-dongle-firmware xpad-noone-git
run dkms status
run grep -rs . /etc/modprobe.d /usr/lib/modprobe.d
run ls -la /usr/lib/firmware/xone_dongle_*

override=$(grep -shoE 'fw_override=0x[0-9a-fA-F]+' /etc/modprobe.d/*.conf |
  head -n 1 | sed 's/.*=0x//' | tr 'A-F' 'a-f')
[ -n "$override" ] &&
  more "The older $override firmware is switched on (old-firmware)."

# --- The adapter on USB
adapter=$(find_adapter)
pid="" port="" driver=""
if [ -n "$adapter" ]; then
  pid=$(<"$adapter/idProduct")
  port=${adapter##*/}
  driver=$(driver_of "$adapter")
  ok "The adapter (045e:$pid) is on USB port $port, $(<"$adapter/speed") Mbit/s."
  if [ "$driver" = xone-dongle ]; then
    ok "xone drives it."
  elif [ -n "$driver" ]; then
    bad "The driver $driver holds it instead of xone."
  elif $installed; then
    bad "No driver holds it."
  fi
  for f in idProduct product manufacturer speed bMaxPower devnum \
    power/control power/runtime_status; do
    printf '%s: %s\n' "$f" "$(cat "$adapter/$f" 2>/dev/null)" >&3
  done
fi
run lsusb
run lsusb -t

fw=${override:-$pid}
if $installed && [ -n "$fw" ]; then
  if ls /usr/lib/firmware/xone_dongle_"$fw".bin* >/dev/null 2>&1; then
    ok "The firmware file xone_dongle_$fw.bin is there."
  else
    bad "The firmware file xone_dongle_$fw.bin is missing."
    step "Start Fix Xbox controllers in the library to put the firmware back."
  fi
fi

# --- The kernel log since the adapter last came up
klog_ok=true
klog=$(journalctl -k -b --no-pager -q -o short 2>&1)
if [ -z "$klog" ] || grep -q 'insufficient permissions' <<<"$klog"; then
  klog_ok=false
  bad "The kernel log cannot be read as $(id -un), so errors stay unseen."
fi
from=$(grep -nE "$plug_re" <<<"$klog" | tail -n 1 | cut -d: -f1)
since=$(tail -n +"${from:-1}" <<<"$klog")
errors=$(grep -E "xone|$plug_re" <<<"$since" | grep -vE "$benign_re" |
  grep -E "$fail_re")
# The port where it last came up, also when it is gone now.
seen_port=${port:-$(grep -E "$plug_re" <<<"$klog" | tail -n 1 |
  grep -oE 'usb [0-9]+-[0-9.]+' | cut -d' ' -f2)}
link=""
if [ -n "$seen_port" ]; then
  hub_port="usb${seen_port%%-*}-port${seen_port#*-}"
  link=$(grep -E "usb $seen_port: .*($link_re)|usb $hub_port: " <<<"$since" |
    grep -E "$link_re")
fi
printf '\n--- kernel lines on xone, USB and sleep since it last came up\n' >&3
grep -E "xone|usb [0-9]|usb usb|PM: suspend|$plug_re|$link_re" <<<"$since" |
  tail -n 150 >&3
printf '\n--- xone lines of the boot before\n' >&3
journalctl -k -b -1 --no-pager -q 2>&1 | grep -E "xone|$plug_re" |
  tail -n 40 >&3

if [ -n "$errors" ]; then
  last=$(tail -n 1 <<<"$errors")
  code=$(errno_of "$last")
  bad "When the adapter last came up ($(awk '{print $3}' <<<"$last")), xone failed to start it:"
  more "$(meaning "$code"). That leaves its light off."
  short "$last"
elif [ -n "$adapter" ] && [ "$driver" = xone-dongle ]; then
  ok "No xone errors since the adapter last came up."
fi

woke=false
if [ -n "$link" ]; then
  first=$(head -n 1 <<<"$link")
  at=$(secs "$first")
  # The kernel logs what happened during sleep as the machine wakes.
  while read -r l; do
    t=$(secs "$l")
    [ -n "$at" ] && [ -n "$t" ] && [ $((at - t)) -le 60 ] &&
      [ $((t - at)) -le 60 ] && woke=true
  done < <(grep -E 'PM: suspend (exit|entry)' <<<"$klog")
  if [ -z "$adapter" ]; then
    bad "The adapter stopped answering on USB port $seen_port at $(awk '{print $3}' <<<"$first")."
  else
    bad "USB errors on port $seen_port since $(awk '{print $3}' <<<"$first"):"
  fi
  $woke && more "That was as the Steam Machine woke from sleep."
  short "$(tail -n 2 <<<"$link")"
elif [ -z "$adapter" ]; then
  bad "The Steam Machine does not see the adapter on USB."
fi

# --- Pairing and pads, which set the light: xone makes it blink while it
# pairs, keeps it on while a pad is connected and turns it off otherwise.
pairing="" clients=""
if [ "$driver" = xone-dongle ]; then
  pairing=$(pairing_of "$adapter")
  clients=$(clients_of "$adapter")
  run cat "$(iface "$adapter")/active_clients"
  if [ "${clients:-0}" -gt 0 ] 2>/dev/null; then
    ok "$clients pad(s) connected, so the light is on."
  elif [ "$pairing" = 1 ]; then
    ok "The adapter is pairing, so its light blinks."
  elif [ -n "$pairing" ] && [ -z "$errors" ]; then
    more "No pad is connected and the adapter is not pairing. xone turns"
    more "the light off then, 60 seconds after the adapter came up."
  fi
fi

# --- What the services that install-xone.sh installs did since the start
for svc in xone-after-update xbox-adapter-wake; do
  systemctl is-enabled --quiet "$svc.service" 2>/dev/null || continue
  svc_log=$(journalctl -u "$svc.service" -b -q --no-pager -o short \
    2>/dev/null | grep -v 'systemd\[1\]')
  printf '\n--- %s since the Steam Machine started\n%s\n' "$svc" "$svc_log" >&3
  if [ -n "$svc_log" ]; then
    last=$(tail -n 1 <<<"$svc_log")
    more "$svc at $(awk '{print $3}' <<<"$last"): ${last#*]: }"
  else
    more "$svc has not run since the Steam Machine started."
  fi
done

# --- The test: plug the adapter back in and watch xone start it.
shown=0
show_new() {
  local total
  total=$(wc -l <"$watch")
  [ "$total" -gt "$shown" ] || return 0
  short "$(sed -n "$((shown + 1)),${total}p" "$watch" |
    grep -E "xone|$plug_re|$link_re|USB disconnect" | grep -vE "$benign_re")"
  shown=$total
}

replug_test() {
  local now before paired_before end gone=false button=false
  out ""
  if [ -n "$adapter" ]; then
    out "TEST: unplug the adapter now, wait 5 seconds, and plug it back in."
  else
    out "TEST: unplug the adapter if it is plugged in, wait 5 seconds, and"
    out "plug it back in."
  fi
  out "Watching for 2 minutes..."
  if $klog_ok; then
    journalctl -k -f -n 0 --no-pager -q -o short >"$watch" 2>&1 &
    jpid=$!
  fi
  : >>"$watch"
  before="${adapter:+${adapter##*/} $(devnum_of "$adapter")}"
  paired_before=$(pairing_of "$adapter")
  [ -z "$adapter" ] && gone=true
  end=$((SECONDS + 120))
  while [ $SECONDS -lt $end ]; do
    sleep 0.5
    show_new
    now=$(find_adapter)
    if [ -z "$now" ]; then
      $gone || out "     The adapter is unplugged."
      gone=true
    elif $gone || [ "${now##*/} $(devnum_of "$now")" != "$before" ]; then
      plugged=$now
      break
    elif [ "$paired_before" = 0 ] && [ "$(pairing_of "$now")" = 1 ]; then
      # Its pair button was pressed instead, which also shows xone works.
      plugged=$now button=true
      break
    fi
  done

  if [ -z "$plugged" ]; then
    if ! $gone; then
      result=noreplug
      more "The adapter was not plugged back in."
    elif grep -qE "usb [0-9]+-[0-9.]+: new .*USB device" "$watch"; then
      result=absent_tried
      bad "The adapter was plugged in, but it did not answer on USB."
    else
      result=absent
      bad "The adapter did not show up on USB."
    fi
    return
  fi
  if $button; then
    out "     The adapter's pair button started pairing."
    result=pairing
    return
  fi
  out "     The adapter is back on port ${plugged##*/}. Waiting for xone..."
  end=$((SECONDS + 25))
  while [ $SECONDS -lt $end ]; do
    sleep 0.5
    show_new
    [ "$(pairing_of "$plugged")" = 1 ] && result=pairing && break
    grep -E "$fail_re" "$watch" | grep -qvE "$benign_re" &&
      result=failed && break
  done
  sleep 1
  show_new
  case $result in
    pairing) ;;
    failed)
      code=$(errno_of "$(grep -E "$fail_re" "$watch" | grep -vE "$benign_re" |
        tail -n 1)")
      bad "xone failed to start the adapter again: $(meaning "$code")."
      ;;
    *)
      if [ "$(driver_of "$plugged")" = xone-dongle ]; then
        result=quiet
        bad "xone took the adapter without an error, but it did not start"
        more "pairing in 25 seconds, so its light stays off."
      else
        result=silent
        bad "No driver took the adapter."
      fi
      ;;
  esac
}

pad_test() {
  local n end
  ok "xone runs the adapter. Its light blinks for 60 seconds."
  out ""
  out "TEST: turn on a pad now. A pad paired before connects by itself."
  out "A new pad: hold its pair button until its Xbox light blinks fast."
  end=$((SECONDS + 60))
  while [ $SECONDS -lt $end ]; do
    sleep 1
    n=$(clients_of "$plugged")
    [ "${n:-0}" -gt 0 ] 2>/dev/null && result=pad && break
  done
  if [ $result = pad ]; then
    ok "A pad connected. The light stays on while a pad is connected."
  else
    bad "No pad connected in 60 seconds."
  fi
}

result="" plugged=""
if $installed; then
  if [ "${clients:-0}" -gt 0 ] 2>/dev/null; then
    result=pad
  elif [ "$pairing" = 1 ]; then
    result=pairing plugged=$adapter
  else
    replug_test
  fi
  [ "$result" = pairing ] && pad_test
  [ -n "${jpid:-}" ] && kill "$jpid" 2>/dev/null
  if [ -f "$watch" ]; then
    printf '\n--- kernel log during the test (%s)\n' "$result" >&3
    cat "$watch" >&3
    rm -f -- "$watch"
  fi
  [ -n "$plugged" ] && run cat "$(iface "$plugged")/active_clients"
fi

# --- What to do
again="start Fix Xbox controllers again"
other_port="Plug the adapter into another USB port of the Steam Machine,"
other_port="$other_port without a hub or extension cable, and $again."
other_fw="switch the adapter to the older 091e firmware"
[ -n "$override" ] && other_fw="switch the adapter back to its own firmware"
case $result in
  absent)
    step "Unplug the adapter, wait 5 seconds, plug it back in and $again."
    step "If it does not show up then: $other_port"
    ;;
  absent_tried)
    step "$other_port"
    step "If no port shows it, the adapter is broken."
    ;;
  failed)
    step "$other_port"
    step "If it fails in every port, $other_fw: in Desktop Mode, with the" \
      "stick plugged in, enter old-firmware in Konsole. Then $again."
    ;;
  quiet)
    step "Press the pair button on the adapter. If its light does not blink" \
      "then, $again."
    ;;
  pairing)
    step "Pair each pad again: press the pair button on the adapter, then" \
      "hold the pad's pair button until its Xbox light blinks fast."
    ;;
  noreplug)
    if [ -n "$errors" ] || [ "$driver" != xone-dongle ]; then
      step "Start Fix Xbox controllers again and unplug and replug the" \
        "adapter when it asks."
    else
      step "Press the pair button on the adapter: its light blinks while it" \
        "pairs, and a pad turned on then connects."
    fi
    ;;
esac
if [ "$result" = pad ] && $woke; then
  step "When the light is off after the Steam Machine wakes from sleep," \
    "unplug the adapter, wait 5 seconds and plug it back in."
elif [ -n "$errors" ] && { [ "$result" = pad ] || [ "$result" = pairing ]; }; then
  step "When the light stays off after a restart, unplug the adapter, wait" \
    "5 seconds and plug it back in."
fi
case $result in absent_tried | failed | silent)
  step "Bring the SHARE stick to the computer with Claude Code, with this report on it." ;;
esac

out ""
if [ ${#todo[@]} -eq 0 ]; then
  out "Nothing wrong found."
else
  out "What to do:"
  i=1
  for t in "${todo[@]}"; do
    out "$(fold -s -w 72 <<<"$i. $t" | sed -e 's/ *$//' -e '2,$s/^/   /')"
    i=$((i + 1))
  done
fi
status=1
{ [ "$result" = pad ] || [ ${#todo[@]} -eq 0 ]; } && status=0

# --- Save the report to the stick too
exec 3>&-
sync
saved="Saved the report as $report"
dev=$(readlink -f /dev/disk/by-label/SHARE 2>/dev/null)
if [ -b "$dev" ]; then
  was=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
  target=$was
  if [ -z "$target" ] && udisksctl mount -b "$dev" >/dev/null 2>&1; then
    target=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null)
  fi
  if [ -n "$target" ] && mkdir -p "$target/steambox-info" &&
    cp "$report" "$target/steambox-info/"; then
    sync
    saved="Saved the report on the stick too, as steambox-info/${report##*/}"
  fi
  [ -z "$was" ] && udisksctl unmount -b "$dev" >/dev/null 2>&1
fi
echo
echo "$saved"

if $from_steam; then
  echo "This window closes by itself in 10 minutes, or when you quit it in Steam."
  sleep 600
fi
exit "$status"
