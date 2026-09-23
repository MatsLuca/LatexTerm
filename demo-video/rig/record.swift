// record — captures one LatexTerm window with ScreenCaptureKit into an H.264 .mov.
// Usage: record <out.mov> [--fps 30] [--window-id N]   (stops on SIGINT/SIGTERM)
// Writes <out.mov>.json with the wall-clock time (unix ms) of the first frame, so the
// state log (statelog.py) can be aligned to video time.
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write("usage: record <out.mov> [--fps N] [--window-id N]\n".data(using: .utf8)!); exit(2) }
let outURL = URL(fileURLWithPath: args[1])
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let fps = Int(opt("--fps") ?? "30") ?? 30
let wantedID = opt("--window-id").flatMap { UInt32($0) }

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var writer: AVAssetWriter!
    var input: AVAssetWriterInput!
    var stream: SCStream!
    var started = false
    var firstPTS = CMTime.zero
    var frames = 0
    let q = DispatchQueue(label: "rec")

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let wins = content.windows.filter { $0.owningApplication?.applicationName == "LatexTerm" && $0.windowLayer == 0 && $0.frame.width > 400 }
        guard let win = (wantedID.flatMap { id in wins.first { $0.windowID == id } }) ?? wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw NSError(domain: "record", code: 1, userInfo: [NSLocalizedDescriptionKey: "no LatexTerm window"])
        }
        let scale = 2.0
        let w = Int(win.frame.width * scale) / 2 * 2, h = Int(win.frame.height * scale) / 2 * 2
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = true
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 8
        cfg.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: win)

        try? FileManager.default.removeItem(at: outURL)
        writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000, AVVideoExpectedSourceFrameRateKey: fps],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await stream.startCapture()
        print("recording window \(win.windowID) \(Int(win.frame.width))x\(Int(win.frame.height))pt at \(win.frame.origin) → \(w)x\(h)px")
        let meta: [String: Any] = ["windowID": win.windowID, "frame": [win.frame.origin.x, win.frame.origin.y, win.frame.width, win.frame.height], "scale": scale, "fps": fps]
        try? JSONSerialization.data(withJSONObject: meta).write(to: URL(fileURLWithPath: outURL.path + ".win.json"))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = att[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete || status == .idle
        else { return }
        guard CMSampleBufferGetImageBuffer(sb) != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started {
            started = true; firstPTS = pts
            writer.startWriting(); writer.startSession(atSourceTime: .zero)
            let ms = Int64(Date().timeIntervalSince1970 * 1000)
            try? JSONSerialization.data(withJSONObject: ["t0": ms, "fps": fps]).write(to: URL(fileURLWithPath: outURL.path + ".json"))
        }
        if input.isReadyForMoreMediaData {
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTimeSubtract(pts, firstPTS), decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
            if let copy { input.append(copy); frames += 1 }
        }
    }

    func stop() async {
        try? await stream.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.async {
                self.input.markAsFinished()
                self.writer.finishWriting { c.resume() }
            }
        }
        print("stopped: \(frames) frames → \(outURL.path)")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { FileHandle.standardError.write("stream error: \(error)\n".data(using: .utf8)!) }
}

_ = NSApplication.shared  // initialises CoreGraphics (SCK asserts otherwise)
let rec = Recorder()
var sources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { Task { await rec.stop(); exit(0) } }
    s.resume(); sources.append(s)
}
Task {
    do { try await rec.start() } catch { FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }
}
dispatchMain()
