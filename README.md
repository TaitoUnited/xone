<p align="center">
  <img src="src/banner.svg" alt="xone for the office Steam Machine: no more dropped pads on the Melee couch" width="100%">
</p>

The Taito United Oy office plays Super Smash Bros. Melee on a Steam Machine from a couch too far
from the TV for cables. The Steam Controller does not suit Melee, so the office uses four Xbox One
controllers on an Xbox Wireless Adapter and this driver.

The controllers kept dropping. One pad on newer firmware failed its handshake with the adapter in
15 of 17 tries, the adapter kept the slots the driver had freed, and in the end it fell off USB and
took every pad with it. xone is no longer maintained, so this copy
(https://github.com/TaitoUnited/xone/pull/1):

- frees adapter slots the driver no longer holds;
- gives a rejoining pad a fresh slot;
- adds the option `channel=` to move the adapter off 2.4 GHz channel 1;
- logs each certificate chunk it acknowledges.

The driver and upstream's README are in [`src/`](src). The code is under the GNU General Public
License 2.0 or later, in [LICENSE](LICENSE). This README and the banner are under Creative Commons
Attribution-ShareAlike 4.0, in [LICENSE-PROSE](LICENSE-PROSE).
