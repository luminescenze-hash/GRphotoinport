import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum LivePhotoImportError: LocalizedError {
    case stagingFailed(reason: String)
    case imageMetadataFailed(reason: String)
    case videoProcessingFailed(reason: String)
    case libraryRejected(reason: String)
    case notLivePhoto

    var errorDescription: String? {
        switch self {
        case let .stagingFailed(reason):
            return "无法创建临时文件：\(reason)"
        case let .imageMetadataFailed(reason):
            return "处理 JPG 失败：\(reason)"
        case let .videoProcessingFailed(reason):
            return "处理 MOV 失败：\(reason)"
        case let .libraryRejected(reason):
            return "写入相册失败：\(reason)"
        case .notLivePhoto:
            return "已写入相册，但系统未将其识别为实况照片"
        }
    }
}

/// 合成一张 Live Photo 的完整流程：
/// 1. 生成一个 asset identifier（UUID）；
/// 2. 把 identifier 写进 JPG 的 Apple MakerNote（key "17"）；
/// 3. 把同一个 identifier 写进 MOV 的 `com.apple.quicktime.content.identifier`，
///    并补上 `com.apple.quicktime.still-image-time` 定时元数据轨道；
/// 4. 用同一个 PHAssetCreationRequest 把两个文件写进相册。
struct LivePhotoImporter {
    func importPair(movieURL: URL, photoURL: URL) async throws {
        let fileManager = FileManager.default

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("LivePhotoStaging", isDirectory: true)
        try ensureDirectory(stagingRoot)

        let workDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ensureDirectory(workDir)
        defer { try? fileManager.removeItem(at: workDir) }

        let assetIdentifier = UUID().uuidString
        let stillURL = workDir.appendingPathComponent("still.jpg", isDirectory: false)
        let pairedMovieURL = workDir.appendingPathComponent("paired.mov", isDirectory: false)

        try writeStillImage(from: photoURL, to: stillURL, assetIdentifier: assetIdentifier)
        try await writePairedMovie(from: movieURL, to: pairedMovieURL, assetIdentifier: assetIdentifier, photoURL: photoURL)
        try await writeToLibrary(photoURL: stillURL, movieURL: pairedMovieURL)
    }

    // MARK: - JPG：写入 MakerApple 17

    private func writeStillImage(from sourceURL: URL, to destinationURL: URL, assetIdentifier: String) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw LivePhotoImportError.imageMetadataFailed(
                reason: "无法读取「\(sourceURL.lastPathComponent)」"
            )
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any]) ?? [:]
        var makerApple = (properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
        makerApple["17"] = assetIdentifier
        properties[kCGImagePropertyMakerAppleDictionary] = makerApple
        // 元数据需要重新封装；尽量保持原始画质。
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0

        // 优先用 AddImageFromSource（避免整张图解码，通常也更省内存）。
        try writeImage(source: source, decoded: nil, properties: properties, to: destinationURL)

        if makerAppleAssetIdentifier(at: destinationURL) == assetIdentifier {
            return
        }

        // 某些格式下 AddImageFromSource 可能不会写入 MakerApple，
        // 回退到解码后重新编码的方式（参考实现常用的做法）。
        guard let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LivePhotoImportError.imageMetadataFailed(
                reason: "无法解码「\(sourceURL.lastPathComponent)」"
            )
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try writeImage(source: source, decoded: decodedImage, properties: properties, to: destinationURL)

        // 读回校验：如果 ImageIO 没有把 MakerApple 写进去，提前报错，
        // 避免相册导入时报出难以理解的 -1 错误。
        guard makerAppleAssetIdentifier(at: destinationURL) == assetIdentifier else {
            throw LivePhotoImportError.imageMetadataFailed(
                reason: "无法把实况照片标识写入 JPG（该文件可能使用了不支持的色彩/压缩格式）"
            )
        }
    }

    private func writeImage(
        source: CGImageSource,
        decoded: CGImage?,
        properties: [AnyHashable: Any],
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LivePhotoImportError.imageMetadataFailed(reason: "无法创建输出 JPG")
        }

        if let decoded {
            CGImageDestinationAddImage(destination, decoded, properties as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoImportError.imageMetadataFailed(reason: "写入 JPG 元数据失败")
        }
    }

    private func makerAppleAssetIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any],
              let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
              let identifier = makerApple["17"] as? String
        else {
            return nil
        }
        return identifier
    }

    // MARK: - MOV：重封装并写入 Live Photo 元数据

    /// 写 MOV。`shouldBakeRotation` 为 false 时用轨道矩阵声明方向（无损直传）；
    /// 为 true 时先把旋转烘焙进像素，再直传封装元数据（兜底路径）。
    private func writePairedMovie(
        from sourceURL: URL,
        to destinationURL: URL,
        assetIdentifier: String,
        photoURL: URL,
        shouldBakeRotation: Bool = false
    ) async throws {
        // 相机竖拍时 JPG 只靠 EXIF 方向标记，而 MOV 的画面往往是横向像素且没有方向信息；
        // 原样成对写入相册就会出现「静止图竖、视频横」。这里让视频显示方向跟随照片。
        let stillOrientation = stillImageOrientation(at: photoURL)

        var effectiveSourceURL = sourceURL
        if shouldBakeRotation {
            let bakedURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent("baked.mov", isDirectory: false)
            try? FileManager.default.removeItem(at: bakedURL)

            let probe = AVURLAsset(url: sourceURL)
            guard let probeTrack = (try? await probe.loadTracks(withMediaType: .video))?.first else {
                throw LivePhotoImportError.videoProcessingFailed(reason: "MOV 中没有视频轨道")
            }
            let probeTransform = (try? await probeTrack.load(.preferredTransform)) ?? .identity
            let probeSize = (try? await probeTrack.load(.naturalSize)) ?? CGSize(width: 1, height: 1)
            let targetTransform = adjustedVideoTransform(
                source: probeTransform,
                naturalSize: probeSize,
                photoOrientation: stillOrientation
            )
            try await bakeRotationIntoVideo(
                sourceURL: sourceURL,
                destinationURL: bakedURL,
                videoTrack: probeTrack,
                transform: targetTransform,
                naturalSize: probeSize
            )
            effectiveSourceURL = bakedURL
        }

        let asset = AVURLAsset(url: effectiveSourceURL)

        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        let duration: CMTime
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: "无法读取「\(sourceURL.lastPathComponent)」：\(error.localizedDescription)"
            )
        }

        guard let videoTrack = videoTracks.first else {
            throw LivePhotoImportError.videoProcessingFailed(reason: "MOV 中没有视频轨道")
        }

        let videoFormatDescriptions: [CMFormatDescription]
        let videoTransform: CGAffineTransform
        let naturalSize: CGSize
        do {
            videoFormatDescriptions = try await videoTrack.load(.formatDescriptions)
            videoTransform = try await videoTrack.load(.preferredTransform)
            naturalSize = try await videoTrack.load(.naturalSize)
        } catch {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: "无法读取视频信息：\(error.localizedDescription)"
            )
        }

        guard let videoFormatDescription = videoFormatDescriptions.first else {
            throw LivePhotoImportError.videoProcessingFailed(reason: "无法获取视频编码信息")
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        } catch {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: "无法创建输出 MOV：\(error.localizedDescription)"
            )
        }

        // 视频：outputSettings 为 nil 表示直接复用原始压缩数据，不转码。
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatDescription
        )
        videoInput.expectsMediaDataInRealTime = false
        // 烘焙路径的画面像素已经转到位，矩阵必须是单位阵，否则会二次旋转。
        let appliedTransform = shouldBakeRotation
            ? CGAffineTransform.identity
            : adjustedVideoTransform(
                source: videoTransform,
                naturalSize: naturalSize,
                photoOrientation: stillOrientation
            )
        videoInput.transform = appliedTransform
        guard writer.canAdd(videoInput) else {
            throw LivePhotoImportError.videoProcessingFailed(reason: "无法添加视频轨道")
        }
        writer.add(videoInput)

        // 音频：可选。读取失败或写入器不支持时，降级为无声视频。
        var audioInput: AVAssetWriterInput?
        var audioTrack: AVAssetTrack?
        if let candidate = audioTracks.first {
            do {
                let descriptions = try await candidate.load(.formatDescriptions)
                if let audioFormat = descriptions.first {
                    let input = AVAssetWriterInput(
                        mediaType: .audio,
                        outputSettings: nil,
                        sourceFormatHint: audioFormat
                    )
                    input.expectsMediaDataInRealTime = false
                    if writer.canAdd(input) {
                        writer.add(input)
                        audioInput = input
                        audioTrack = candidate
                    }
                }
            } catch {
                // 忽略音频，保留视频。
            }
        }

        // Live Photo 标记所必需的定时元数据轨道：com.apple.quicktime.still-image-time
        let metadataInput: AVAssetWriterInput
        let metadataAdaptor: AVAssetWriterInputMetadataAdaptor
        do {
            let specification: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                    "mdta/com.apple.quicktime.still-image-time" as NSString,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                    "com.apple.metadata.datatype.int8" as NSString
            ]

            var stillFormatDescription: CMMetadataFormatDescription?
            let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [specification] as CFArray,
                formatDescriptionOut: &stillFormatDescription
            )

            guard status == noErr, let stillFormatDescription else {
                throw LivePhotoImportError.videoProcessingFailed(reason: "无法创建静态帧元数据格式")
            }

            metadataInput = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: stillFormatDescription
            )
            metadataInput.expectsMediaDataInRealTime = false

            guard writer.canAdd(metadataInput) else {
                throw LivePhotoImportError.videoProcessingFailed(reason: "无法添加静态帧元数据轨道")
            }

            // adaptor 必须在 startWriting 之前创建。
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
            writer.add(metadataInput)
        } catch {
            if let error = error as? LivePhotoImportError {
                throw error
            }
            throw LivePhotoImportError.videoProcessingFailed(reason: error.localizedDescription)
        }

        // MOV 顶层内容标识，必须与 JPG 的 MakerApple 17 相同。
        let contentIdentifierItem = AVMutableMetadataItem()
        contentIdentifierItem.keySpace = AVMetadataKeySpace.quickTimeMetadata
        contentIdentifierItem.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier.rawValue as NSString
        contentIdentifierItem.value = assetIdentifier as NSString
        contentIdentifierItem.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [contentIdentifierItem as AVMetadataItem]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: "无法读取视频：\(error.localizedDescription)"
            )
        }

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw LivePhotoImportError.videoProcessingFailed(reason: "无法读取视频轨道")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack, audioInput != nil {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        guard reader.startReading() else {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: reader.error?.localizedDescription ?? "无法开始读取视频"
            )
        }

        guard writer.startWriting() else {
            reader.cancelReading()
            throw LivePhotoImportError.videoProcessingFailed(
                reason: writer.error?.localizedDescription ?? "无法开始写入视频"
            )
        }

        writer.startSession(atSourceTime: .zero)

        do {
            try await copyMediaSamples(
                reader: reader,
                writer: writer,
                videoOutput: videoOutput,
                videoInput: videoInput,
                audioOutput: audioOutput,
                audioInput: audioInput
            )

            try await appendStillImageTime(
                to: metadataAdaptor,
                input: metadataInput,
                writer: writer,
                duration: duration
            )

            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            metadataInput.markAsFinished()

            if writer.status == .writing {
                await finishWriting(writer)
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        guard writer.status == .completed else {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: writer.error?.localizedDescription ?? "视频处理未完成"
            )
        }

        // 直传模式下个别系统版本可能不写轨道矩阵，读回确认一次；
        // 方向没生效就把旋转烘焙进像素后重写（只重试一次）。
        if !shouldBakeRotation {
            let matches = await videoTransformMatches(at: destinationURL, expected: appliedTransform)
            if !matches {
                try? FileManager.default.removeItem(at: destinationURL)
                try await writePairedMovie(
                    from: sourceURL,
                    to: destinationURL,
                    assetIdentifier: assetIdentifier,
                    photoURL: photoURL,
                    shouldBakeRotation: true
                )
            }
        }
    }

    /// 同时从视频/音频轨道读取并写入，避免一次把整段视频读进内存。
    private func copyMediaSamples(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?
    ) async throws {
        var videoFinished = false
        var audioFinished = (audioOutput == nil || audioInput == nil)

        while !videoFinished || !audioFinished {
            if Task.isCancelled {
                throw CancellationError()
            }
            if reader.status == .failed {
                throw LivePhotoImportError.videoProcessingFailed(
                    reason: reader.error?.localizedDescription ?? "读取视频失败"
                )
            }
            if writer.status == .failed {
                throw LivePhotoImportError.videoProcessingFailed(
                    reason: writer.error?.localizedDescription ?? "写入视频失败"
                )
            }

            var didWork = false

            if !videoFinished, videoInput.isReadyForMoreMediaData {
                if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                    guard videoInput.append(sampleBuffer) else {
                        throw LivePhotoImportError.videoProcessingFailed(reason: "写入视频帧失败")
                    }
                    didWork = true
                } else {
                    videoFinished = true
                }
            }

            if !audioFinished,
               let audioOutput,
               let audioInput,
               audioInput.isReadyForMoreMediaData {
                if let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sampleBuffer) else {
                        throw LivePhotoImportError.videoProcessingFailed(reason: "写入音频帧失败")
                    }
                    didWork = true
                } else {
                    audioFinished = true
                }
            }

            if !didWork {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        if reader.status == .failed {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: reader.error?.localizedDescription ?? "读取视频失败"
            )
        }
    }

    private func appendStillImageTime(
        to adaptor: AVAssetWriterInputMetadataAdaptor,
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        duration: CMTime
    ) async throws {
        let seconds = CMTimeGetSeconds(duration)
        let stillSeconds = (seconds.isFinite && seconds > 0) ? seconds / 2 : 0
        let stillTime = CMTime(seconds: stillSeconds, preferredTimescale: 600)
        let timeRange = CMTimeRange(
            start: stillTime,
            duration: CMTime(value: 1, timescale: 30)
        )

        let item = AVMutableMetadataItem()
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.key = "com.apple.quicktime.still-image-time" as NSString
        // Live Photo 的约定值：int8 的 0xFF（即 -1）。真正重要的是样本时间戳。
        item.value = NSNumber(value: Int8(-1))
        item.dataType = "com.apple.metadata.datatype.int8"

        let group = AVTimedMetadataGroup(
            items: [item as AVMetadataItem],
            timeRange: timeRange
        )

        while !input.isReadyForMoreMediaData {
            if Task.isCancelled {
                throw CancellationError()
            }
            if writer.status == .failed {
                throw LivePhotoImportError.videoProcessingFailed(
                    reason: writer.error?.localizedDescription ?? "写入视频失败"
                )
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard adaptor.append(group) else {
            throw LivePhotoImportError.videoProcessingFailed(reason: "写入静态帧元数据失败")
        }
    }

    private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - 方向修正

    private static let transformEpsilon: CGFloat = 0.01

    /// 读静止图的 EXIF 方向（1 正常 / 3 旋转 180° / 6 顺时针 90° / 8 逆时针 90°）。
    private func stillImageOrientation(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any],
              let value = properties[kCGImagePropertyOrientation as String] as? NSNumber
        else {
            return 1
        }
        return value.intValue
    }

    /// 源视频自带方向（矩阵非单位阵）时保留原样，否则按照片的 EXIF 方向补旋转。
    private func adjustedVideoTransform(
        source: CGAffineTransform,
        naturalSize: CGSize,
        photoOrientation: Int
    ) -> CGAffineTransform {
        let epsilon = Self.transformEpsilon
        let isSourceIdentity = abs(source.a - 1) < epsilon
            && abs(source.d - 1) < epsilon
            && abs(source.b) < epsilon
            && abs(source.c) < epsilon
        guard isSourceIdentity else { return source }
        return rotationTransform(for: photoOrientation, naturalSize: naturalSize)
    }

    /// EXIF 方向 → 让「横向像素」画面呈现为照片视觉方向所需的旋转矩阵。
    private func rotationTransform(for orientation: Int, naturalSize: CGSize) -> CGAffineTransform {
        let width = abs(naturalSize.width)
        let height = abs(naturalSize.height)
        switch orientation {
        case 3:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 6:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 8:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default:
            return .identity
        }
    }

    /// 旋转后的显示尺寸（仅处理 0/90/180/270 四种正交情形）。
    private func rotatedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let width = abs(naturalSize.width)
        let height = abs(naturalSize.height)
        if abs(transform.b) > 0.5 || abs(transform.c) > 0.5 {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    /// 读回成品，确认轨道方向矩阵确实写进去了。
    private func videoTransformMatches(at url: URL, expected: CGAffineTransform) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let actual = try? await track.load(.preferredTransform)
        else {
            return false
        }
        let epsilon = Self.transformEpsilon
        return abs(actual.a - expected.a) < epsilon
            && abs(actual.b - expected.b) < epsilon
            && abs(actual.c - expected.c) < epsilon
            && abs(actual.d - expected.d) < epsilon
    }

    /// 兜底：用 video composition 把旋转烘焙进像素，输出方向已正确的中间 MOV。
    private func bakeRotationIntoVideo(
        sourceURL: URL,
        destinationURL: URL,
        videoTrack: AVAssetTrack,
        transform: CGAffineTransform,
        naturalSize: CGSize
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LivePhotoImportError.videoProcessingFailed(reason: "无法创建视频导出会话")
        }

        let duration = (try? await asset.load(.duration)) ?? .zero
        let frameRate = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 30)
        let fps = frameRate > 1 ? frameRate : 30

        let composition = AVMutableVideoComposition()
        composition.renderSize = rotatedSize(naturalSize: naturalSize, transform: transform)
        composition.frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        exportSession.videoComposition = composition
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exportSession.exportAsynchronously {
                continuation.resume(returning: ())
            }
        }

        guard exportSession.status == .completed else {
            throw LivePhotoImportError.videoProcessingFailed(
                reason: exportSession.error?.localizedDescription ?? "旋转视频失败"
            )
        }
    }

    // MARK: - 相册

    private func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw LivePhotoImportError.stagingFailed(reason: error.localizedDescription)
        }
    }

    private func writeToLibrary(photoURL: URL, movieURL: URL) async throws {
        final class IdentifierBox: @unchecked Sendable {
            var localIdentifier: String?
        }

        let box = IdentifierBox()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photoURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
                box.localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    let nsError = error as NSError?
                    let code = nsError.map { " [\($0.domain) \($0.code)]" } ?? ""
                    continuation.resume(throwing: LivePhotoImportError.libraryRejected(
                        reason: (error?.localizedDescription ?? "未知错误") + code
                    ))
                }
            })
        }

        // 仅当 App 拥有相册“读取”权限时才做校验。
        // 本 App 默认只申请 add-only 权限，此时无法 fetch，仍以 PhotoKit 的成功回调为准。
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let localIdentifier = box.localIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else {
            return
        }

        if !asset.mediaSubtypes.contains(.photoLive) {
            throw LivePhotoImportError.notLivePhoto
        }
    }
}
