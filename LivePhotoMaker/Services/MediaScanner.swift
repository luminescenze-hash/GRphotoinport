import AVFoundation
import Foundation
import ImageIO

struct ScanOutcome: Sendable {
    var pairs: [MediaPair] = []
    var unmatchedMovies: [FoundFile] = []
    var unmatchedPhotos: [FoundFile] = []
    var ignoredDuplicateMovies = 0
    var ignoredDuplicatePhotos = 0
    /// 通过拍摄时间配对成功的数量（其余靠文件名兜底）。
    var timeMatchedCount = 0
}

enum MediaScanError: LocalizedError {
    case cannotEnumerate(folder: String)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate(let folder):
            return "无法读取文件夹「\(folder)」。请确认 U 盘仍然连接，并重新选择文件夹。"
        }
    }
}

enum MediaScanner {
    /// 目前按需求只匹配 MOV 与 JPG/JPEG。
    /// 如需支持 HEIC，把 "heic" 加入 photoExtensions 即可。
    static let movieExtensions: Set<String> = ["mov"]
    static let photoExtensions: Set<String> = ["jpg", "jpeg"]

    /// 按时间配对允许的最大时间差（秒）。
    /// 相机同一次拍摄生成的 MOV 与 JPG 拍摄时间通常同秒；exFAT/FAT 的时间戳粒度是 2 秒，
    /// 再叠加拷贝过程可能带来的偏移，这里留 8 秒余量。
    static let timeTolerance: TimeInterval = 8

    /// 时间配对候选：一对「视频-照片」的时间差。
    private struct TimeCandidate {
        let delta: TimeInterval
        let movieIndex: Int
        let photoIndex: Int
        let sameStem: Bool
    }

    /// U 盘上常见的系统目录，直接跳过。
    private static let ignoredDirectoryNames: Set<String> = [
        "$recycle.bin",
        "system volume information",
        ".trashes",
        ".spotlight-v100",
        ".fseventsd"
    ]

    static func scan(moviesRoot: URL, photosRoot: URL) async throws -> ScanOutcome {
        let rawMovies = try collectFiles(in: moviesRoot, extensions: movieExtensions)
        let rawPhotos = try collectFiles(in: photosRoot, extensions: photoExtensions)

        let movies = await attachingCaptureTimes(rawMovies)
        let photos = attachingPhotoCaptureTimes(rawPhotos)

        // 同一个文件名出现多次时，只取路径层级最浅的一个（例如优先 DCIM 根目录），
        // 避免不同子目录里的同名文件造成歧义。该去重同时用于「文件名兜底配对」。
        var movieByStem: [String: FoundFile] = [:]
        var duplicateMovies = 0
        for movie in movies.sorted(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }) {
            let key = movie.stem.lowercased()
            if movieByStem[key] == nil {
                movieByStem[key] = movie
            } else {
                duplicateMovies += 1
            }
        }

        var photoByStem: [String: FoundFile] = [:]
        var duplicatePhotos = 0
        for photo in photos.sorted(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }) {
            let key = photo.stem.lowercased()
            if photoByStem[key] == nil {
                photoByStem[key] = photo
            } else {
                duplicatePhotos += 1
            }
        }

        let candidateMovies = movieByStem.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let candidatePhotos = photoByStem.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var pairs: [MediaPair] = []
        var timeMatchedCount = 0

        // MARK: 第一步：按拍摄时间配对

        // 只有两边都拿到了拍摄时间的文件才参与；其余进入下一步按文件名兜底，
        // 避免「一个有时间、一个没时间」时产生错配。
        let timedMovies = candidateMovies.enumerated().filter { $0.element.captureTime != nil }
        let timedPhotoIndices = candidatePhotos.enumerated()
            .filter { $0.element.captureTime != nil }
            .sorted { ($0.element.captureTime ?? .distantPast) < ($1.element.captureTime ?? .distantPast) }
        let photoTimes = timedPhotoIndices.map { $0.element.captureTime ?? .distantPast }

        var candidates: [TimeCandidate] = []
        for (movieIndex, movie) in timedMovies {
            guard let movieTime = movie.captureTime else { continue }
            let lower = movieTime.addingTimeInterval(-timeTolerance)
            let upper = movieTime.addingTimeInterval(timeTolerance)

            var position = firstIndex(of: lower, in: photoTimes)
            while position < photoTimes.count, photoTimes[position] <= upper {
                let photoEntry = timedPhotoIndices[position]
                let photo = photoEntry.element
                if let photoTime = photo.captureTime {
                    candidates.append(TimeCandidate(
                        delta: abs(movieTime.timeIntervalSince(photoTime)),
                        movieIndex: movieIndex,
                        photoIndex: photoEntry.offset,
                        sameStem: movie.stem.lowercased() == photo.stem.lowercased()
                    ))
                }
                position += 1
            }
        }

        // 时间差最小优先；时间差相同时同名优先，再按文件名稳定排序，保证结果可复现。
        candidates.sort { lhs, rhs in
            if lhs.delta != rhs.delta { return lhs.delta < rhs.delta }
            if lhs.sameStem != rhs.sameStem { return lhs.sameStem && !rhs.sameStem }
            let lName = candidateMovies[lhs.movieIndex].name
            let rName = candidateMovies[rhs.movieIndex].name
            if lName != rName { return lName.localizedStandardCompare(rName) == .orderedAscending }
            return candidatePhotos[lhs.photoIndex].name.localizedStandardCompare(candidatePhotos[rhs.photoIndex].name) == .orderedAscending
        }

        var usedMovies = Set<Int>()
        var usedPhotos = Set<Int>()

        for candidate in candidates {
            if usedMovies.contains(candidate.movieIndex) { continue }
            if usedPhotos.contains(candidate.photoIndex) { continue }

            usedMovies.insert(candidate.movieIndex)
            usedPhotos.insert(candidate.photoIndex)

            let movie = candidateMovies[candidate.movieIndex]
            let photo = candidatePhotos[candidate.photoIndex]
            pairs.append(MediaPair(stem: movie.stem, movie: movie, photo: photo))
            timeMatchedCount += 1
        }

        // MARK: 第二步：时间不可用的文件按文件名兜底配对

        var remainingMovies: [FoundFile] = []
        for (index, movie) in candidateMovies.enumerated() where !usedMovies.contains(index) {
            remainingMovies.append(movie)
        }
        var remainingPhotos: [FoundFile] = []
        for (index, photo) in candidatePhotos.enumerated() where !usedPhotos.contains(index) {
            remainingPhotos.append(photo)
        }

        var photoByStemRemaining: [String: FoundFile] = [:]
        for photo in remainingPhotos {
            let key = photo.stem.lowercased()
            if photoByStemRemaining[key] == nil {
                photoByStemRemaining[key] = photo
            }
        }

        var unmatchedMovies: [FoundFile] = []
        var consumedPhotoStems = Set<String>()

        for movie in remainingMovies {
            let key = movie.stem.lowercased()
            if let photo = photoByStemRemaining[key], !consumedPhotoStems.contains(key) {
                consumedPhotoStems.insert(key)
                pairs.append(MediaPair(stem: movie.stem, movie: movie, photo: photo))
            } else {
                unmatchedMovies.append(movie)
            }
        }

        let unmatchedPhotos = remainingPhotos
            .filter { !consumedPhotoStems.contains($0.stem.lowercased()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        pairs.sort { $0.stem.localizedStandardCompare($1.stem) == .orderedAscending }

        return ScanOutcome(
            pairs: pairs,
            unmatchedMovies: unmatchedMovies.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            unmatchedPhotos: unmatchedPhotos,
            ignoredDuplicateMovies: duplicateMovies,
            ignoredDuplicatePhotos: duplicatePhotos,
            timeMatchedCount: timeMatchedCount
        )
    }

    // MARK: - 拍摄时间

    /// 读取每个文件的拍摄时间：视频优先用容器元数据，兜底用文件系统时间。
    private static func attachingCaptureTimes(_ files: [FoundFile]) async -> [FoundFile] {
        var result: [FoundFile] = []
        result.reserveCapacity(files.count)
        for file in files {
            let time = await videoCaptureTime(file.url) ?? file.captureTime
            result.append(file.withCaptureTime(time))
        }
        return result
    }

    /// 图片直接同步读 EXIF，成本很低（只读文件头），不需要异步。
    private static func attachingPhotoCaptureTimes(_ files: [FoundFile]) -> [FoundFile] {
        files.map { file in
            file.withCaptureTime(photoCaptureTime(file.url) ?? file.captureTime)
        }
    }

    /// 视频拍摄时间：优先 QuickTime 的 creationdate 元数据，其次 AVAsset.creationDate。
    private static func videoCaptureTime(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)

        if let items = try? await asset.load(.metadata) {
            for item in items {
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                let rawKey = (item.key as? String)?.lowercased() ?? ""
                let matched = identifier.contains("creationdate") || identifier.contains("creation_date")
                    || rawKey.contains("creationdate") || rawKey.contains("creation_date")
                guard matched else { continue }

                let loadedDate: Date? = try? await item.load(.dateValue)
                if let date = loadedDate {
                    return localWallClock(date)
                }
                let loadedString: String? = try? await item.load(.stringValue)
                if let raw = loadedString, let date = parseQuickTimeDate(raw) {
                    return localWallClock(date)
                }
            }
        }

        if let loadedItem = try? await asset.load(.creationDate), let date = loadedItem.dateValue {
            return localWallClock(date)
        }

        return nil
    }

    /// 图片拍摄时间：EXIF DateTimeOriginal 优先，其次 TIFF DateTime。
    private static func photoCaptureTime(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let exifKey = kCGImagePropertyExifDictionary as String
        let tiffKey = kCGImagePropertyTIFFDictionary as String

        if let exif = properties[exifKey] as? [String: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
           let date = parseExifDate(raw) {
            return date
        }

        if let tiff = properties[tiffKey] as? [String: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime as String] as? String,
           let date = parseExifDate(raw) {
            return date
        }

        return nil
    }

    /// EXIF 时间形如 `2025:05:01 10:00:00`，不带时区，按本地时区解析即为「墙上时间」。
    private static func parseExifDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: trimmed)
    }

    /// QuickTime creationdate 形如 `2025-05-01T10:00:00+0800`。
    private static func parseQuickTimeDate(_ raw: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd HH:mm:ss Z"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// 把绝对时刻换成「本地墙上时间」：视频元数据通常是 UTC 基准，
    /// 而 EXIF 时间是本地时间且不带时区，两边必须统一到同一基准才能比较。
    private static func localWallClock(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func firstIndex(of value: Date, in sortedDates: [Date]) -> Int {
        var low = 0
        var high = sortedDates.count
        while low < high {
            let mid = (low + high) / 2
            if sortedDates[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - 递归扫描

    private static func collectFiles(in root: URL, extensions: Set<String>) throws -> [FoundFile] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw MediaScanError.cannotEnumerate(folder: root.lastPathComponent)
        }

        var files: [FoundFile] = []
        for case let url as URL in enumerator {
            let lowercasedComponents = url.pathComponents.map { $0.lowercased() }
            if lowercasedComponents.contains(where: { ignoredDirectoryNames.contains($0) }) {
                continue
            }

            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }

            let name = url.lastPathComponent
            let stem = (name as NSString).deletingPathExtension

            var relativePath = url.path
            if relativePath.hasPrefix(root.path) {
                relativePath = String(relativePath.dropFirst(root.path.count))
            }
            relativePath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // 拷贝进沙盒后创建时间会变成拷贝时间，修改时间通常保留，所以修改时间优先。
            let fileDate = values.contentModificationDate ?? values.creationDate

            files.append(FoundFile(
                url: url,
                name: name,
                stem: stem,
                relativePath: relativePath,
                size: Int64(values.fileSize ?? 0),
                captureTime: fileDate.map(localWallClock)
            ))
        }

        return files
    }
}
