# ShenzhenQR

A tiny Mac app that reads QR codes and barcodes from any camera: the built-in one, a USB webcam, a virtual camera or an iPhone.

![ShenzhenQR reading a Wi-Fi QR code](docs/screenshot.png)

- **Any camera.** Pick it from the menu at the top; ShenzhenQR remembers your choice and notices cameras being plugged in or removed.
- **Every common code.** QR, Micro QR, Aztec, Data Matrix, PDF417, EAN and UPC, Code 128, 39 and 93, ITF, Codabar and GS1 DataBar.
- **The text, ready to use.** What the code holds appears in a field you can select and edit. **Copy** puts it on the clipboard.
- **The right next step.** Depending on the code: **Join** a Wi-Fi network (or copy its password), **Open in Browser**, **Add to Contacts**, **Add to Calendar**, **Write Email**, **Call**, **Send Message** or **Show in Maps**. Buttons follow your edits.

## Install

Download `ShenzhenQR.dmg` from [Releases](../../releases/latest), open it and drag ShenzhenQR onto Applications. When you first open ShenzhenQR from Applications, it ejects the disk image for you. Opened straight from the disk image, it offers to move itself to Applications.

Requires macOS 14 or later on Apple Silicon. Nothing you scan leaves your Mac.

## Build

One Swift file, no dependencies:

```bash
./build.sh            # build/ShenzhenQR.app, signed for this Mac only
./build.sh --release  # Developer ID signature, notarized app and disk image
```

`make-icon.swift` draws the icon; `ShenzhenQR --decode <image>…` prints what the app would do with the codes in pictures.
