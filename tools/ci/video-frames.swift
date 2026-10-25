// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Extracts PNG frames from a simulator screen recording (CI only, macOS runner):
//   xcrun swift tools/ci/video-frames.swift <video> <out-dir> [seconds=8] [step=0.1]
// The CI screenshot job records the first seconds after `simctl launch`, because the launch
// screen shows for less time than one `simctl io screenshot` takes.

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: video-frames.swift <video> <out-dir> [seconds] [step]")
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let out = URL(fileURLWithPath: args[2], isDirectory: true)
let limit = args.count > 3 ? Double(args[3]) ?? 8 : 8
let step = args.count > 4 ? Double(args[4]) ?? 0.1 : 0.1
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let duration = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

var index = 0
var time = 0.0
while time < min(duration, limit) {
    let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
    let url = out.appendingPathComponent(String(format: "frame-%03d.png", index))
    if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    index += 1
    time += step
}
print("video-frames: \(index) frames from \(String(format: "%.1f", duration)) s of video")
