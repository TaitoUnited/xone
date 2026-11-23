<p align="center">
  <img src="src/banner.svg" alt="xone, without the pad drops: first fixed on the office Melee couch" width="100%">
</p>

[xone](https://github.com/dlundqvist/xone) is the Linux driver for Xbox One and Xbox Series X|S
pads on the Xbox Wireless Adapter. When a pad fails its security handshake, xone can leave the pad's
slot on the adapter stuck, so the pad cannot join again
([issue 210](https://github.com/dlundqvist/xone/issues/210)), and upstream is no longer
maintained. This copy:

- frees adapter slots the driver no longer holds and gives a rejoining pad a fresh one;
- adds the option `channel=` to pick the adapter's channel, such as 36 in place of 2.4 GHz
  channel 1;
- logs each certificate chunk it acknowledges.

It started at the Taito United Oy office, which plays Super Smash Bros. Melee on a Steam Machine
with four Xbox One controllers on an Xbox Wireless Adapter. One pad, a Model 1708 on controller
firmware 5.23.6.0 from March 2025, failed its handshake in 15 of 17 tries, and the stuck slots
ended with the adapter falling off USB and every pad dropping. On 23 November 2026, after this copy
went in, that pad joined 13 times without a failed handshake.

## Why the pad failed

To prove it is a genuine Xbox pad, a controller sends the adapter a certificate of about 780 bytes in
chunks and waits for each to be acknowledged. The Model 1708 is the 2016 revision introduced with the
Xbox One S ([Wikipedia](https://en.wikipedia.org/wiki/Xbox_Wireless_Controller)). On firmware
5.23.6.0, which Microsoft shipped in late March 2025 to fix 5.23.5.0
([24 Rows](https://24rows.com/xbox-controller-firmware-5-23-6-0-microsoft-fixes-major-issues-from-previous-update/)),
it sends 122-byte chunks, and on 19 November 2026 its certificate stopped arriving partway in 15 of
17 tries. The same model on firmware 3.1.1221.0 sends 58-byte chunks and got through.
[Issue 210](https://github.com/dlundqvist/xone/issues/210), open since July 2026 with no reply,
describes a failed handshake leaving a slot stuck, on an Elite Series 2 with firmware 5.22.16.0.

## Why upstream has no fix

xone's author, Severin von Wnuck-Lipinski, put it in maintenance mode on 21 December 2025 and pointed
to the fork dlundqvist/xone
([commit](https://github.com/medusalix/xone/commit/3484f603484782dd7551c64e5a33fc602b127051)).
That fork's README has said since 15 November 2026 that it is no longer actively maintained as of
July 2026, and asks for someone to take it over ([README](https://github.com/dlundqvist/xone)).
Neither README gives a reason. Tomasz Pakuła, who merged the fork's last code changes in March 2026,
wrote in its [PR 234](https://github.com/dlundqvist/xone/pull/234) that they are no longer a
maintainer and have no Xbox hardware left to test with.

The Arch Wiki predates that notice. Its [Gamepad](https://wiki.archlinux.org/title/Gamepad) page,
last edited on 7 November 2026, still says the dlundqvist fork maintains xone's bugfixes and sends
readers to the AUR package [xone-dkms](https://aur.archlinux.org/packages/xone-dkms), which builds
that fork's v0.5.8. It also tells readers to update a pad's firmware when it performs poorly; here
the pad on the newer firmware is the one that failed.

## Try it

On the machine with the adapter, paste this into Claude Code:

```text
clone github.com/TaitoUnited/xone, install the xone driver from its src/xone folder as
src/xone/README.md says, and load xone_dongle with the option channel=36
```

A machine without Claude Code, such as the office Steam Machine in Gaming Mode, gets the fix from a
USB stick, as [src/stick/README.md](src/stick/README.md) describes.

## The C changes

Commit [a40a6ff](https://github.com/TaitoUnited/xone/commit/a40a6ff3742c5d2a4b3a8d4b52e8d306e15a5580)
on upstream commit 30317da added or changed these parts of four files; `/* ... */` stands for
unchanged code left out.

[`src/xone/bus/protocol.c`](src/xone/bus/protocol.c):

```c
if (ack->options & GIP_OPT_CHUNK)
	gip_dbg(client, "%s: command=0x%02x, length=0x%04x, remaining=0x%04x\n",
		__func__, pkt.command, len, le16_to_cpu(pkt.remaining));
```

[`src/xone/transport/dongle.c`](src/xone/transport/dongle.c):

```c
#define XONE_DONGLE_STALE_CLIENT msecs_to_jiffies(1000)
/* ... */
unsigned long last_rx;
/* ... */
if (!dongle->pairing || dongle->mt.channel_fixed)
/* ... */
client->last_rx = jiffies;
/* ... */
static int xone_dongle_remove_client(struct xone_dongle *dongle, u8 wcid);

static int xone_dongle_add_client(struct xone_dongle *dongle, u8 *addr)
{
	struct xone_dongle_client *client;
	int i, err;
	unsigned long flags;

	/*
	 * A controller that asks to join while it holds a slot has lost its
	 * connection without a word, unless it sent data within the last
	 * second. Left alone, its dead slot keeps it from joining again.
	 */
	for (i = 0; i < XONE_DONGLE_MAX_CLIENTS; i++) {
		client = dongle->clients[i];
		if (!client || !ether_addr_equal(client->address, addr))
			continue;

		if (time_before(jiffies,
				client->last_rx + XONE_DONGLE_STALE_CLIENT))
			return 0;

		dev_dbg(dongle->mt.dev, "%s: replacing stale wcid=%d, address=%pM\n",
			__func__, client->wcid, addr);
		xone_dongle_remove_client(dongle, client->wcid);
		break;
	}

	client = xone_dongle_create_client(dongle, addr);
	if (IS_ERR(client))
		return PTR_ERR(client);
/* ... */
if (!client) {
	/* the adapter can keep reporting a slot xone holds no client in */
	dev_dbg(dongle->mt.dev, "%s: freeing empty wcid=%d\n",
		__func__, wcid);
	return xone_mt76_remove_client(&dongle->mt, wcid);
}
/* ... */
client->last_rx = jiffies;
```

[`src/xone/transport/mt76.c`](src/xone/transport/mt76.c):

```c
static uint fixed_channel;
module_param_named(channel, fixed_channel, uint, 0444);
MODULE_PARM_DESC(channel, "Run the adapter on this channel, such as 36, instead of the one with the highest transmit power");

/* ... */
struct xone_mt76_channel *chan, *fixed = NULL;
int i, err, pow = 0;

mt->channel = NULL;
mt->channel_fixed = false;
/* ... */

	if (fixed_channel && chan->index == fixed_channel)
		fixed = chan;
}

if (fixed) {
	mt->channel = fixed;
	mt->channel_fixed = true;
	dev_info(mt->dev, "%s: channel=%u, set by the channel option\n",
		 __func__, fixed->index);
} else if (fixed_channel) {
	dev_warn(mt->dev, "%s: channel option %u is not one of the adapter's channels\n",
		 __func__, fixed_channel);
```

[`src/xone/transport/mt76.h`](src/xone/transport/mt76.h):

```c
struct xone_mt76 {
	/* ... */
	struct xone_mt76_channel channels[XONE_MT_NUM_CHANNELS];
	struct xone_mt76_channel *channel;
	bool channel_fixed;
};
```

## License

The driver in [`src/xone/`](src/xone): `GPL-2.0-or-later` ([LICENSE](LICENSE)), as upstream's. A
kernel module has to declare a GPL-compatible license for the kernel to link it to the USB
functions it needs ([license rules](https://docs.kernel.org/process/license-rules.html)). The
scripts in [`src/stick/`](src/stick): `AGPL-3.0-or-later` ([src/stick/LICENSE](src/stick/LICENSE)),
apart from the patch inside `install-xone.sh`, which is code from `src/xone/` and keeps its
license. This README and the one in `src/stick/`, the banner and the library art in
`src/stick/commands/fix-art/`: `CC-BY-SA-4.0` ([LICENSE-PROSE](LICENSE-PROSE)).
