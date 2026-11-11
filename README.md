# ShenzhenQR

A tiny Mac app that reads QR codes and barcodes from any camera: the built-in one, a USB webcam, a virtual camera or an iPhone.

<a href="https://github.com/casimir-engineering/shenzhen-qr/releases/latest/download/ShenzhenQR.dmg"><img src="https://img.shields.io/badge/Download%20for%20macOS-Apple%20Silicon-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS (Apple Silicon)" height="46"></a>

Apple Silicon · macOS 14+ · Signed and notarized

![ShenzhenQR reading a Wi-Fi QR code](docs/screenshot.png)

- **Any camera.** Pick it from the menu at the top; ShenzhenQR remembers your choice and notices cameras being plugged in or removed.
- **Every common code.** QR, Micro QR, Aztec, Data Matrix, PDF417, EAN and UPC, Code 128, 39 and 93, ITF, Codabar and GS1 DataBar.
- **See where it is.** A green outline marks each code where it was read. With several in view, click one to use it.
- **Settings** (⌘,): the camera resolution, and how many processor cores read frames at the same time (4 unless you change it).
- **The text, ready to use.** What the code holds appears in a field you can select and edit. **Copy** puts it on the clipboard.
- **The right next step.** Depending on the code: **Join** a Wi-Fi network (or copy its password), **Open in Browser**, **Add to Contacts**, **Add to Calendar**, **Write Email**, **Call**, **Send Message** or **Show in Maps**. Buttons follow your edits.

## Install

Download `ShenzhenQR.dmg` with the button above, open it and drag ShenzhenQR onto Applications. When you first open ShenzhenQR from Applications, it ejects the disk image for you. Opened straight from the disk image, it offers to move itself to Applications.

Requires macOS 14 or later on Apple Silicon. Nothing you scan leaves your Mac.

## Command line

The app is also a command-line tool. To call it `shenzhenqr`:

```bash
sudo ln -sf /Applications/ShenzhenQR.app/Contents/MacOS/ShenzhenQR /usr/local/bin/shenzhenqr
```

```text
$ shenzhenqr scan desk.jpg
desk.jpg: QR code · Wi-Fi network · at x 513, y 167, 301 × 283 px of 1280 × 720
  WIFI:T:WPA;S:Shenzhen Lab;P:hello-shenzhen;;
  → Join “Shenzhen Lab” · Copy Password
```

- `shenzhenqr scan [options] <picture>...` reads every code in pictures (`-` reads standard input).
- `shenzhenqr camera [options]` prints each new code a camera sees, until Ctrl-C; `--once` stops at the first.
- `shenzhenqr cameras`, `shenzhenqr types` list the cameras and the code types.
- `shenzhenqr parse <text>` says what a code's text is and what can be done with it; `shenzhenqr run <text> join` does it.
- `shenzhenqr settings [<name> <value>]` shows or changes the app's settings: `resolution`, `cores`, `camera`.

`--json` gives one JSON object per code with its type, text, kind, actions and position: `box` (x, y, width,
height) and `corners`, in pixels from the picture's top-left corner. `--text` gives only the text, `--first` only the
biggest code, `--types qr,ean13` only those types, `--cores <n>` how many pictures or frames are read at once.
`shenzhenqr help` has the rest. Exit status: 0 a code was read, 1 none was, 2 the command was wrong, 3 the camera
can't be used. The camera needs your terminal app allowed in System Settings › Privacy & Security › Camera.

## Build

One Swift file, no dependencies:

```bash
./build.sh            # build/ShenzhenQR.app, signed for this Mac only
./build.sh --release  # Developer ID signature, notarized app and disk image
```

`make-icon.swift` draws the icon; `ShenzhenQR --screenshot <out.png> <picture>` draws the screenshot above.
