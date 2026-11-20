<p align="center">
  <img src="src/banner.svg" alt="xone for the office Steam Machine: no more dropped pads on the Melee couch" width="100%">
</p>

The Taito United Oy office plays Super Smash Bros. Melee on a Steam Machine with four Xbox One
controllers on an Xbox Wireless Adapter, since the couch is too far from the TV for cables and the
Steam Controller does not suit Melee. The pads kept dropping: one on newer firmware failed its
handshake in 15 of 17 tries, the adapter kept slots the driver had freed, and in the end it fell off
USB and took every pad with it. xone is no longer maintained, so this copy
(https://github.com/TaitoUnited/xone/pull/1):

- frees adapter slots the driver no longer holds;
- gives a rejoining pad a fresh slot;
- adds the option `channel=` to move the adapter off 2.4 GHz channel 1;
- logs each certificate chunk it acknowledges.

The code and upstream's README are in [`src/`](src), under `GPL-2.0-or-later`; this README and the
banner are under `CC-BY-SA-4.0` ([LICENSE-PROSE](LICENSE-PROSE)).
