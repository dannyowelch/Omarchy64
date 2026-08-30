# Omarchy64

Launch [VICE](https://vice-emu.sourceforge.io/) from the Omarchy bar, load a C64 image, map a joystick, and play on a dedicated workspace.

The bar icon is the classic Commodore “duck lips” C.

## Why VICE

VICE is the standard open-source Commodore emulator. Arch packages it as `vice-sdl2` (SDL2, preferred here) and `vice` (GTK3). The SDL2 build is the better fit for this plugin: it is a single game window, talks to USB pads through SDL, and moves cleanly onto a Hyprland workspace.

Frodo and similar emulators are lighter, but they do not cover cartridges, tapes, and joystick mapping as completely. libretro VICE cores are already in the Omarchy repo; RetroArch is a heavier launcher than `x64sc` for “open this `.d64`”.

## What it does

- Bar button with the duck-lips C; click opens the panel
- **Drive 8** — choose a disk; attaches it if VICE is already open, otherwise just remembers it
- **Eject** — empty drive 8
- **Load "*",8,1** — RUN the disk in drive 8 (file chooser if the drive is empty)
- **BASIC** — READY. prompt; the remembered disk is in drive 8 if one is set
- PAL / NTSC toggle (restarts VICE with `-pal` or `-ntsc` if it is already running)
- Map the first gamepad (or a keyboard keyset) to C64 control port **2** by default
- Always opens on Hyprland workspace **64**
- Right-click the bar icon to run the last autostarted image; middle-click quits VICE

## Install

```sh
omarchy pkg add vice-sdl2
omarchy plugin add https://github.com/dannyowelch/omarchy64.git --enable
```

Drop images into `~/Games/C64`. **Drive 8** and **Load "*",8,1** open a file chooser there.

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

- Click the duck-lips C on the bar
- **BASIC** for a blank READY. prompt
- **Drive 8** to put a `.d64` in the drive (type `LOAD "*",8,1` yourself)
- **Load "*",8,1** to launch and RUN a `.prg`, `.crt`, `.d64`, or `.tap`
- PAL / NTSC, joystick, and port are under Controls

Keyboard in the panel: `j` / `k` moves, `d` Drive 8, `l` Load, `b` BASIC, Esc closes.

While VICE is focused, a USB pad is the joystick. With **Keyboard**, VICE Keyset A is arrows plus Ctrl as fire.

Summon from a bind:

```
omarchy-shell shell summon io.github.dannyowelch.omarchy64 '{}'
```

CLI (same binary the panel runs):

```sh
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl status
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl basic
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl drive8 ~/Games/C64/game.d64
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl launch ~/Games/C64/game.d64
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl set video ntsc
~/.config/omarchy/plugins/io.github.dannyowelch.omarchy64/omarchy64-ctl quit
```

## Controls

| Setting | Default | Notes |
|---------|---------|--------|
| Workspace | `64` | Dedicated Hyprland workspace |
| Joystick | Auto | First `/dev/input/js*` or `*-event-joystick`; otherwise keyboard |
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

MIT. The duck-lips C is a tribute to the classic Commodore mark.
