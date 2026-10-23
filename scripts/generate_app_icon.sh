#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$ROOT/Resources"
APP_ICON_SOURCE_PATH="$ROOT/Resources/OpenBridgeAppIconSource.svg"
BRAND_MARK_SOURCE_PATH="$ROOT/Resources/OpenBridgeAppIconSource.svg"
MENU_BAR_SOURCE_PATH="$RESOURCES_DIR/OpenBridgeMenuBarSource.jpeg"
ICONSET_DIR="$RESOURCES_DIR/OpenBridgeIcon.iconset"
ICNS_PATH="$RESOURCES_DIR/OpenBridgeIcon.icns"
MENU_BAR_PNG_PATH="$RESOURCES_DIR/OpenBridgeMenuBarTemplate.png"
SWIFT_RESOURCES_DIR="$ROOT/Sources/OpenBridgeApp/Resources"
SWIFT_MENU_BAR_PNG_PATH="$SWIFT_RESOURCES_DIR/OpenBridgeMenuBarTemplate.png"
SWIFT_BRAND_MARK_PNG_PATH="$SWIFT_RESOURCES_DIR/OpenBridgeBrandMark.png"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR" "$ICONSET_DIR"
}
trap cleanup EXIT

command -v sips >/dev/null || (echo "sips is required to resize icon assets." >&2; exit 1)
command -v iconutil >/dev/null || (echo "iconutil is required to build the .icns file." >&2; exit 1)
command -v swift >/dev/null || (echo "swift is required to build the menu bar template icon." >&2; exit 1)

if [[ ! -f "$APP_ICON_SOURCE_PATH" ]]; then
  echo "Missing app icon source: $APP_ICON_SOURCE_PATH" >&2
  exit 1
fi
if [[ ! -f "$BRAND_MARK_SOURCE_PATH" ]]; then
  echo "Missing brand mark source: $BRAND_MARK_SOURCE_PATH" >&2
  exit 1
fi
if [[ ! -f "$MENU_BAR_SOURCE_PATH" ]]; then
  echo "Missing menu bar icon source: $MENU_BAR_SOURCE_PATH" >&2
  exit 1
fi

mkdir -p "$RESOURCES_DIR"
SOURCE_PNG="$TMP_DIR/OpenBridgeAppIconSource.png"
sips -s format png -z 1024 1024 "$APP_ICON_SOURCE_PATH" --out "$SOURCE_PNG" >/dev/null
mkdir -p "$SWIFT_RESOURCES_DIR"
sips -s format png -z 512 512 "$BRAND_MARK_SOURCE_PATH" --out "$SWIFT_BRAND_MARK_PNG_PATH" >/dev/null

mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

MENU_TEMPLATE_SCRIPT="$TMP_DIR/make_menu_template.swift"
cat >"$MENU_TEMPLATE_SCRIPT" <<'SWIFT'
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("Usage: make_menu_template.swift input output1 output2...\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURLs = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
guard let sourceImage = NSImage(contentsOf: inputURL),
      let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("Could not load menu bar source image.\n".utf8))
    exit(1)
}

let size = 44
let bytesPerPixel = 4
let bytesPerRow = size * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: size * bytesPerRow)

guard let context = CGContext(
    data: &pixels,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("Could not create bitmap context.\n".utf8))
    exit(1)
}

context.interpolationQuality = .high
context.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: size, height: size))

for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
    let red = Double(pixels[index])
    let green = Double(pixels[index + 1])
    let blue = Double(pixels[index + 2])
    let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
    let alpha: UInt8
    if luminance <= 55 {
        alpha = 0
    } else if luminance >= 180 {
        alpha = 255
    } else {
        alpha = UInt8(max(0, min(255, ((luminance - 55) / 125) * 255)))
    }
    pixels[index] = 255
    pixels[index + 1] = 255
    pixels[index + 2] = 255
    pixels[index + 3] = alpha
}

guard let outputCGImage = context.makeImage() else {
    FileHandle.standardError.write(Data("Could not create output image.\n".utf8))
    exit(1)
}

for outputURL in outputURLs {
    guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("Could not create PNG destination for \(outputURL.path).\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, outputCGImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("Could not write PNG to \(outputURL.path).\n".utf8))
        exit(1)
    }
}
SWIFT
swift "$MENU_TEMPLATE_SCRIPT" "$MENU_BAR_SOURCE_PATH" "$MENU_BAR_PNG_PATH" "$SWIFT_MENU_BAR_PNG_PATH"
echo "Generated app icon at: $ICNS_PATH"
echo "Generated menu bar icon at: $MENU_BAR_PNG_PATH"
echo "Generated SwiftUI brand mark at: $SWIFT_BRAND_MARK_PNG_PATH"
