# SystemRescue Kitchen

My config for customizing [SystemRescue](https://www.system-rescue.org/).

> Requires `sysrescue-customize`, `curl`, `jq`, `mksquashfs`, `rsync`, and `xorriso`.

Uses a simple script which when run, finds the latest version of the SystemRescue ISO in the `input` folder,
and uses [`sysrescue-customize`](https://www.system-rescue.org/scripts/sysrescue-customize/) to make some 
tweaks to my liking, namely:

- Touchpad settings
  - Natural scrolling
  - Tap-to-click
- XFCE dark mode (Adwaita-dark)
- Custom wallpapers
- Some Firefox [extensions](./extensions.txt) I like.

## Usage
0. Clone the repo
0. Create `./input` and `./output` folders in the repo root.
0. Paste in a SystemRescue ISO image into `./input`.
0. Run [`build.sh`](./build.sh).


> Wallpapers by [Pawel Czerwinski on Unsplash](https://unsplash.com/@pawel_czerwinski)