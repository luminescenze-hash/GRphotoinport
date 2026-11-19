import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @Bindable var model: AppModel

    @State private var showClearHistoryConfirm = false
    @State private var showFailures = false
    @State private var showUnmatched = false
    @State private var showDocumentsHint = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    introCard
                    folderCards
                    folderHelpCard
                    statusSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("GRliveinport")
            .toolbar { topBarMenu }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task { model.onAppear() }
            .sheet(isPresented: $showFailures) {
                FailureListView(failures: model.failures)
            }
            .sheet(isPresented: $showUnmatched) {
                UnmatchedListView(
                    movies: model.unmatchedMovies,
                    photos: model.unmatchedPhotos
                )
            }
            .alert("需要相册写入权限", isPresented: $model.permissionAlert) {
                Button("前往设置") { openSettings() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在“设置 → 隐私与安全性 → 照片”中允许 GRliveinport 添加照片。")
            }
            .confirmationDialog(
                "清除导入记录？",
                isPresented: $showClearHistoryConfirm,
                titleVisibility: .visible
            ) {
                Button("清除", role: .destructive) { model.clearHistory() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清除后，之前合成过的文件将不再被自动跳过。")
            }
        }
    }

    // MARK: - 顶部说明

    private var introCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "livephoto")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("GRliveinport · 把 U 盘里的照片和视频合成实况照片")
                    .font(.subheadline.weight(.semibold))
                Text("从外接 U 盘（RICOH GR）根目录的 GRLIFE 读取 MOV，再从同盘 DCIM/100RICOH 读取 JPG，按拍摄时间配对后合成实况照片写入 iPhone 系统相册。时间读不到时退回按文件名配对，子目录递归查找。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 文件夹选择

    private var folderCards: some View {
        VStack(spacing: 12) {
            autoDetectCard

            folderCard(
                title: "GRLIFE 文件夹（MOV）",
                subtitle: "U 盘根目录 / GRLIFE，里面是 .MOV 视频",
                systemImage: "film",
                folder: model.movieFolder,
                role: .movies
            )

            folderCard(
                title: "DCIM/100RICOH 文件夹（JPG）",
                subtitle: "U 盘根目录 / DCIM/100RICOH，里面是 .JPG 照片",
                systemImage: "photo.on.rectangle.angled",
                folder: model.photoFolder,
                role: .photos
            )
        }
    }

    private var autoDetectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                presentRootPicker()
            } label: {
                Label("一键导入 U 盘（先选 MOV，再选 JPG）", systemImage: "wand.and.stars")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isImporting)

            Text("外接 U 盘不支持“原地打开”，选文件夹会整片灰显。这里改为让系统把文件拷贝进 App：先多选 GRLIFE 里的 MOV，选完自动接着弹 JPG 选择（DCIM/100RICOH），随后自动配对。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func folderCard(
        title: String,
        subtitle: String,
        systemImage: String,
        folder: FolderRef?,
        role: FolderRole
    ) -> some View {
        VStack(spacing: 8) {
            FolderCardView(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                folder: folder,
                selectTitle: "选择文件夹",
                action: { presentPicker(for: role) }
            )

            Button {
                presentCopyImport(for: role)
            } label: {
                Label(
                    role == .movies
                        ? "拷贝导入 MOV 文件（文件夹点不动时用）"
                        : "拷贝导入 JPG 文件（文件夹点不动时用）",
                    systemImage: "square.and.arrow.down"
                )
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isImporting)
        }
    }

    private func presentRootPicker() {
        guard !model.isImporting else { return }

        // 外接 U 盘在系统文件提供者上不支持「原地打开」，选文件夹会整片灰显。
        // 因此一键流程不再去选根目录，而是直接用 copy 方式选文件：
        // 先多选 GRLIFE 里的 MOV，选完自动接着多选 DCIM/100RICOH 里的 JPG，
        // 两份副本都落到沙盒 Imported/ 下后自动配对扫描。
        DocumentPickerPresenter.shared.presentMoviePicker(access: .copy) { movieURLs in
            guard let movieURLs, !movieURLs.isEmpty else { return }

            Task { @MainActor in
                model.importCopiedItems(movieURLs, role: .movies)
            }

            Task { @MainActor in
                // 等上一个选择器完全收起，避免 present 冲突。
                try? await Task.sleep(nanoseconds: 400_000_000)
                DocumentPickerPresenter.shared.presentImagePicker(access: .copy) { photoURLs in
                    guard let photoURLs, !photoURLs.isEmpty else { return }
                    Task { @MainActor in
                        _ = model.importCopiedItems(photoURLs, role: .photos)
                    }
                }
            }
        }
    }

    private func presentPicker(for role: FolderRole) {
        guard !model.isImporting else { return }

        DocumentPickerPresenter.shared.presentFolderPicker(access: .inPlace) { urls in
            guard let url = urls?.first else { return }
            Task { @MainActor in
                model.setFolder(url, role: role)
            }
        }
    }

    private func presentCopyImport(for role: FolderRole) {
        guard !model.isImporting else { return }

        let handle: ([URL]?) -> Void = { urls in
            guard let urls, !urls.isEmpty else { return }
            Task { @MainActor in
                _ = model.importCopiedItems(urls, role: role)
            }
        }

        switch role {
        case .movies:
            DocumentPickerPresenter.shared.presentMoviePicker(access: .copy, completion: handle)
        case .photos:
            DocumentPickerPresenter.shared.presentImagePicker(access: .copy, completion: handle)
        }
    }

    /// 选择器使用提示 + App 内文件备用入口。
    /// 外接 U 盘在个别 iOS 版本/文件提供者上无法选中文件夹时，
    /// 用户可以把 GRLIFE/DCIM 复制进 App 的 Documents（Files 里显示为 GRliveinport）再导入。
    private var folderHelpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("选择器提示", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))

            Text("外接 U 盘若不支持“原地打开”，系统选择器里的文件夹会整体灰显、点不动。这时用各卡片下方的“拷贝导入”，直接多选 GRLIFE 里的 MOV 和 DCIM/100RICOH 里的 JPG，系统先复制进 App 再合成。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if !model.useDocumentsFolders() {
                    showDocumentsHint = true
                }
            } label: {
                Label("使用 App 内的 GRLIFE / DCIM（备用）", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(model.isImporting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .alert("备用文件夹未找到", isPresented: $showDocumentsHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请先在“文件”App 中把 U 盘的 GRLIFE 和 DCIM 文件夹复制到“我的 iPhone → GRliveinport”（若显示为 LivePhotoMaker 也可以），再点“使用 App 内的 GRLIFE / DCIM”。")
        }
    }

    // MARK: - 扫描 / 结果

    @ViewBuilder
    private var statusSection: some View {
        if model.isScanning {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在扫描文件夹…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        } else if let error = model.scanError {
            scanErrorCard(error)
        } else if model.hasFolders {
            resultsCard

            if let summary = model.importSummary {
                importResultCard(summary)
            }

            if !model.pairs.isEmpty {
                pairsList
            }

            if !model.unmatchedMovies.isEmpty || !model.unmatchedPhotos.isEmpty {
                unmatchedCard
            }

            if model.ignoredDuplicateMovies + model.ignoredDuplicatePhotos > 0 {
                duplicateNote
            }
        }
    }

    private func scanErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("无法扫描文件夹", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("重新扫描") { model.scan() }
                .font(.footnote.weight(.medium))
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("匹配结果", systemImage: "photo.stack")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    model.scan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(model.isImporting)
            }

            HStack(spacing: 10) {
                statTile(value: model.pairs.count, label: "可合成", tint: .green)
                statTile(value: model.unmatchedMovies.count, label: "缺 JPG", tint: .orange)
                statTile(value: model.unmatchedPhotos.count, label: "缺 MOV", tint: .gray)
            }

            if model.pairs.isEmpty {
                Text("没有找到能配对的 MOV 与 JPG。配对依据是拍摄时间（相差 8 秒内视为同一次拍摄）；两边时间都读不到时，才退回按去掉扩展名后的同名文件匹配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.historySkippedCount > 0 {
                Text("其中 \(model.historySkippedCount) 对之前已合成过，默认会自动跳过。可在右上角菜单里调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statTile(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func importResultCard(_ summary: ImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("本次合成完成", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            HStack(spacing: 8) {
                resultPill(title: "成功", value: summary.success, tint: .green)
                resultPill(title: "失败", value: summary.failure, tint: .red)
                resultPill(title: "跳过", value: summary.skipped, tint: .gray)
            }

            if !model.failures.isEmpty {
                Button {
                    showFailures = true
                } label: {
                    Label("查看失败详情", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func resultPill(title: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.1), in: Capsule())
    }

    private var pairsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件列表（\(model.pairs.count)）")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 2)

            LazyVStack(spacing: 8) {
                ForEach(model.pairs) { pair in
                    PairRowView(
                        pair: pair,
                        wasImportedBefore: model.wasImported(pair)
                    )
                    .padding(10)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
            }
        }
    }

    private var unmatchedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("有未匹配的文件")
                    .font(.footnote.weight(.medium))
                Text("\(model.unmatchedMovies.count) 个 MOV、\(model.unmatchedPhotos.count) 个 JPG 找不到时间相近的对象")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("查看") { showUnmatched = true }
                .font(.caption)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var duplicateNote: some View {
        Text("已忽略 \(model.ignoredDuplicateMovies) 个重名 MOV、\(model.ignoredDuplicatePhotos) 个重名 JPG；每个文件名只处理路径层级最浅的一个文件。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部操作栏

    @ViewBuilder
    private var bottomBar: some View {
        if model.hasFolders, !model.isScanning, !model.pairs.isEmpty {
            VStack(spacing: 10) {
                if model.isImporting {
                    ProgressView(value: model.importProgress.fraction)

                    HStack(spacing: 6) {
                        Text(model.currentPairName ?? "正在合成…")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(model.importProgress.done)/\(model.importProgress.total)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button {
                        model.cancelImport()
                    } label: {
                        Text("取消")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        model.startImport()
                    } label: {
                        Label(
                            "合成 \(model.importablePairs.count) 张实况照片",
                            systemImage: "wand.and.stars"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.importablePairs.isEmpty)

                    Text(footerHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
    }

    private var footerHint: String {
        if model.importablePairs.isEmpty {
            return model.historySkippedCount > 0
                ? "所有可合成文件都已合成过"
                : "没有可合成的文件"
        }
        if model.historySkippedCount > 0 {
            return "已自动跳过 \(model.historySkippedCount) 对之前合成过的文件"
        }
        return "合成过程中请保持 App 在前台，并确保 U 盘连接稳定"
    }

    // MARK: - 菜单

    @ToolbarContentBuilder
    private var topBarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: $model.skipImported) {
                    Label("跳过已合成过的文件", systemImage: "clock.arrow.circlepath")
                }

                Divider()

                Button(role: .destructive) {
                    showClearHistoryConfirm = true
                } label: {
                    Label("清除导入记录", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .disabled(model.isImporting)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 失败详情

private struct FailureListView: View {
    let failures: [ImportFailure]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if failures.isEmpty {
                    ContentUnavailableView("没有失败记录", systemImage: "checkmark.circle")
                } else {
                    List(failures) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.name)
                                .font(.subheadline.weight(.semibold))
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("失败详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 未匹配文件

private struct UnmatchedListView: View {
    let movies: [FoundFile]
    let photos: [FoundFile]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if movies.isEmpty {
                        Text("没有未匹配的 MOV")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(movies) { file in
                            fileRow(file, kind: "MOV")
                        }
                    }
                } header: {
                    Text("没有可配对 JPG 的 MOV（\(movies.count)）")
                } footer: {
                    Text("这些 MOV 在 DCIM 中找不到拍摄时间相近的 JPG，也没有同名文件可配。")
                }

                Section {
                    if photos.isEmpty {
                        Text("没有未匹配的 JPG")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(photos) { file in
                            fileRow(file, kind: "JPG")
                        }
                    }
                } header: {
                    Text("没有可配对 MOV 的 JPG（\(photos.count)）")
                } footer: {
                    Text("这些 JPG 在 GRLIFE 中找不到拍摄时间相近的 MOV，也没有同名文件可配。")
                }
            }
            .navigationTitle("未匹配文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fileRow(_ file: FoundFile, kind: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(kind)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

