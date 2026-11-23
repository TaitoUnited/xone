#!/usr/bin/env bash
# Install the xone driver for the Xbox Wireless Adapter on SteamOS, and
# xpad-noone so Xbox 360 pads keep working once xone turns xpad off.
# Builds the AUR packages as xone's install/steam-deck-install.sh does, but
# skips the system update while the build tools and the headers for the
# running kernel are still installed. A SteamOS update removes all of it.
# With the deck password it also installs what runs without it:
# - xone-after-update.service runs a root copy of this script with --boot at
#   each start, which builds xone again when a SteamOS update removed it;
# - xbox-adapter-wake.service runs adapter-wake.sh after each wake;
# - /etc/atomic-update.conf.d/steambox.conf lists these files, since SteamOS
#   3.6 and later keep only listed changes to /etc through an update.
# xone gets the Steam Machine patch in steambox_patch below. When it no longer
# fits a new xone, or does not build, xone builds without it.
# --no-reboot skips the restart after a build, for a run/ job that restarts
# xone itself.

boot=false user=$USER reboot=true
if [ "${1:-}" = --boot ]; then
  boot=true
  user=${2:-deck}
elif [ "${1:-}" = --no-reboot ]; then
  reboot=false
fi
if $boot && [ "$(id -u)" -ne 0 ]; then
  echo "Stopped: --boot runs as root, from xone-after-update.service."
  exit 1
fi
if ! $boot && [ "$(id -u)" -eq 0 ]; then
  echo "Stopped: run this as your own user, without sudo."
  exit 1
fi
home=$(getent passwd "$user" | cut -d: -f6)
if [ ! -d "$home" ]; then
  echo "Stopped: user $user has no home folder."
  exit 1
fi

home_copy="$home/install-xone.sh"
if ! $boot; then
  self=$(readlink -f "$0")
  if [ "$self" != "$home_copy" ]; then
    cp "$self" "$home_copy" && chmod +x "$home_copy"
    echo "Saved a copy as ~/install-xone.sh for after SteamOS updates."
  fi
fi
root() { if $boot; then "$@"; else sudo "$@"; fi; }
as_user() { if $boot; then runuser -u "$user" -- "$@"; else "$@"; fi; }
# Opens Steam's on-screen keyboard before sudo asks, so a pad can type the
# deck password.
ask_password() {
  if ! sudo -n true 2>/dev/null; then
    echo "Type the deck password on Steam's keyboard, then press its Enter key."
    steam -ifrunning steam://open/keyboard >/dev/null 2>&1 &
  fi
  sudo -v
}

kernel=$(uname -r)
kernel_pkg=$(pacman -Qoq "/usr/lib/modules/$kernel/vmlinuz" 2>/dev/null)
if [ -z "$kernel_pkg" ]; then
  echo "Stopped: no package owns the running kernel $kernel."
  exit 1
fi

missing() { ! pacman -Q "$@" >/dev/null 2>&1; }
no_module() { ! modinfo "$1" >/dev/null 2>&1; }
built() { dkms status 2>/dev/null | grep -q "^$1.*installed"; }

# The Steam Machine patch for xone 0.5.8: the adapter frees slots that xone
# holds no pad in, a pad asking to join from a dead slot gets a new one, the
# channel option, and a debug line for each acknowledged chunk.
steambox_patch() {
  cat <<'PATCH'
diff --git a/bus/protocol.c b/bus/protocol.c
index 9152be5..2300f5c 100644
--- a/bus/protocol.c
+++ b/bus/protocol.c
@@ -455,8 +455,9 @@ static int gip_acknowledge_pkt(struct gip_client *client,
 	if ((ack->options & GIP_OPT_CHUNK) && buf)
 		pkt.remaining = cpu_to_le16(buf->length - len);
 
-	// gip_dbg(client, "%s: ACME(host) command=0x%02x, length=0x%04x\n",
-	// 	__func__, pkt.command, len);
+	if (ack->options & GIP_OPT_CHUNK)
+		gip_dbg(client, "%s: command=0x%02x, length=0x%04x, remaining=0x%04x\n",
+			__func__, pkt.command, len, le16_to_cpu(pkt.remaining));
 
 	return gip_send_pkt(client, &hdr, &pkt);
 }
diff --git a/transport/dongle.c b/transport/dongle.c
index fb5494b..d1a66e1 100644
--- a/transport/dongle.c
+++ b/transport/dongle.c
@@ -32,6 +32,7 @@ module_param_named(fw_override, fw_override_pid, ushort, 0600);
 
 #define XONE_DONGLE_PAIRING_TIMEOUT 60 // seconds
 #define XONE_DONGLE_PAIR_SCAN_INTERVAL msecs_to_jiffies(2000)
+#define XONE_DONGLE_STALE_CLIENT msecs_to_jiffies(1000)
 #define XONE_DONGLE_PWR_OFF_TIMEOUT msecs_to_jiffies(5000)
 #define XONE_DONGLE_FW_REQ_TIMEOUT_MS 3000
 #define XONE_DONGLE_FW_REQ_RETRIES 11 // 30 seconds
@@ -59,6 +60,7 @@ struct xone_dongle_client {
 	u8 wcid;
 	u8 address[ETH_ALEN];
 	bool encryption_enabled;
+	unsigned long last_rx;
 
 	struct gip_adapter *adapter;
 };
@@ -332,7 +334,7 @@ static void xone_dongle_pairing_scan(struct work_struct *work)
 
 	mutex_lock(&dongle->pairing_lock);
 
-	if (!dongle->pairing)
+	if (!dongle->pairing || dongle->mt.channel_fixed)
 		goto out_unlock;
 
 	/*
@@ -499,6 +501,7 @@ xone_dongle_create_client(struct xone_dongle *dongle, u8 *addr)
 
 	client->dongle = dongle;
 	client->wcid = i + 1;
+	client->last_rx = jiffies;
 	memcpy(client->address, addr, ETH_ALEN);
 
 	client->adapter = gip_create_adapter(dongle->mt.dev,
@@ -514,18 +517,34 @@ xone_dongle_create_client(struct xone_dongle *dongle, u8 *addr)
 	return client;
 }
 
+static int xone_dongle_remove_client(struct xone_dongle *dongle, u8 wcid);
+
 static int xone_dongle_add_client(struct xone_dongle *dongle, u8 *addr)
 {
 	struct xone_dongle_client *client;
 	int i, err;
 	unsigned long flags;
 
-	/* reject duplicate: controller already has a WCID slot */
-	for (i = 0; i < XONE_DONGLE_MAX_CLIENTS; i++)
-		if (dongle->clients[i] &&
-		    ether_addr_equal(dongle->clients[i]->address, addr))
+	/*
+	 * A controller that asks to join while it holds a slot has lost its
+	 * connection without a word, unless it sent data within the last
+	 * second. Left alone, its dead slot keeps it from joining again.
+	 */
+	for (i = 0; i < XONE_DONGLE_MAX_CLIENTS; i++) {
+		client = dongle->clients[i];
+		if (!client || !ether_addr_equal(client->address, addr))
+			continue;
+
+		if (time_before(jiffies,
+				client->last_rx + XONE_DONGLE_STALE_CLIENT))
 			return 0;
 
+		dev_dbg(dongle->mt.dev, "%s: replacing stale wcid=%d, address=%pM\n",
+			__func__, client->wcid, addr);
+		xone_dongle_remove_client(dongle, client->wcid);
+		break;
+	}
+
 	client = xone_dongle_create_client(dongle, addr);
 	if (IS_ERR(client))
 		return PTR_ERR(client);
@@ -565,8 +584,12 @@ static int xone_dongle_remove_client(struct xone_dongle *dongle, u8 wcid)
 	unsigned long flags;
 
 	client = dongle->clients[wcid - 1];
-	if (!client)
-		return 0;
+	if (!client) {
+		/* the adapter can keep reporting a slot xone holds no client in */
+		dev_dbg(dongle->mt.dev, "%s: freeing empty wcid=%d\n",
+			__func__, wcid);
+		return xone_mt76_remove_client(&dongle->mt, wcid);
+	}
 
 	dev_dbg(dongle->mt.dev, "%s: wcid=%d, address=%pM\n",
 		__func__, wcid, client->address);
@@ -703,6 +726,7 @@ static int xone_dongle_handle_qos_data(struct xone_dongle *dongle,
 
 	client = dongle->clients[wcid - 1];
 	if (client) {
+		client->last_rx = jiffies;
 		/*
 		 * Active data traffic is the strongest signal that we are on
 		 * the right channel. Refresh last_wlan_rx so the pairing scan
diff --git a/transport/mt76.c b/transport/mt76.c
index ecdbde4..d252857 100644
--- a/transport/mt76.c
+++ b/transport/mt76.c
@@ -73,6 +73,10 @@ static char override_mac[ETH_ALEN] = { 0 };
 module_param_array(override_mac, byte, NULL, 0444);
 MODULE_PARM_DESC(override_mac, "Override MAC address (6 bytes), helps deconflict counterfeit adapters");
 
+static uint fixed_channel;
+module_param_named(channel, fixed_channel, uint, 0444);
+MODULE_PARM_DESC(channel, "Run the adapter on this channel, such as 36, instead of the one with the highest transmit power");
+
 static u32 xone_mt76_read_register(struct xone_mt76 *mt, u32 addr)
 {
 	u8 req = MT_VEND_MULTI_READ;
@@ -662,10 +666,11 @@ static int xone_mt76_get_channel_power(struct xone_mt76 *mt,
 
 static int xone_mt76_evaluate_channels(struct xone_mt76 *mt)
 {
-	struct xone_mt76_channel *chan;
+	struct xone_mt76_channel *chan, *fixed = NULL;
 	int i, err, pow = 0;
 
 	mt->channel = NULL;
+	mt->channel_fixed = false;
 
 	memcpy(mt->channels, xone_mt76_channels, sizeof(xone_mt76_channels));
 
@@ -690,6 +695,19 @@ static int xone_mt76_evaluate_channels(struct xone_mt76 *mt)
 
 		dev_dbg(mt->dev, "%s: channel=%u, power=%u\n", __func__,
 			chan->index, chan->power);
+
+		if (fixed_channel && chan->index == fixed_channel)
+			fixed = chan;
+	}
+
+	if (fixed) {
+		mt->channel = fixed;
+		mt->channel_fixed = true;
+		dev_info(mt->dev, "%s: channel=%u, set by the channel option\n",
+			 __func__, fixed->index);
+	} else if (fixed_channel) {
+		dev_warn(mt->dev, "%s: channel option %u is not one of the adapter's channels\n",
+			 __func__, fixed_channel);
 	}
 
 	if (mt->channel == NULL)
diff --git a/transport/mt76.h b/transport/mt76.h
index 933a64e..cac4a84 100644
--- a/transport/mt76.h
+++ b/transport/mt76.h
@@ -60,6 +60,7 @@ struct xone_mt76 {
 
 	struct xone_mt76_channel channels[XONE_MT_NUM_CHANNELS];
 	struct xone_mt76_channel *channel;
+	bool channel_fixed;
 };
 
 struct sk_buff *xone_mt76_alloc_message(int len, gfp_t gfp);
PATCH
}
patch_id=$(steambox_patch | cksum | cut -d' ' -f1)
xone_version() { pacman -Q xone-dkms 2>/dev/null | awk '{sub(/-[^-]*$/, "", $2); print $2}'; }
# Once a build tried this patch on this xone and kernel, it is not tried again.
patch_mark=/etc/steambox/xone-patch
patch_key() { echo "patch $patch_id, xone $(xone_version), kernel $kernel"; }
patch_tried() { [ "$(cat "$patch_mark" 2>/dev/null)" = "$(patch_key)" ]; }
# The build notes in xone's source whether the patch went in.
patch_result() {
  cat "/usr/src/xone-$(xone_version)/steambox-patch" 2>/dev/null ||
    echo "left out, as the AUR's xone-dkms build changed"
}

# Units as in the ArchWiki's systemd and Power management/Suspend and
# hibernate pages. Type=exec keeps the start from waiting for a build.
lib="$home/.local/share/steambox"
units=/etc/systemd/system
keep=/etc/atomic-update.conf.d/steambox.conf
sleep_targets="suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"
wake_text="[Unit]
Description=Bring the Xbox Wireless Adapter back after sleep
After=$sleep_targets

[Service]
Type=oneshot
ExecStart=/etc/steambox/adapter-wake.sh
TimeoutStartSec=4min

[Install]
WantedBy=$sleep_targets"
boot_text="[Unit]
Description=Build xone again after a SteamOS update

[Service]
Type=exec
ExecStart=/etc/steambox/install-xone.sh --boot $user
Nice=10

[Install]
WantedBy=multi-user.target"
keep_text="$keep
/etc/steambox/**
/etc/modprobe.d/steambox-xone*.conf
$units/xone-after-update.service
$units/multi-user.target.wants/xone-after-update.service
$units/xbox-adapter-wake.service"
for t in $sleep_targets; do
  keep_text+=$'\n'"$units/$t.wants/xbox-adapter-wake.service"
done

sum_of() { cksum 2>/dev/null <"$1" || echo missing; }
text_differs() { [ "$(printf '%s\n' "$1" | cksum)" != "$(sum_of "$2")" ]; }
file_differs() { [ "$(sum_of "$1")" != "$(sum_of "$2")" ]; }
need_units=false
if ! $boot && [ -f "$lib/adapter-wake.sh" ]; then
  if file_differs "$home_copy" /etc/steambox/install-xone.sh ||
    file_differs "$lib/adapter-wake.sh" /etc/steambox/adapter-wake.sh ||
    text_differs "$wake_text" "$units/xbox-adapter-wake.service" ||
    text_differs "$boot_text" "$units/xone-after-update.service" ||
    { [ -d "${keep%/*}" ] && text_differs "$keep_text" "$keep"; } ||
    ! systemctl is-enabled --quiet xbox-adapter-wake.service 2>/dev/null ||
    ! systemctl is-enabled --quiet xone-after-update.service 2>/dev/null; then
    need_units=true
  fi
fi
install_units() {
  root install -D -m 755 -o root -g root "$home_copy" /etc/steambox/install-xone.sh &&
    root install -D -m 755 -o root -g root "$lib/adapter-wake.sh" /etc/steambox/adapter-wake.sh &&
    printf '%s\n' "$wake_text" | root tee "$units/xbox-adapter-wake.service" >/dev/null &&
    printf '%s\n' "$boot_text" | root tee "$units/xone-after-update.service" >/dev/null &&
    { [ ! -d "${keep%/*}" ] || printf '%s\n' "$keep_text" | root tee "$keep" >/dev/null; } &&
    root systemctl daemon-reload &&
    root systemctl enable --quiet xone-after-update.service xbox-adapter-wake.service &&
    echo "Installed what runs without the deck password:" &&
    echo "- after a SteamOS update, the Steam Machine builds xone again by itself;" &&
    echo "- after sleep, it reconnects the adapter if the adapter stopped answering."
}

need_fw=false need_xone=false need_noone=false need_tools=false
missing xone-dongle-firmware && need_fw=true
no_module xone_dongle && need_xone=true
if ! $need_xone && ! patch_tried; then
  echo "xone runs without the Steam Machine patch, so it is built again with it."
  need_xone=true
fi
no_module xpad_noone && need_noone=true
if missing base-devel dkms git linux-api-headers "$kernel_pkg-headers" ||
  [ ! -d "/usr/lib/modules/$kernel/build" ]; then
  need_tools=true
fi
# At start only xone counts: a failed xpad-noone build would repeat each time.
$boot && need_noone=false

if ! $need_fw && ! $need_xone && ! $need_noone; then
  if $boot; then
    echo "xone is installed for kernel $kernel."
    exit 0
  fi
  if $need_units; then
    ask_password || exit 1
    install_units || {
      echo "Stopped: installing the services failed, see above."
      exit 1
    }
    echo
  fi
  echo "xone and xpad-noone are already installed for this kernel ($kernel)."
  echo "Steam Machine patch for xone: $(patch_result)."
  echo "If a pad does not connect, unplug the adapter, wait 5 seconds and plug"
  echo "it back in."
  exit 0
fi

if $boot; then
  echo "xone is missing for kernel $kernel, as after a SteamOS update."
  online=false
  for _ in $(seq 90); do
    curl -fsS --max-time 10 -o /dev/null https://aur.archlinux.org/ && online=true && break
    sleep 10
  done
  if ! $online; then
    echo "Stopped: no connection to the AUR in 15 minutes. The next start tries again."
    exit 1
  fi
  echo "Building xone again..."
elif systemctl is-active --quiet xone-after-update.service; then
  echo "The Steam Machine is building xone by itself after the SteamOS update."
  echo "Pads work once it is done, in a few minutes."
  exit 1
fi

build=""
fail() {
  echo "Stopped: $1"
  cd "$home" || exit 1
  [ -n "$build" ] && rm -rf -- "$build"
  root steamos-readonly enable
  exit 1
}

if ! $boot; then
  ask_password || exit 1
  # Keeps sudo from asking for the password again during the builds.
  (while sleep 60; do sudo -n true || exit; done) &
  keepalive=$!
  trap 'kill "$keepalive" 2>/dev/null' EXIT
fi

root steamos-readonly disable

if $need_tools || $need_fw; then
  echo "Installing the build tools and the kernel headers..."
  root pacman-key --init
  root pacman-key --populate archlinux holo
  root pacman -Syu --noconfirm --needed base-devel fakeroot glibc git \
    "$kernel_pkg" "$kernel_pkg-headers" linux-api-headers ||
    fail "the SteamOS package update failed, see above."
  deps=(dkms)
  $need_fw && deps+=(w3m html-xml-utils)
  root pacman -S --noconfirm --needed --asdeps "${deps[@]}" ||
    fail "installing the build tools failed, see above."
fi

build=$(as_user mktemp -d "$home/xone-build.XXXXXX") || fail "no build folder."
aur="https://aur.archlinux.org/cgit/aur.git/plain"

# $1 is the AUR package, the rest are files its PKGBUILD needs beside it.
fetch_pkg() {
  as_user bash -c '
    build=$1 pkg=$2 aur=$3
    shift 3
    rm -rf "$build/$pkg" && mkdir "$build/$pkg" && cd "$build/$pkg" || exit 1
    for file in PKGBUILD "$@"; do
      curl -fsSL --retry 4 -o "$file" "$aur/$file?h=$pkg" || exit 1
    done' _ "$build" "$1" "$aur" "${@:2}"
}
# makepkg refuses root, so at start it runs as the user.
make_pkg() { as_user bash -c 'cd "$1" && makepkg -Ccf --noconfirm' _ "$build/$1"; }
build_pkg() { fetch_pkg "$@" && make_pkg "$1"; }

# $1 is apply, or skip to build xone as the AUR has it. The PKGBUILD gets a
# prepare() that applies the patch and notes how that went.
add_patch() {
  local dir="$build/xone-dkms"
  if grep -q '^prepare()' "$dir/PKGBUILD" || ! grep -q '^sha256sums=' "$dir/PKGBUILD"; then
    echo "The AUR's xone-dkms build changed, so xone is built without the Steam Machine patch."
    return 0
  fi
  steambox_patch | as_user tee "$dir/steambox-xone.patch" >/dev/null || return 1
  as_user tee -a "$dir/PKGBUILD" >/dev/null <<EOF

source+=(steambox-xone.patch)
sha256sums+=(SKIP)
prepare() {
  cd "\$srcdir/\$_pkgsrc" || return 1
  if [ $1 != apply ]; then
    echo "left out, as xone did not build with it" >steambox-patch
  elif git apply --check ../steambox-xone.patch; then
    git apply ../steambox-xone.patch && echo "applied" >steambox-patch
  else
    echo "left out, as it does not fit xone \$pkgver" >steambox-patch
  fi
}
EOF
}

# pacman's DKMS hook keeps a module already built for this xone version, so
# the module is built again here.
build_xone() {
  fetch_pkg xone-dkms && add_patch "$1" && make_pkg xone-dkms &&
    root pacman -U --noconfirm "$build"/xone-dkms/xone-dkms-[0-9]*.pkg.tar.* &&
    { root dkms remove "xone/$(xone_version)" -k "$kernel" >/dev/null 2>&1 || true; } &&
    root dkms install "xone/$(xone_version)" -k "$kernel" &&
    built xone
}

changed=false

# xone-dkms depends on the firmware package, so that one goes in first.
if $need_fw; then
  build_pkg xone-dongle-firmware || fail "building the adapter firmware failed."
  root pacman -U --noconfirm --asdeps \
    "$build"/xone-dongle-firmware/xone-dongle-firmware-[0-9]*.pkg.tar.* ||
    fail "installing the adapter firmware failed."
  changed=true
fi

if $need_xone; then
  if ! build_xone apply; then
    echo "xone did not build with the Steam Machine patch, so it is built without it."
    build_xone skip || fail "building xone failed."
  fi
  if ! built xone; then
    # Without the module, its blacklist would leave the adapter with no driver.
    root pacman -R --noconfirm xone-dkms
    fail "xone did not build for kernel $kernel, see above. Nothing changed."
  fi
  root mkdir -p "${patch_mark%/*}" && patch_key | root tee "$patch_mark" >/dev/null
  echo "Steam Machine patch for xone: $(patch_result)."
  changed=true
fi

noone_ok=true
if $need_noone; then
  if build_pkg xpad-noone-git modprobe.conf &&
    root pacman -U --noconfirm \
      "$build"/xpad-noone-git/xpad-noone-git-r*.pkg.tar.* &&
    built xpad-noone; then
    changed=true
  else
    noone_ok=false
    missing xpad-noone-git || root pacman -R --noconfirm xpad-noone-git
  fi
fi

$need_fw && root pacman -Rns --noconfirm w3m html-xml-utils
if $need_units && ! install_units; then
  echo "Warning: installing the services failed, see above."
fi
cd "$home" && rm -rf -- "$build"
root steamos-readonly enable

if ! $changed; then
  echo "Stopped: nothing new was installed."
  exit 1
fi

if $boot; then
  # Loading the modules now spares a restart in the middle of a game.
  adapter_state() {
    local d link
    for d in /sys/bus/usb/devices/*; do
      [ "$(cat "$d/idVendor" 2>/dev/null)" = 045e ] || continue
      case $(cat "$d/idProduct" 2>/dev/null) in
        02e6 | 02fe | 02f9 | 091e) ;;
        *) continue ;;
      esac
      link=$(readlink -f "$d/${d##*/}:1.0/driver" 2>/dev/null)
      if [ "${link##*/}" = xone-dongle ]; then echo bound; else echo plugged; fi
      return
    done
    echo absent
  }
  modprobe -r xpad 2>/dev/null
  modprobe -r mt76x2u 2>/dev/null
  modprobe xone_dongle
  ! $noone_ok || modprobe xpad_noone
  state=absent
  for _ in $(seq 30); do
    state=$(adapter_state)
    [ "$state" = plugged ] || break
    sleep 1
  done
  case $state in
    bound) echo "xone is back and runs the adapter, with no restart." ;;
    absent) echo "xone is back; it takes the adapter once it is plugged in." ;;
    *)
      echo "xone is back but did not take the adapter, so the Steam Machine restarts."
      systemctl reboot
      ;;
  esac
  exit 0
fi

echo
if ! $noone_ok; then
  echo "Warning: xpad-noone did not build, see above. While xone is installed,"
  echo "Xbox 360 pads and the Xbox 360 receiver do not work; Xbox One pads do."
fi
if ! $reboot; then
  echo "xone is installed. It runs once xone restarts."
  exit 0
fi
echo "xone is installed. After the reboot, if the adapter's light stays off,"
echo "unplug the adapter and plug it back in."
echo "Rebooting in 15 seconds, Ctrl+C to stay."
sleep 15
sudo reboot
