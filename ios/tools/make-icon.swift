#!/usr/bin/env swift
//
//  make-icon.swift
//  Crops a square out of any image and writes a 1024x1024 App Store icon.
//
//  Exists because the obvious tools don't fit: `sips` only crops dead-centre,
//  and neither PIL nor ImageMagick is installed. This is CoreGraphics, which
//  ships with the machine.
//
//  Usage:
//    swift tools/make-icon.swift <input> <output.png> [centerX] [centerY] [side]
//
//    centerX, centerY   where to centre the crop, as fractions of the image
//                       (0,0 = top-left, 0.5,0.5 = middle). Default 0.5 0.5.
//    side               square size as a fraction of the SHORTER edge.
//                       Default 1.0, i.e. the largest square that fits.
//
//  Example — the mushroom sits about 64% across a wide panorama:
//    swift tools/make-icon.swift shroom.jpg icon-1024.png 0.64 0.45 0.95
//
//  The output is deliberately opaque: App Store icons must have no alpha
//  channel, and a transparent one is rejected at upload rather than at build.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    die("usage: make-icon.swift <input> <output.png> [centerX] [centerY] [side]")
}

let inputPath  = args[1]
let outputPath = args[2]
let centerX = args.count > 3 ? Double(args[3]) ?? 0.5 : 0.5
let centerY = args.count > 4 ? Double(args[4]) ?? 0.5 : 0.5
let sideFrac = args.count > 5 ? Double(args[5]) ?? 1.0 : 1.0

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    die("could not read \(inputPath)")
}

let w = CGFloat(image.width)
let h = CGFloat(image.height)

// Square side measured against the shorter edge, so a panorama gives a crop as
// tall as the image rather than something taller than it.
let side = min(CGFloat(sideFrac) * min(w, h), min(w, h))

// CGImage's coordinate space puts (0,0) at the top-left, so centerY is measured
// downward from the top. Clamped so a centre near an edge slides the crop back
// inside the frame instead of producing an out-of-bounds rect.
let x = min(max(CGFloat(centerX) * w - side / 2, 0), w - side)
let y = min(max(CGFloat(centerY) * h - side / 2, 0), h - side)

guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
    die("crop failed — rect \(x),\(y) \(side)x\(side) against a \(Int(w))x\(Int(h)) image")
}

let out = 1024
guard let ctx = CGContext(data: nil,
                          width: out, height: out,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    die("could not create the output context")
}
ctx.interpolationQuality = .high
ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: out, height: out))

guard let final = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    die("could not create \(outputPath)")
}
CGImageDestinationAddImage(dest, final, nil)
guard CGImageDestinationFinalize(dest) else { die("could not write \(outputPath)") }

print("\(Int(w))x\(Int(h)) → cropped \(Int(side))² at (\(Int(x)),\(Int(y))) → \(out)x\(out) opaque → \(outputPath)")
