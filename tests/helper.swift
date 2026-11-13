// Помощник для тестов.
//   helper gen <out.mov>   — тестовое видео 1920x1080 со звуком, 6 секунд
//   helper info <файлы…>   — число страниц PDF либо размер кадра, кодек и число звуковых дорожек видео
import AVFoundation
import CoreVideo
import PDFKit

func generate(_ out: URL) async throws {
    let folder = out.deletingLastPathComponent()
    let videoURL = folder.appendingPathComponent("_video.mov")
    let audioURL = folder.appendingPathComponent("_audio.caf")
    for url in [out, videoURL, audioURL] { try? FileManager.default.removeItem(at: url) }
    let seconds = 6

    let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    var audioSettings = audioFormat.settings
    audioSettings[AVLinearPCMIsNonInterleaved] = false
    let audioFile = try AVAudioFile(forWriting: audioURL, settings: audioSettings)
    let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(44_100 * seconds))!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<2 {
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![channel][index] = sin(Float(index) * 0.06) * 0.3
        }
    }
    try audioFile.write(from: buffer)

    let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(30 * seconds) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer!, [])
        let pixels = CVPixelBufferGetBaseAddress(pixelBuffer!)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer!)
        for y in 0..<1080 {
            for x in 0..<1920 {
                let offset = y * rowBytes + x * 4
                pixels[offset] = UInt8((x + frame * 9) & 255)
                pixels[offset + 1] = UInt8((y * 2 + frame * 5) & 255)
                pixels[offset + 2] = UInt8(((x ^ y) + frame * 3) & 255)
                pixels[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
        adaptor.append(pixelBuffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()

    let composition = AVMutableComposition()
    for (url, type) in [(videoURL, AVMediaType.video), (audioURL, AVMediaType.audio)] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: type)[0]
        let duration = try await asset.load(.duration)
        try composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
    }
    let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
    try await session.export(to: out, as: .mov)
    for url in [videoURL, audioURL] { try? FileManager.default.removeItem(at: url) }
}

func info(_ url: URL) async {
    if url.pathExtension.lowercased() == "pdf" {
        print("pages=\(PDFDocument(url: url)?.pageCount ?? -1)")
        return
    }
    let asset = AVURLAsset(url: url)
    let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
    let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    var size = "0x0", codec = "none"
    if let track = video.first, let natural = try? await track.load(.naturalSize),
       let description = try? await track.load(.formatDescriptions).first {
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [UInt8(code >> 24 & 255), UInt8(code >> 16 & 255), UInt8(code >> 8 & 255), UInt8(code & 255)]
        codec = String(bytes: bytes, encoding: .ascii) ?? "?"
        size = "\(Int(natural.width))x\(Int(natural.height))"
    }
    print("size=\(size) codec=\(codec) audio=\(audio.count)")
}

let arguments = CommandLine.arguments
let done = DispatchSemaphore(value: 0)
Task {
    if arguments.count == 3, arguments[1] == "gen" {
        do { try await generate(URL(fileURLWithPath: arguments[2])) } catch { print("gen error: \(error)"); exit(1) }
    } else if arguments.count >= 3, arguments[1] == "info" {
        for path in arguments.dropFirst(2) { await info(URL(fileURLWithPath: path)) }
    } else {
        print("usage: helper gen <out.mov> | helper info <files…>")
        exit(2)
    }
    done.signal()
}
done.wait()
