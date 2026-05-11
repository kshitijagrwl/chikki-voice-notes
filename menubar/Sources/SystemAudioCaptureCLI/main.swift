// chikki-syscap — captures system audio via ScreenCaptureKit and writes WAV.
//
// Usage:  chikki-syscap <output.wav> [--sample-rate N] [--channels N]
//
// Control: writes a WAV header on start, streams PCM frames as they arrive,
// finalizes header on exit. Reads stdin; on a line containing "stop", or on
// SIGINT/SIGTERM, finalizes and exits cleanly. All status messages go to stderr.

import Foundation
import AVFoundation
import ScreenCaptureKit

// MARK: - Logging

func logErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Argument parsing

struct Args {
    var outputPath: String
    var sampleRate: Double = 16000
    var channels: Int = 1
}

func parseArgs() -> Args? {
    let argv = CommandLine.arguments
    guard argv.count >= 2 else {
        logErr("usage: chikki-syscap <output.wav> [--sample-rate N] [--channels N]")
        return nil
    }
    var args = Args(outputPath: argv[1])
    var i = 2
    while i < argv.count {
        switch argv[i] {
        case "--sample-rate":
            if i + 1 < argv.count, let v = Double(argv[i + 1]) {
                args.sampleRate = v
                i += 2
            } else { i += 1 }
        case "--channels":
            if i + 1 < argv.count, let v = Int(argv[i + 1]) {
                args.channels = v
                i += 2
            } else { i += 1 }
        default:
            i += 1
        }
    }
    return args
}

// MARK: - WAV writer (float32 PCM, written incrementally)

final class WAVWriter {
    let url: URL
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 32  // float32
    private var handle: FileHandle!
    private var bytesWritten: UInt32 = 0
    private let lock = NSLock()

    init(url: URL, sampleRate: Double, channels: Int) throws {
        self.url = url
        self.sampleRate = UInt32(sampleRate)
        self.channels = UInt16(channels)

        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "chikki-syscap", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(url.path)"])
        }
        self.handle = h
        try writeHeader(dataSize: 0)
    }

    private func writeHeader(dataSize: UInt32) throws {
        var data = Data()
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let fileSize: UInt32 = 36 + dataSize

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: UInt32(fileSize).leBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: UInt32(16).leBytes)
        data.append(contentsOf: UInt16(3).leBytes)              // 3 = IEEE float
        data.append(contentsOf: UInt16(channels).leBytes)
        data.append(contentsOf: UInt32(sampleRate).leBytes)
        data.append(contentsOf: UInt32(byteRate).leBytes)
        data.append(contentsOf: UInt16(blockAlign).leBytes)
        data.append(contentsOf: UInt16(bitsPerSample).leBytes)
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: UInt32(dataSize).leBytes)

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        if dataSize == 0 {
            // Position cursor at end of header for streaming writes
            try handle.seek(toOffset: 44)
        }
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            bytesWritten += UInt32(data.count)
        } catch {
            logErr("[chikki-syscap] write error: \(error)")
        }
    }

    func finalize() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try writeHeader(dataSize: bytesWritten)
            try handle.synchronize()
            try handle.close()
        } catch {
            logErr("[chikki-syscap] finalize error: \(error)")
        }
    }
}

extension UInt32 {
    var leBytes: [UInt8] {
        return [UInt8(self & 0xff), UInt8((self >> 8) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 24) & 0xff)]
    }
}
extension UInt16 {
    var leBytes: [UInt8] {
        return [UInt8(self & 0xff), UInt8((self >> 8) & 0xff)]
    }
}

// MARK: - Capture engine

@available(macOS 13.0, *)
final class SysCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    let writer: WAVWriter
    let targetSampleRate: Double
    let targetChannels: Int
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    init(writer: WAVWriter, sampleRate: Double, channels: Int) {
        self.writer = writer
        self.targetSampleRate = sampleRate
        self.targetChannels = channels
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "chikki-syscap", code: 2, userInfo: [NSLocalizedDescriptionKey: "no display available"])
        }

        // Include all on-screen apps (system-wide audio mix). We exclude our own process to avoid feedback.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == myPID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(targetSampleRate)
        cfg.channelCount = targetChannels
        // We don't need video frames; minimize cost.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.width = 2
        cfg.height = 2
        cfg.queueDepth = 6

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "chikki-syscap.audio"))
        try await s.startCapture()
        self.stream = s
        logErr("[chikki-syscap] capturing system audio @ \(Int(targetSampleRate))Hz \(targetChannels)ch -> \(writer.url.path)")
    }

    func stop() async {
        if let s = stream {
            do {
                try await s.stopCapture()
            } catch {
                logErr("[chikki-syscap] stopCapture error: \(error)")
            }
            stream = nil
        }
        writer.finalize()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = pcmBuffer(from: sampleBuffer) else { return }

        let converted: AVAudioPCMBuffer
        if pcm.format.sampleRate == outputFormat.sampleRate &&
           pcm.format.channelCount == outputFormat.channelCount &&
           pcm.format.commonFormat == .pcmFormatFloat32 {
            converted = pcm
        } else {
            if converter == nil || sourceFormat != pcm.format {
                sourceFormat = pcm.format
                converter = AVAudioConverter(from: pcm.format, to: outputFormat)
            }
            guard let conv = converter else { return }
            // Allocate output buffer with enough capacity.
            let ratio = outputFormat.sampleRate / pcm.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 1024)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }
            var err: NSError?
            var supplied = false
            let status = conv.convert(to: outBuf, error: &err) { _, statusPtr in
                if supplied {
                    statusPtr.pointee = .noDataNow
                    return nil
                }
                supplied = true
                statusPtr.pointee = .haveData
                return pcm
            }
            if status == .error || err != nil {
                logErr("[chikki-syscap] convert error: \(err?.localizedDescription ?? "?")")
                return
            }
            converted = outBuf
        }

        // Write interleaved float32 bytes.
        guard let ch = converted.floatChannelData else { return }
        let frames = Int(converted.frameLength)
        let channels = Int(converted.format.channelCount)
        let isInterleaved = converted.format.isInterleaved

        if isInterleaved {
            let byteCount = frames * channels * MemoryLayout<Float>.size
            let data = Data(bytes: ch[0], count: byteCount)
            writer.append(data)
        } else {
            // Interleave manually.
            var buffer = [Float](repeating: 0, count: frames * channels)
            for c in 0..<channels {
                let src = ch[c]
                for f in 0..<frames {
                    buffer[f * channels + c] = src[f]
                }
            }
            buffer.withUnsafeBufferPointer { ptr in
                let data = Data(buffer: ptr)
                writer.append(data)
            }
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }
        var asbdCopy = asbd
        guard let format = AVAudioFormat(streamDescription: &asbdCopy) else { return nil }

        var blockBufferOut: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBufferOut
        )
        guard status == noErr else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &audioBufferList) else {
            return nil
        }
        pcm.frameLength = frameCount
        return pcm
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logErr("[chikki-syscap] stream stopped: \(error.localizedDescription)")
    }
}

// MARK: - Main

guard let args = parseArgs() else { exit(2) }

if #available(macOS 13.0, *) {
    let url = URL(fileURLWithPath: args.outputPath)
    let writer: WAVWriter
    do {
        writer = try WAVWriter(url: url, sampleRate: args.sampleRate, channels: args.channels)
    } catch {
        logErr("[chikki-syscap] cannot open output: \(error.localizedDescription)")
        exit(3)
    }

    let capture = SysCapture(writer: writer, sampleRate: args.sampleRate, channels: args.channels)
    let stopSemaphore = DispatchSemaphore(value: 0)
    var stopping = false
    let stopLock = NSLock()

    func requestStop(_ reason: String) {
        stopLock.lock()
        if stopping { stopLock.unlock(); return }
        stopping = true
        stopLock.unlock()
        logErr("[chikki-syscap] stop requested (\(reason))")
        stopSemaphore.signal()
    }

    // SIGINT / SIGTERM
    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSrc.setEventHandler { requestStop("SIGINT") }
    sigintSrc.resume()
    signal(SIGINT, SIG_IGN)

    let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    sigtermSrc.setEventHandler { requestStop("SIGTERM") }
    sigtermSrc.resume()
    signal(SIGTERM, SIG_IGN)

    // stdin reader: any line containing "stop" triggers shutdown. EOF also stops.
    DispatchQueue.global().async {
        let stdin = FileHandle.standardInput
        while true {
            let data = stdin.availableData
            if data.isEmpty {
                requestStop("stdin EOF")
                return
            }
            if let s = String(data: data, encoding: .utf8), s.lowercased().contains("stop") {
                requestStop("stdin stop")
                return
            }
        }
    }

    // Kick off capture.
    Task {
        do {
            try await capture.start()
        } catch {
            logErr("[chikki-syscap] start error: \(error.localizedDescription)")
            requestStop("start failed")
        }
    }

    stopSemaphore.wait()

    let done = DispatchSemaphore(value: 0)
    Task {
        await capture.stop()
        done.signal()
    }
    done.wait()
    logErr("[chikki-syscap] done")
    exit(0)
} else {
    logErr("[chikki-syscap] requires macOS 13+")
    exit(4)
}
