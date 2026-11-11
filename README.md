# ShenzhenQR

A tiny Mac app that reads QR codes and barcodes from any camera: the built-in one, a USB webcam, a virtual camera or an iPhone.

<a href="https://github.com/casimir-engineering/shenzhen-qr/releases/latest/download/ShenzhenQR.dmg"><img src="https://img.shields.io/badge/Download%20for%20macOS-Apple%20Silicon-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS (Apple Silicon)" height="46"></a>

Apple Silicon · macOS 14+ · Signed and notarized

![ShenzhenQR reading a Wi-Fi QR code](docs/screenshot.png)

- **Any camera.** Pick it from the menu at the top; ShenzhenQR remembers your choice and notices cameras being plugged in or removed.
- **Every common code.** QR, Micro QR, Aztec, Data Matrix, PDF417, EAN and UPC, Code 128, 39 and 93, ITF, Codabar and GS1 DataBar.
- **The text, ready to use.** What the code holds appears in a field you can select and edit. **Copy** puts it on the clipboard.
- **The right next step.** Depending on the code: **Join** a Wi-Fi network (or copy its password), **Open in Browser**, **Add to Contacts**, **Add to Calendar**, **Write Email**, **Call**, **Send Message** or **Show in Maps**. Buttons follow your edits.

## Install

Download `ShenzhenQR.dmg` with the button above, open it and drag ShenzhenQR onto Applications. When you first open ShenzhenQR from Applications, it ejects the disk image for you. Opened straight from the disk image, it offers to move itself to Applications.

Requires macOS 14 or later on Apple Silicon. Nothing you scan leaves your Mac.

## Build

One Swift file, no dependencies:

```bash
./build.sh            # build/ShenzhenQR.app, signed for this Mac only
./build.sh --release  # Developer ID signature, notarized app and disk image
```

`make-icon.swift` draws the icon; `ShenzhenQR --decode <image>…` prints what the app would do with the codes in pictures.
