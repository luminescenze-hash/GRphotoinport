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

    /// 一组「文件索引 + 该文件所有可能的时间解释」，用于按时间配对。
    private typealias TimedFile = (index: Int, times: [Date])

    /// 时间配对的候选：一对「视频-照片」的时间差。
    private struct TimeCandidate {
        let delta: TimeInterval
        let movie: Int
        let photo: Int
    }

    /// 在一批「视频时间」与「照片时间」之间做一对一配对：
    /// 每个文件可带多个时间解释，任一解释落在容差内即成为候选，取最小差值参与排序；
    /// 时间差最小优先，差值相同按电影索引、照片索引稳定排序，保证结果可复现。
    private static func timeMatches(movieTimes: [TimedFile], photoTimes: [TimedFile]) -> [(movie: Int, photo: Int)] {
        var candidates: [TimeCandidate] = []

        for movie in movieTimes {
            for photo in photoTimes {
                var best: TimeInterval?
                for movieTime in movie.times {
                    for photoTime in photo.times {
                        let delta = abs(movieTime.timeIntervalSince(photoTime))
                        guard delta <= timeTolerance else { continue }
                        if best == nil || delta < (best ?? .greatestFiniteMagnitude) {
                            best = delta
                        }
                    }
                }
                guard let delta = best else { continue }
                candidates.append(TimeCandidate(delta: delta, movie: movie.index, photo: photo.index))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.delta != rhs.delta { return lhs.delta < rhs.delta }
            if lhs.movie != rhs.movie { return lhs.movie < rhs.movie }
            return lhs.photo < rhs.photo
        }

        var usedMovies = Set<Int>()
        var usedPhotos = Set<Int>()
        var matches: [(movie: Int, photo: Int)] = []

        for candidate in candidates {
            if usedMovies.contains(candidate.movie) || usedPhotos.contains(candidate.photo) { continue }
            usedMovies.insert(candidate.movie)
            usedPhotos.insert(candidate.photo)
            matches.append((candidate.movie, candidate.photo))
        }

        return matches
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

        // 只有真正读到元数据时间的文件才参与时间配对；读不到的留到下一步按文件名兜底，
        // 避免「拷贝时间恰好相近」这类伪时间造成错配。
        let metadataMovieTimes = candidateMovies.enumerated()
            .filter { !$0.element.pairingTimes.isEmpty }
            .map { (index: $0.offset, times: $0.element.pairingTimes) }
        let metadataPhotoTimes = candidatePhotos.enumerated()
            .filter { !$0.element.pairingTimes.isEmpty }
            .map { (index: $0.offset, times: $0.element.pairingTimes) }

        var usedMovies = Set<Int>()
        var usedPhotos = Set<Int>()

        for match in timeMatches(movieTimes: metadataMovieTimes, photoTimes: metadataPhotoTimes) {
            usedMovies.insert(match.movie)
            usedPhotos.insert(match.photo)
            pairs.append(MediaPair(stem: candidateMovies[match.movie].stem,
                                   movie: candidateMovies[match.movie],
                                   photo: candidatePhotos[match.photo]))
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
            let times = await videoCaptureTimes(file.url)
            if times.isEmpty {
                result.append(file)
            } else {
                result.append(file.withCaptureTimes(primary: times.first, candidates: times))
            }
        }
        return result
    }

    /// 图片直接同步读 EXIF，成本很低（只读文件头），不需要异步。
    private static func attachingPhotoCaptureTimes(_ files: [FoundFile]) -> [FoundFile] {
        files.map { file in
            let times = photoCaptureTimes(file.url)
            if times.isEmpty { return file }
            return file.withCaptureTimes(primary: times.first, candidates: times)
        }
    }

    /// 视频拍摄时间的全部可能解释：优先 QuickTime 的 creationdate 元数据，其次 AVAsset.creationDate。
    private static func videoCaptureTimes(_ url: URL) async -> [Date] {
        let asset = AVURLAsset(url: url)

        if let items = try? await asset.load(.metadata) {
            for item in items {
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                let rawKey = (item.key as? String)?.lowercased() ?? ""
                let matched = identifier.contains("creationdate") || identifier.contains("creation_date")
                    || rawKey.contains("creationdate") || rawKey.contains("creation_date")
                guard matched else { continue }

                // 带时区的字面量（如 2026-11-19T16:11:07+0800）按本地挂钟解释优先。
                let loadedString: String? = try? await item.load(.stringValue)
                if let raw = loadedString, let date = parseQuickTimeDate(raw) {
                    let interpretations = timeInterpretations(of: date, preferUTC: false)
                    if !interpretations.isEmpty { return interpretations }
                }

                let loadedDate: Date? = try? await item.load(.dateValue)
                if let date = loadedDate {
                    let interpretations = timeInterpretations(of: date, preferUTC: false)
                    if !interpretations.isEmpty { return interpretations }
                }
            }
        }

        if let loadedItem = try? await asset.load(.creationDate), let date = loadedItem.dateValue {
            // 容器头（moov/mvhd）里的 creation date 绝大多数相机写的是
            // 「拍摄时的本地钟面时间，但按 UTC 记录」，所以 UTC 解释排在最前面。
            return timeInterpretations(of: date, preferUTC: true)
        }

        return []
    }

    /// 图片拍摄时间：EXIF DateTimeOriginal 优先，其次 TIFF DateTime。
    private static func photoCaptureTimes(_ url: URL) -> [Date] {
        guard let date = photoCaptureTime(url) else { return [] }
        // EXIF 时间不带时区，按本地时区解析得到的钟面时间就是相机当时显示的时间，只保留这一种解释。
        return [date]
    }

    /// 读取 EXIF/TIFF 里的原始拍摄时间。
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

    /// 把 UTC 分量当成墙上时间：相机常把「本地钟面时间」直接写进容器并标为 UTC
    /// （例如 16:11:07 的拍摄在 mvhd 里就是 16:11:07Z），这种解释下要点是丢掉时区换算。
    private static func utcWallClock(_ date: Date) -> Date {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return Calendar.current.date(from: components) ?? date
    }

    /// 同一个绝对时刻的两种可能解释：
    /// 1) 按本地时区显示的墙上时间（元数据确实是带时区的真 UTC 时正确）；
    /// 2) 把 UTC 分量直接当墙上时间（相机把本地时间当 UTC 写进容器时正确）。
    /// 两种都作为候选参与配对，任一对上即可，避免时区基准不同导致整批都配不上。
    private static func timeInterpretations(of date: Date, preferUTC: Bool) -> [Date] {
        let local = localWallClock(date)
        let utc = utcWallClock(date)
        if abs(local.timeIntervalSince(utc)) < 1 {
            return [local]
        }
        return preferUTC ? [utc, local] : [local, utc]
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
