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
    /// 拍摄时间（视频/照片元数据优先，其次文件时间），只用于按时间配对。
    /// 始终是「本地墙上时间」，与 EXIF 时间的解析基准保持一致。
    let captureTime: Date?

    var id: String { url.path }

    init(
        url: URL,
        name: String,
        stem: String,
        relativePath: String,
        size: Int64,
        captureTime: Date? = nil
    ) {
        self.url = url
        self.name = name
        self.stem = stem
        self.relativePath = relativePath
        self.size = size
        self.captureTime = captureTime
    }

    /// 读取到更准确的元数据时间后，生成一份替换时间的新值。
    func withCaptureTime(_ time: Date?) -> FoundFile {
        FoundFile(
            url: url,
            name: name,
            stem: stem,
            relativePath: relativePath,
            size: size,
            captureTime: time ?? captureTime
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
