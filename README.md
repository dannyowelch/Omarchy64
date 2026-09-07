# Omarchy64

Launch [VICE](https://vice-emu.sourceforge.io/) from the Omarchy bar, load a C64 image, map a joystick, and play on a dedicated workspace.

The bar icon is a grayscale pixel-art **64**, colored with the bar foreground so it matches the other plugin glyphs.

## Why VICE

VICE is the standard open-source Commodore emulator. Arch packages it as `vice-sdl2` (SDL2, preferred here) and `vice` (GTK3). The SDL2 build is the better fit for this plugin: it is a single game window, talks to USB pads through SDL, and moves cleanly onto a Hyprland workspace.

Frodo and similar emulators are lighter, but they do not cover cartridges, tapes, and joystick mapping as completely. libretro VICE cores are already in the Omarchy repo; RetroArch is a heavier launcher than `x64sc` for “open this `.d64`”.

## What it does

- Bar button with a grayscale **64**; click opens the panel
- **Drive 8** — choose a disk; attaches it if VICE is already open, otherwise just remembers it
- **Cartridge** — choose a `.crt`; attaches it if VICE is already open, otherwise just remembers it
- **Eject** — empty drive 8 or the cartridge slot
- **Load "*",8,1** — RUN the disk in drive 8 (file chooser if the drive is empty)
- **Power** — start VICE if it is off, quit if it is on; disk and cartridge stay inserted
- **Pause** — toggle VICE pause (same as Alt+P in the emulator)
- **Reset** — soft-reset the running emulator (CPU reset, RAM kept)
- PAL / NTSC toggle (restarts VICE with `-pal` or `-ntsc` if it is already running)
- Map the first gamepad (or a keyboard keyset) to C64 control port **2** by default
- Always opens on Hyprland workspace **64**
- Right-click the bar icon to run the last autostarted image; middle-click quits VICE

## Install

```sh
omarchy pkg add vice-sdl2
omarchy plugin add https://github.com/dannyowelch/omarchy64.git --enable
```

Drop images into `~/Games/C64`. **Drive 8**, **Cartridge**, and **Load "*",8,1** open a file chooser there.

The git repo is `~/Projects/omarchy64`. Omarchy loads plugins from a separate live copy:

```
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/
```

After editing the repo, install into that live path:

```sh
./install-local.sh
```

Saved files in the live plugin directory reload automatically. Force rediscovery with:

```sh
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.dannyowelch.omarchy64 --section right
```

## Usage

- Click **64** on the bar
- **Power** to start or stop VICE (READY. if the cartridge slot is empty; otherwise the cart boots)
- **Pause** to freeze or resume the running emulator
- **Reset** for a soft reset while VICE is running
- **Drive 8** to put a `.d64` in the drive (type `LOAD "*",8,1` yourself)
- **Cartridge** to insert a `.crt` (stays inserted until you eject it)
- **Load "*",8,1** to launch and RUN a `.prg`, `.crt`, `.d64`, or `.tap`
- PAL / NTSC, joystick, and port are under Controls

Keyboard in the panel: `j` / `k` moves, `d` Drive 8, `c` Cartridge, `l` Load, `b` Power, `p` Pause, `r` Reset, Esc closes.

While VICE is focused, a USB pad is the joystick (stick or D-pad, plus fire on the first buttons). Changing joystick or port in the panel applies immediately if VICE is already running. **Keyboard** is arrows plus Space.

Summon from a bind:

```
omarchy-shell shell summon io.github.dannyowelch.omarchy64 '{}'
```

CLI (same binary the panel runs):

```sh
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl status
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl power
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl pause
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl reset
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl drive8 ~/Games/C64/game.d64
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl cart ~/Games/C64/game.crt
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl launch ~/Games/C64/game.d64
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl set video ntsc
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl quit
```

## Controls

| Setting | Default | Notes |
|---------|---------|--------|
| Workspace | `64` | Dedicated Hyprland workspace |
| Joystick | Auto | First SDL pad (stick/hat + fire); otherwise arrows + Space. Live-applied while VICE is running. |
| C64 port | 2 | Most games; Port 1 is the exception |
| Video | PAL | NTSC uses `-ntsc`; switching while VICE is open restarts it |
| Warp load | on | `-autostart-warp` on **Load "*",8,1** only |

State lives in `~/.local/state/omarchy/omarchy64.json`. A Hyprland toggle at `~/.local/state/omarchy/toggles/hypr/omarchy64.lua` keeps the VICE window opaque and inhibits idle while it is focused.

## Remove

```sh
omarchy plugin remove io.github.dannyowelch.omarchy64
```

Removal does not uninstall `vice-sdl2` or delete `~/Games/C64`. Delete `~/.local/state/omarchy/omarchy64.json` and `~/.local/state/omarchy/toggles/hypr/omarchy64.lua` if you want those gone too.

## License

MIT.
