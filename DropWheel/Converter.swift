import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum FileKind {
    case image, video, audio, pdf

    static func of(_ url: URL) -> FileKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }
}

/// Один сектор колеса: во что и каким способом конвертировать.
struct Format {
    enum Target {
        case image(UTType)
        /// passthroughFirst: сначала пробуем переложить дорожки без перекодирования (секунды).
        case video(preset: String, fileType: AVFileType, passthroughFirst: Bool)
        case audioM4A
        case audioPCM(bigEndian: Bool)
        case pdfPages(UTType)
        // Инструменты (колесо по Command)
        case imageResave(quality: Double, scale: CGFloat?, maxSide: Int?, suffix: String)
        /// Обрезка: область выбирается в отдельном окне, см. CropWindow.swift.
        case imageCrop
        case imagesToPDF
        case videoMute
        case pdfMerge
        case pdfSplit
    }

    let label: String
    let ext: String
    let kind: FileKind
    let target: Target
    /// Инструмент, а не смена формата: влияет на текст сообщений.
    var isTool = false
    /// Обрабатывает все файлы разом и даёт один результат (склейка).
    var batch = false
}

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Converter {
    /// Доля готовности от 0 до 1; вызывается не из главного потока.
    typealias Progress = @Sendable (Double) -> Void

    // MARK: - Какие форматы показать для файла

    static func formats(for url: URL) -> [Format] {
        guard let kind = FileKind.of(url) else { return [] }
        let sourceExt = url.pathExtension.lowercased()
        let sourceType = UTType(filenameExtension: sourceExt)

        switch kind {
        case .image:
            let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
            var candidates: [(String, String, UTType)] = [
                ("JPG", "jpg", .jpeg), ("PNG", "png", .png), ("HEIC", "heic", .heic),
                ("TIFF", "tiff", .tiff), ("GIF", "gif", .gif), ("BMP", "bmp", .bmp),
                ("PDF", "pdf", .pdf), ("WEBP", "webp", .webP),
            ]
            if let avif = UTType("public.avif") { candidates.append(("AVIF", "avif", avif)) }
            return candidates
                .filter { writable.contains($0.2.identifier) && $0.2 != sourceType }
                .prefix(8)
                .map { Format(label: $0.0, ext: $0.1, kind: .image, target: .image($0.2)) }

        case .video:
            var list: [Format] = []
            if sourceExt != "mp4" {
                list.append(Format(label: "MP4", ext: "mp4", kind: .video,
                                   target: .video(preset: AVAssetExportPresetHighestQuality, fileType: .mp4, passthroughFirst: true)))
            }
            if sourceExt != "mov" {
                list.append(Format(label: "MOV", ext: "mov", kind: .video,
                                   target: .video(preset: AVAssetExportPresetHighestQuality, fileType: .mov, passthroughFirst: true)))
            }
            list.append(Format(label: "HEVC", ext: "mp4", kind: .video,
                               target: .video(preset: AVAssetExportPresetHEVCHighestQuality, fileType: .mp4, passthroughFirst: false)))
            list.append(Format(label: "1080p", ext: "mp4", kind: .video,
                               target: .video(preset: AVAssetExportPreset1920x1080, fileType: .mp4, passthroughFirst: false)))
            list.append(Format(label: "720p", ext: "mp4", kind: .video,
                               target: .video(preset: AVAssetExportPreset1280x720, fileType: .mp4, passthroughFirst: false)))
            list.append(Format(label: "M4A", ext: "m4a", kind: .video, target: .audioM4A))
            return list

        case .audio:
            let all = [
                Format(label: "M4A", ext: "m4a", kind: .audio, target: .audioM4A),
                Format(label: "WAV", ext: "wav", kind: .audio, target: .audioPCM(bigEndian: false)),
                Format(label: "AIFF", ext: "aiff", kind: .audio, target: .audioPCM(bigEndian: true)),
            ]
            return all.filter { $0.ext != sourceExt && !($0.ext == "aiff" && sourceExt == "aif") }

        case .pdf:
            return [
                Format(label: "JPG", ext: "jpg", kind: .pdf, target: .pdfPages(.jpeg)),
                Format(label: "PNG", ext: "png", kind: .pdf, target: .pdfPages(.png)),
                Format(label: "TIFF", ext: "tiff", kind: .pdf, target: .pdfPages(.tiff)),
            ]
        }
    }

    // MARK: - Какие инструменты показать (колесо по Command)

    static func tools(for urls: [URL]) -> [Format] {
        guard let first = urls.first, let kind = FileKind.of(first) else { return [] }
        let count = urls.filter { FileKind.of($0) == kind }.count
        func tool(_ label: String, _ target: Format.Target, ext: String = "", batch: Bool = false) -> Format {
            Format(label: label, ext: ext, kind: kind, target: target, isTool: true, batch: batch)
        }
        switch kind {
        case .image:
            return [
                tool("Сжать", .imageResave(quality: 0.6, scale: nil, maxSide: nil, suffix: " сжато")),
                tool("Обрезать", .imageCrop),
                tool("50%", .imageResave(quality: 0.85, scale: 0.5, maxSide: nil, suffix: " 50%")),
                tool("1920px", .imageResave(quality: 0.85, scale: nil, maxSide: 1920, suffix: " 1920px")),
                tool("1280px", .imageResave(quality: 0.85, scale: nil, maxSide: 1280, suffix: " 1280px")),
                tool("В PDF", .imagesToPDF, batch: true),
            ]
        case .video:
            return [
                tool("Сжать", .video(preset: AVAssetExportPresetHEVC1920x1080, fileType: .mp4, passthroughFirst: false), ext: "mp4"),
                tool("720p", .video(preset: AVAssetExportPreset1280x720, fileType: .mp4, passthroughFirst: false), ext: "mp4"),
                tool("480p", .video(preset: AVAssetExportPreset640x480, fileType: .mp4, passthroughFirst: false), ext: "mp4"),
                tool("Без звука", .videoMute),
            ]
        case .pdf:
            var list = [tool("Разделить", .pdfSplit), tool("В JPG", .pdfPages(.jpeg), ext: "jpg")]
            if count > 1 { list.insert(tool("Склеить", .pdfMerge, batch: true), at: 0) }
            return list
        case .audio:
            return []
        }
    }

    // MARK: - Конвертация

    /// Инструменты, которым нужны все файлы сразу. Возвращает пути новых файлов.
    static func convertBatch(_ urls: [URL], to format: Format) async throws -> [URL] {
        switch format.target {
        case .imagesToPDF: return [try imagesToPDF(urls)]
        case .pdfMerge: return [try mergePDFs(urls)]
        default: throw ConvertError("этот инструмент работает с одним файлом")
        }
    }

    /// Создаёт копию рядом с оригиналом и возвращает пути новых файлов.
    static func convert(_ url: URL, to format: Format, progress: Progress? = nil) async throws -> [URL] {
        switch format.target {
        case .image(let type):
            return [try convertImage(url, type: type, ext: format.ext)]
        case .video(let preset, let fileType, let passthroughFirst):
            let output = try await exportMedia(url, preset: preset, fileType: fileType, ext: format.ext,
                                               suffix: suffix(for: format, source: url),
                                               passthroughFirst: passthroughFirst, progress: progress)
            let isCompress = format.isTool && format.label == "Сжать"
            return [isCompress ? try keepOnlyIfSmaller(output, than: url) : output]
        case .audioM4A:
            return [try await exportMedia(url, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, ext: "m4a",
                                          suffix: "", passthroughFirst: false, progress: progress)]
        case .audioPCM(let bigEndian):
            return [try convertAudioPCM(url, ext: format.ext, bigEndian: bigEndian)]
        case .pdfPages(let type):
            return try renderPDF(url, type: type, ext: format.ext)
        case .imageResave(let quality, let scale, let maxSide, let suffix):
            let output = try resaveImage(url, quality: quality, scale: scale, maxSide: maxSide, suffix: suffix)
            let isCompress = scale == nil && maxSide == nil
            return [isCompress ? try keepOnlyIfSmaller(output, than: url) : output]
        case .imageCrop:
            throw ConvertError("обрезка открывается в отдельном окне")
        case .videoMute:
            return [try await muteVideo(url, progress: progress)]
        case .pdfSplit:
            return try splitPDF(url)
        case .imagesToPDF, .pdfMerge:
            return try await convertBatch([url], to: format)
        }
    }

    /// Чтобы «video.mp4 → 720p» не называлось так же, как оригинал.
    private static func suffix(for format: Format, source: URL) -> String {
        switch format.label {
        case "HEVC": return " HEVC"
        case "1080p": return " 1080p"
        case "720p": return " 720p"
        case "480p": return " 480p"
        case "Сжать": return " сжато"
        default: return ""
        }
    }

    private static func outputURL(for source: URL, suffix: String = "", ext: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    // MARK: Картинки

    private static func convertImage(_ url: URL, type: UTType, ext: String) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConvertError("не удалось открыть изображение")
        }
        let output = outputURL(for: url, ext: ext)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError("формат \(ext.uppercased()) не поддерживается")
        }
        // Качество для JPG/HEIC; для TIFF просим сжатие LZW (система применяет его не ко всем снимкам).
        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImageDestinationBackgroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],
        ] as CFDictionary

        // JPG, HEIC и TIFF хранят поворот и метаданные снимка, поэтому переносим их как есть.
        // Для остальных форматов разворачиваем пиксели, иначе фото с айфона ляжет на бок.
        if type == .jpeg || type == .heic || type == .tiff {
            CGImageDestinationAddImageFromSource(destination, source, 0, options)
        } else {
            guard let image = uprightImage(from: source) else {
                throw ConvertError("не удалось прочитать изображение")
            }
            CGImageDestinationAddImage(destination, image, options)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError("не удалось сохранить \(ext.uppercased())")
        }
        return output
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    /// Пересохраняет картинку с другим качеством и/или размером. JPG и HEIC остаются в своём формате
    /// при сжатии; при изменении размера формат сохраняется, если система умеет его записывать.
    private static func resaveImage(_ url: URL, quality: Double, scale: CGFloat?, maxSide: Int?, suffix: String) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConvertError("не удалось открыть изображение")
        }
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let sourceType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let resizing = scale != nil || maxSide != nil
        var type = UTType.jpeg
        var ext = "jpg"
        if let sourceType, writable.contains(sourceType.identifier),
           resizing || sourceType == .jpeg || sourceType == .heic {
            type = sourceType
            ext = url.pathExtension
        }

        let size = pixelSize(of: source)
        let longest = max(size.width, size.height)
        var target = longest
        if let scale { target = max(1, Int(CGFloat(longest) * scale)) }
        if let maxSide { target = min(longest, maxSide) }
        guard let image = uprightImage(from: source, maxPixel: target) else {
            throw ConvertError("не удалось прочитать изображение")
        }

        let output = outputURL(for: url, suffix: suffix, ext: ext)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError("формат \(ext.uppercased()) не поддерживается")
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationBackgroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError("не удалось сохранить файл")
        }
        return output
    }

    // MARK: Обрезка

    /// Уменьшенная копия для окна обрезки и полный размер картинки с учётом поворота.
    static func previewImage(_ url: URL, maxPixel: Int) -> (image: CGImage, fullSize: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let size = pixelSize(of: source)
        let longest = max(size.width, size.height)
        guard longest > 0, let image = uprightImage(from: source, maxPixel: min(longest, maxPixel)) else { return nil }
        let scale = CGFloat(longest) / CGFloat(max(image.width, image.height))
        return (image, CGSize(width: (CGFloat(image.width) * scale).rounded(),
                              height: (CGFloat(image.height) * scale).rounded()))
    }

    /// Обрезанная копия. area — область в долях картинки (0…1), начало координат в левом верхнем углу.
    static func cropImage(_ url: URL, to area: CGRect) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = uprightImage(from: source) else {
            throw ConvertError("не удалось открыть изображение")
        }
        let width = CGFloat(full.width), height = CGFloat(full.height)
        let pixels = CGRect(x: (area.minX * width).rounded(), y: (area.minY * height).rounded(),
                            width: (area.width * width).rounded(), height: (area.height * height).rounded())
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixels.width >= 1, pixels.height >= 1, let cropped = full.cropping(to: pixels) else {
            throw ConvertError("область обрезки пустая")
        }

        // Формат оригинала сохраняем, если система умеет его записывать; иначе JPG.
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        var type = UTType.jpeg
        var ext = "jpg"
        if let sourceType = (CGImageSourceGetType(source) as String?).flatMap({ UTType($0) }),
           writable.contains(sourceType.identifier) {
            type = sourceType
            ext = url.pathExtension
        }
        let output = outputURL(for: url, suffix: " обрезано", ext: ext)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError("формат \(ext.uppercased()) не поддерживается")
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImageDestinationBackgroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cropped, options)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError("не удалось сохранить файл")
        }
        return output
    }

    /// Все картинки в один PDF, по странице на картинку.
    private static func imagesToPDF(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw ConvertError("нет файлов") }
        let output = outputURL(for: first, suffix: urls.count > 1 ? " и ещё \(urls.count - 1)" : "", ext: "pdf")
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw ConvertError("не удалось создать PDF")
        }
        var pages = 0
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = uprightImage(from: source) else { continue }
            // 144 точки на дюйм: страница вдвое меньше пикселей картинки.
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
            context.beginPage(mediaBox: &box)
            // Картинка в JPEG-упаковке попадает в PDF сжатой, иначе файл выходит в десятки мегабайт.
            context.draw(jpegBacked(image, quality: 0.85) ?? image, in: box)
            context.endPage()
            pages += 1
        }
        context.closePDF()
        guard pages > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError("не удалось прочитать изображения")
        }
        return output
    }

    private static func jpegBacked(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationBackgroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Для «Сжать»: если копия вышла не меньше оригинала, она бесполезна — убираем её и говорим об этом.
    private static func keepOnlyIfSmaller(_ output: URL, than source: URL) throws -> URL {
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        if size(output) >= size(source) {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError("файл уже сжат, меньше не становится")
        }
        return output
    }

    private static func uprightImage(from source: CGImageSource, maxPixel: Int? = nil) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) > 0 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Видео и звук из видео

    private static func exportMedia(_ url: URL, preset: String, fileType: AVFileType, ext: String,
                                    suffix: String, passthroughFirst: Bool, progress: Progress?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        if fileType == .m4a, try await asset.loadTracks(withMediaType: .audio).isEmpty {
            throw ConvertError("в этом видео нет звука")
        }
        let output = outputURL(for: url, suffix: suffix, ext: ext)
        try await export(asset, to: output, preset: preset, fileType: fileType,
                         passthroughFirst: passthroughFirst, progress: progress)
        return output
    }

    /// Копия видео без звуковой дорожки; картинка не перекодируется.
    private static func muteVideo(_ url: URL, progress: Progress?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let copy = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        guard !composition.tracks.isEmpty else { throw ConvertError("в файле нет видеодорожки") }
        let isMOV = url.pathExtension.lowercased() == "mov"
        let output = outputURL(for: url, suffix: " без звука", ext: isMOV ? "mov" : "mp4")
        try await export(composition, to: output, preset: AVAssetExportPresetHighestQuality,
                         fileType: isMOV ? .mov : .mp4, passthroughFirst: true, progress: progress)
        return output
    }

    /// Запускает экспорт, сообщает о прогрессе и прерывает его, если задачу отменили.
    private static func run(_ session: AVAssetExportSession, to output: URL, as fileType: AVFileType,
                            progress: Progress?) async throws {
        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let current) = state { progress?(current.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try await session.export(to: output, as: fileType)
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()
    }

    private static func export(_ asset: AVAsset, to output: URL, preset: String, fileType: AVFileType,
                               passthroughFirst: Bool, progress: Progress?) async throws {
        let ext = output.pathExtension

        if passthroughFirst, let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            do {
                try await run(session, to: output, as: fileType, progress: progress)
                return
            } catch {
                try? FileManager.default.removeItem(at: output)
                try Task.checkCancellation()
            }
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError("этот файл нельзя конвертировать в \(ext.uppercased())")
        }
        do {
            try await run(session, to: output, as: fileType, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    // MARK: Звук в WAV / AIFF

    private static func convertAudioPCM(_ url: URL, ext: String, bigEndian: Bool) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let output = outputURL(for: url, ext: ext)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: output, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
                throw ConvertError("не удалось прочитать звук")
            }
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try file.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    // MARK: PDF: склеить и разделить

    private static func mergePDFs(_ urls: [URL]) throws -> URL {
        guard urls.count > 1, let first = urls.first else { throw ConvertError("для склейки нужно несколько PDF") }
        let merged = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else { throw ConvertError("не удалось открыть \(url.lastPathComponent)") }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        let output = outputURL(for: first, suffix: " (склеено)", ext: "pdf")
        guard merged.pageCount > 0, merged.write(to: output) else { throw ConvertError("не удалось сохранить PDF") }
        return output
    }

    private static func splitPDF(_ url: URL) throws -> [URL] {
        guard let document = PDFDocument(url: url) else { throw ConvertError("не удалось открыть PDF") }
        guard document.pageCount > 1 else { throw ConvertError("в этом PDF одна страница") }
        var outputs: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let output = outputURL(for: url, suffix: "-\(index + 1)", ext: "pdf")
            guard single.write(to: output) else { throw ConvertError("не удалось сохранить страницу \(index + 1)") }
            outputs.append(output)
        }
        return outputs
    }

    // MARK: PDF в картинки (по файлу на страницу)

    private static func renderPDF(_ url: URL, type: UTType, ext: String) throws -> [URL] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            throw ConvertError("не удалось открыть PDF")
        }
        let pages = document.numberOfPages
        let scale: CGFloat = 2 // 144 точки на дюйм
        var outputs: [URL] = []

        for number in 1...pages {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }
            var size = page.getBoxRect(.cropBox).size
            if page.rotationAngle % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                         rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { continue }

            let output = outputURL(for: url, suffix: pages > 1 ? "-\(number)" : "", ext: ext)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
                throw ConvertError("формат \(ext.uppercased()) не поддерживается")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConvertError("не удалось сохранить страницу \(number)")
            }
            outputs.append(output)
        }
        guard !outputs.isEmpty else { throw ConvertError("в PDF нет страниц для сохранения") }
        return outputs
    }
}
