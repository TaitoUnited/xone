# The USB stick route

The office Steam Machine has no Claude Code: it runs SteamOS in Gaming Mode, so a USB stick named
`SHARE` carries the work there and back. The scripts it carries are in [`commands/`](commands).

1. On the computer with Claude Code, paste this into Claude Code:

   ```text
   clone github.com/TaitoUnited/xone and copy its src/stick/commands folder to the usb stick named
   SHARE as commands
   ```

2. Plug the stick into the Steam Machine and switch it to Desktop Mode. The xone install asks for
   the password of the deck user; if it has none yet, set one in Konsole:

   ```bash
   passwd
   ```

3. Mount the stick in Konsole, which says where it went, or that it already is mounted:

   ```bash
   udisksctl mount -b /dev/disk/by-label/SHARE
   ```

4. Run the setup, which copies the scripts into the home folder, which SteamOS updates keep, and
   adds **Fix Xbox controllers** to the Steam library:

   ```bash
   bash /run/media/deck/SHARE/commands/setup.sh
   ```

5. In Gaming Mode, start **Fix Xbox controllers** from the library. It runs in Konsole: with the
   stick in, it takes the newer scripts from `commands/` and runs each job that Claude Code put in
   `run/` once, moving it to `run/done/` with its output. It then reports the pads that dropped,
   builds xone with the patch in `install-xone.sh` again after a SteamOS update, checks the adapter
   and closes by itself. When it needs the deck password, Steam's on-screen keyboard opens, so a pad
   can type it.
6. Each run saves its reports to `steambox-info/` on the stick, which goes back to the computer
   with Claude Code to be read.

## License

`AGPL-3.0-or-later` ([LICENSE](LICENSE)), apart from the patch inside `install-xone.sh`, which is
code from [`../xone/`](../xone) and keeps its `GPL-2.0-or-later`. The art in `commands/fix-art/`
and this README: `CC-BY-SA-4.0` ([LICENSE-PROSE](../../LICENSE-PROSE)).
