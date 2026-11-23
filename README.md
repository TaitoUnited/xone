<p align="center">
  <img src="src/banner.svg" alt="xone for the office Steam Machine: no more dropped pads on the Melee couch" width="100%">
</p>

The Taito United Oy office plays Super Smash Bros. Melee on a Steam Machine with four Xbox One
controllers on an Xbox Wireless Adapter. One pad, a Model 1708 on controller firmware 5.23.6.0 from
March 2025, failed its security handshake in 15 of 17 tries, and a failure could leave the adapter
holding a slot until it fell off USB and dropped every pad. Upstream xone is no longer maintained, so
this copy:

- frees adapter slots the driver no longer holds and gives a rejoining pad a fresh one;
- adds the option `channel=` to move the adapter off 2.4 GHz channel 1;
- logs each certificate chunk it acknowledges.

On 23 November 2026, after this copy went in, that pad joined 13 times without a failed handshake.

<details>
<summary>Why the pad failed, why upstream has no fix, the C changes and how to try it</summary>

**Why the pad failed.** To prove it is a genuine Xbox pad, a controller sends the adapter a
certificate of about 780 bytes in chunks and waits for each to be acknowledged. The Model 1708 is the
2016 revision introduced with the Xbox One S
([Wikipedia](https://en.wikipedia.org/wiki/Xbox_Wireless_Controller)). On firmware 5.23.6.0, which
Microsoft shipped in late March 2025 to fix 5.23.5.0
([24 Rows](https://24rows.com/xbox-controller-firmware-5-23-6-0-microsoft-fixes-major-issues-from-previous-update/)),
it sends 122-byte chunks, and on 19 November 2026 its certificate stopped arriving partway in 15 of
17 tries. The same model on firmware 3.1.1221.0 sends 58-byte chunks and got through.
[Issue 210](https://github.com/dlundqvist/xone/issues/210), open since July 2026 with no reply,
describes a failed handshake leaving a slot stuck, on an Elite Series 2 with firmware 5.22.16.0.

**Why upstream has no fix.** xone's author, Severin von Wnuck-Lipinski, put it in maintenance mode
on 21 December 2025 and pointed to the fork dlundqvist/xone
([commit](https://github.com/medusalix/xone/commit/3484f603484782dd7551c64e5a33fc602b127051)).
That fork's README has said since 15 November 2026 that it is no longer actively maintained as of
July 2026, and asks for someone to take it over ([README](https://github.com/dlundqvist/xone)).
Neither README gives a reason. Tomasz Pakuła, who merged the fork's last code changes in March 2026,
wrote in its [PR 234](https://github.com/dlundqvist/xone/pull/234) that he is no longer a
maintainer and has no Xbox hardware left to test with.

**Try it.** Paste this into Claude Code on the machine with the adapter:

```text
clone github.com/TaitoUnited/xone, install the xone driver from its src folder as src/README.md
says, and load xone_dongle with the option channel=36
```

**The C changes**, commit a40a6ff on upstream commit 30317da:

```diff
--- a/src/bus/protocol.c
+++ b/src/bus/protocol.c
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
--- a/src/transport/dongle.c
+++ b/src/transport/dongle.c
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
--- a/src/transport/mt76.c
+++ b/src/transport/mt76.c
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
--- a/src/transport/mt76.h
+++ b/src/transport/mt76.h
@@ -60,6 +60,7 @@ struct xone_mt76 {
 
 	struct xone_mt76_channel channels[XONE_MT_NUM_CHANNELS];
 	struct xone_mt76_channel *channel;
+	bool channel_fixed;
 };
 
 struct sk_buff *xone_mt76_alloc_message(int len, gfp_t gfp);
```

</details>

Code in [`src/`](src): `GPL-2.0-or-later`. This README and the banner: `CC-BY-SA-4.0`
([LICENSE-PROSE](LICENSE-PROSE)).
