#!/usr/bin/env bash
# Brings the Xbox Wireless Adapter back when it stops answering on USB as the
# Steam Machine wakes from sleep, by switching its USB port off for 5 seconds.
# The power goes off, as when unplugging it, only on hubs that support power
# switching (port<X>/disable in the kernel's
# Documentation/ABI/testing/sysfs-bus-usb). The Steam Machine's own ports do
# not (lsusb, 2026-11-16), so there it only reconnects the adapter.
# xbox-adapter-wake.service runs this as root after each wake. With --now it
# cuts the power at once, as a test, for 5 seconds or the seconds given after
# it. install-xone.sh puts it in /etc/steambox.

now=false off=5
if [ "${1:-}" = --now ]; then
  now=true
  off=${2:-5}
fi
case $off in
  '' | *[!0-9]*)
    echo "Stopped: give the seconds as a number, as in --now 15."
    exit 1
    ;;
esac
if [ "$(id -u)" -ne 0 ]; then
  echo "Stopped: run this as root, as with sudo."
  exit 1
fi

plug_re='idVendor=045e, idProduct=(02e6|02fe|02f9|091e)'
# What xone logs when it cannot start the adapter. It logs other errors as
# the port goes off, which say nothing about the start.
fail_re='xone.*: (request firmware|load firmware|init radio|enable pairing) failed'
usb=/sys/bus/usb/devices

is_adapter() {
  [ "$(cat "$1/idVendor" 2>/dev/null)" = 045e ] &&
    case $(cat "$1/idProduct" 2>/dev/null) in
      02e6 | 02fe | 02f9 | 091e) true ;;
      *) false ;;
    esac
}
find_adapter() {
  local d
  for d in "$usb"/*; do
    is_adapter "$d" && echo "$d" && return 0
  done
  return 1
}
bound() {
  local link
  link=$(readlink -f "$1/${1##*/}:1.0/driver" 2>/dev/null)
  [ "${link##*/}" = xone-dongle ]
}
pairing() { cat "$1/${1##*/}:1.0/pairing" 2>/dev/null; }
kernel_since() { journalctl -k -q --no-pager -o cat --since "$1" 2>/dev/null; }
# The device on a port folder such as usb1-port2 (1-2) or 1-2-port3 (1-2.3).
child_of() {
  local hub=${1%-port*} n=${1##*-port}
  case $hub in
    usb*) echo "${hub#usb}-$n" ;;
    *) echo "$hub.$n" ;;
  esac
}

adapter=$(find_adapter)
port=${adapter##*/}
if [ -z "$port" ]; then
  port=$(journalctl -k -b -q --no-pager -o cat 2>/dev/null | grep -E "$plug_re" |
    tail -n 1 | grep -oE '^usb [0-9]+-[0-9.]+' | cut -d' ' -f2)
fi
if [ -z "$port" ]; then
  echo "The adapter has not been on USB since the Steam Machine started."
  exit 0
fi
bus=${port%%-*} rest=${port#*-}
case $rest in
  *.*) name="$bus-${rest%.*}-port${rest##*.}" ;;
  *) name="usb$bus-port$rest" ;;
esac
dir=""
for d in "$usb"/*/"$name"; do
  [ -e "$d/disable" ] && dir=$d && break
done
if [ -z "$dir" ]; then
  echo "Port $port has no disable file, so its power cannot be cut."
  exit 1
fi

if ! $now; then
  # The kernel logs what happened during sleep with the time of the wake.
  since=$(date -d '-2 minutes' '+%Y-%m-%d %H:%M:%S')
  why="" fine=0
  for _ in $(seq 120); do
    log=$(kernel_since "$since")
    if grep -qE "usb ($name|$port): .*unable to enumerate" <<<"$log"; then
      why="the kernel could not enumerate it on port $port"
      break
    fi
    if grep -qE "$fail_re" <<<"$log"; then
      why="xone failed to start it"
      break
    fi
    adapter=$(find_adapter)
    if [ -n "$adapter" ] && bound "$adapter"; then
      fine=$((fine + 1))
    else
      fine=0
    fi
    if [ $fine -ge 20 ]; then
      echo "The adapter answers on USB port ${adapter##*/} after the wake."
      exit 0
    fi
    sleep 1
  done
  echo "The adapter stopped working as the Steam Machine woke:" \
    "${why:-it was not back on USB 2 minutes later}."
fi

# The same connector has a USB 3 twin port; both lose power together.
peer=$(readlink -f "$dir/peer" 2>/dev/null)
for p in "$dir" ${peer:+"$peer"}; do
  dev="$usb/$(child_of "${p##*/}")"
  if [ -e "$dev/idVendor" ] && ! is_adapter "$dev"; then
    echo "Left port $port alone: $(cat "$dev/product" 2>/dev/null) is on it now."
    exit 1
  fi
done

restore() {
  echo 0 >"$dir/disable"
  [ -n "$peer" ] && echo 0 >"$peer/disable"
}
trap restore EXIT
cut_at=$(date '+%Y-%m-%d %H:%M:%S')
echo "Switching USB port $port off for $off seconds..."
[ -n "$peer" ] && echo 1 >"$peer/disable"
if ! echo 1 >"$dir/disable"; then
  echo "The kernel refused to switch port $port off."
  exit 1
fi
sleep "$off"
restore
trap - EXIT

for i in $(seq 30); do
  adapter=$(find_adapter)
  if [ -n "$adapter" ] && bound "$adapter"; then
    echo "The adapter is back on USB port ${adapter##*/} after $i seconds."
    break
  fi
  sleep 1
done
if [ -z "$adapter" ] || ! bound "$adapter"; then
  echo "The adapter did not come back in 30 seconds."
  exit 1
fi
# xone starts pairing, and the light blinks, once the adapter runs.
for _ in $(seq 25); do
  if [ "$(pairing "$adapter")" = 1 ]; then
    echo "xone started the adapter, so its light blinks."
    exit 0
  fi
  if kernel_since "$cut_at" | grep -qE "$fail_re"; then
    echo "xone could not start the adapter; it may have kept power."
    exit 1
  fi
  sleep 1
done
echo "xone did not start pairing in 25 seconds."
exit 1
