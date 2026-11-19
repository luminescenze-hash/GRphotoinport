import Foundation

// MARK: - 文件夹角色

enum FolderRole: String, CaseIterable, Identifiable, Sendable {
    case movies
    case photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "GRLIFE 文件夹"
        case .photos: return "DCIM 文件夹"
        }
    }
}

// MARK: - 扫描得到的文件

struct FoundFile: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// 去掉扩展名后的文件名，配对失败时作为兜底依据。
    let stem: String
    /// 相对于所选根目录的路径，用于界面展示。
    let relativePath: String
    let size: Int64
    /// 拍摄时间（视频/照片元数据优先，其次文件时间），只用于按时间配对与界面展示。
    /// 始终是「本地墙上时间」，与 EXIF 时间的解析基准保持一致。
    let captureTime: Date?

    /// 同一拍摄时间的多种可能解释（例如「相机把本地时间写进容器当作 UTC」和「写入的是真 UTC」）。
    /// 按时间配对时任一解释落在容差内即视为同一次拍摄，用来吸收时区基准差异。
    let captureTimeCandidates: [Date]

    var id: String { url.path }

    init(
        url: URL,
        name: String,
        stem: String,
        relativePath: String,
        size: Int64,
        captureTime: Date? = nil,
        captureTimeCandidates: [Date] = []
    ) {
        self.url = url
        self.name = name
        self.stem = stem
        self.relativePath = relativePath
        self.size = size
        self.captureTime = captureTime
        self.captureTimeCandidates = captureTimeCandidates
    }

    /// 参与时间配对的时间点集合（只含元数据里的拍摄时间，不含文件系统时间）。
    /// 为空表示这个文件读不到拍摄时间，只能按文件名兜底。
    var pairingTimes: [Date] {
        captureTimeCandidates
    }

    /// 读取到更准确的元数据时间后，生成一份替换时间的新值。
    func withCaptureTime(_ time: Date?) -> FoundFile {
        withCaptureTimes(primary: time, candidates: time.map { [$0] } ?? [])
    }

    /// 用元数据时间与它的多种解释替换当前值。
    func withCaptureTimes(primary: Date?, candidates: [Date]) -> FoundFile {
        FoundFile(
            url: url,
            name: name,
            stem: stem,
            relativePath: relativePath,
            size: size,
            captureTime: primary ?? captureTime,
            captureTimeCandidates: candidates.isEmpty ? captureTimeCandidates : candidates
        )
    }
}

// MARK: - 配对结果

enum PairImportStatus: Equatable, Sendable {
    case pending
    case importing
    case imported
    case failed(String)
}

struct MediaPair: Identifiable, Equatable, Sendable {
    let stem: String
    let movie: FoundFile
    let photo: FoundFile
    var status: PairImportStatus = .pending

    var id: String { "\(movie.url.path)|\(photo.url.path)" }
}

// MARK: - 导入进度与结果

struct ImportProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(done) / Double(total))
    }
}

struct ImportFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let message: String
}

struct ImportSummary: Identifiable, Equatable, Sendable {
    let id = UUID()
    let success: Int
    let failure: Int
    let skipped: Int
}
