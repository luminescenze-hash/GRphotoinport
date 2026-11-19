# GRliveinport（实况照片合成）

一个 iOS 17+ 的 SwiftUI App：读取外接 USB 存储设备的两个文件夹——

- `GRLIFE/**.MOV`（视频）
- `DCIM/**.JPG`（照片）

按“去掉扩展名后的同名文件”配对（忽略大小写），把每一对 JPG + MOV 合成为一张 **Live Photo（实况照片）**，并直接写入系统相册。

```
U 盘根目录/
├── GRLIFE/
│   ├── IMG_0001.MOV
│   └── IMG_0002.MOV
└── DCIM/
    ├── 100APPLE/
    │   └── IMG_0001.JPG
    └── IMG_0002.JPG
```

`IMG_0001.MOV` ↔ `IMG_0001.JPG`，`DCIM` 的子目录会被递归扫描。

---

## 一、实现方案

### 1. 访问外接 U 盘

iOS App 运行在沙盒里，不能直接用 `/Volumes/...` 之类的路径读 U 盘。正确做法是：

1. 用 `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)` 弹出系统“文件”选择器；
2. 用户在“文件”里进入 U 盘，点进 `GRLIFE` / `DCIM` 文件夹，再点右上角“打开”；
3. 拿到的 URL 是 **security-scoped URL**，调用 `startAccessingSecurityScopedResource()` 后才能枚举、读取；
4. 把 URL 的 bookmark 存到 `UserDefaults`，下次启动时恢复访问（U 盘未连接或书签失效时重新选择即可）。

为了避免“选择器嵌在 SwiftUI sheet 里导致文件夹选不了/看不到打开按钮”，
`DocumentPickerPresenter` 直接用 UIKit 从当前 window 的顶层 ViewController **全屏 present** 系统选择器。

> **备用方案**：如果某个 iOS 版本 / U 盘的文件提供者仍然无法选中文件夹，
> 可以先把 U 盘里的 `GRLIFE`、`DCIM` 复制到“文件”App 的
> **我的 iPhone → GRliveinport**（若显示为 LivePhotoMaker 也可以），再点 App 里的“使用 App 内的 GRLIFE / DCIM（备用）”。
> `UIFileSharingEnabled` 和 `LSSupportsOpeningDocumentsInPlace` 已在 `Config/Info.plist` 打开。

> 为什么分两次选文件夹？
> iOS 只授权“用户选中的文件夹及其子目录”，没有授权父目录 / 兄弟目录的能力。因此 App 分别让你选 `GRLIFE` 和 `DCIM`，而不是只选 U 盘根目录（系统选择器通常也不允许选中卷根）。

### 2. 扫描与配对

`FileManager.enumerator(at:includingPropertiesForKeys:options:)` 递归枚举两个文件夹：

- `GRLIFE` 中只收集 `.mov`；
- `DCIM` 中只收集 `.jpg` / `.jpeg`；
- 用 `文件名去掉扩展名后小写` 作为 key 配对；
- 同名文件出现多次时，取路径层级最浅的一个；
- 自动跳过 `$RECYCLE.BIN`、`System Volume Information` 等 U 盘系统目录。

扫描在后台线程执行，不会卡住界面。

### 3. 合成 Live Photo（关键）

Apple 的 Live Photo 不是简单地把 JPG 和 MOV 放在一起：两个文件必须携带**相同的 asset identifier**，MOV 还必须带一条 `still-image-time` 定时元数据轨道。缺任何一项，PhotoKit 导入时都可能报 `PHPhotosErrorDomain Code=-1`。

因此 `LivePhotoImporter` 做了完整的三步处理：

1. **生成 UUID** 作为本张实况照片的 asset identifier。
2. **处理 JPG**：用 ImageIO 读出原图属性和 EXIF，写入
   `kCGImagePropertyMakerAppleDictionary = ["17": assetIdentifier]`，
   再输出到临时目录中的 `still.jpg`（JPEG 质量设为 1.0，尽量保留画质）。
3. **处理 MOV**：用 `AVAssetReader` / `AVAssetWriter` 以 **passthrough（不转码）** 方式重封装视频，并写入：
   - 顶层 QuickTime 元数据 `com.apple.quicktime.content.identifier = assetIdentifier`；
   - 一条 `.metadata` 轨道，规格为 `mdta/com.apple.quicktime.still-image-time`，在视频约 50% 处写入一个 int8 样本（0xFF）。
   音频轨道存在时会一起封装（passthrough，不转码）。
4. **写入相册**：把处理好的 `still.jpg` 与 `paired.mov` 放进**同一个** `PHAssetCreationRequest`：

```swift
PHPhotoLibrary.shared().performChanges({
    let request = PHAssetCreationRequest.forAsset()
    request.addResource(with: .photo, fileURL: stillJPGURL, options: nil)
    request.addResource(with: .pairedVideo, fileURL: pairedMOVURL, options: nil)
})
```

这样 PhotoKit 才能把它识别为一张完整的 Live Photo。

其他实现细节：

- 处理结果写在 App 沙盒的临时目录（`tmp/LivePhotoStaging`），用完自动删除。这样 PhotoKit 读取的是本地文件，不需要依赖外部卷的 security scope；
- 只申请 **add-only** 相册权限：`NSPhotoLibraryAddUsageDescription` + `PHPhotoLibrary.requestAuthorization(for: .addOnly)`；
- 每个文件导入成功后，把“文件夹名 + 文件名 + 文件大小”记入 `UserDefaults`，下次自动跳过，避免重复导入；
- 单对导入失败不影响后续文件，失败原因会显示在列表和“失败详情”里。

### 4. 界面流程

1. 选择 `GRLIFE` → 选择 `DCIM`（选择器里要点进文件夹再点右上角“打开”）；
2. 自动扫描并显示：可合成数量、缺 JPG 的 MOV、缺 MOV 的 JPG、文件名列表 + JPG 缩略图；
3. 点底部“合成 N 张实况照片”；
4. 首次请求相册写入权限；
5. 逐对导入并显示进度，可在文件之间取消；
6. 完成后打开系统相册即可看到新生成的实况照片（长按照片播放）。

App 名称是 **GRliveinport**；界面按 iPhone 安全区布局，`UILaunchScreen` 已配置，
在 iPhone 15 Pro 上会以原生分辨率全屏显示（不会出现旧 App 的兼容缩放黑边）。
合成出的实况照片**保留原始照片/视频分辨率**，不会强制缩放到 1179×2556 屏幕尺寸。

---

## 二、目录结构

```
live photo maker/
├── project.yml                       # XcodeGen 工程描述
├── Config/
│   └── Info.plist                    # 显示名 GRliveinport、文件共享、启动屏等
├── .github/workflows/build-ipa.yml   # GitHub Actions 构建 unsigned IPA
├── scripts/
│   ├── build-unsigned-ipa.sh
│   └── make-icon.ps1                 # 生成 GR 风格 App 图标
├── docs/github-upload.md
├── README.md
└── LivePhotoMaker/
    ├── App/
    │   └── LivePhotoMakerApp.swift   # App 入口
    ├── Models/
    │   ├── Models.swift              # 文件 / 配对 / 导入结果模型
    │   └── AppModel.swift            # 状态、扫描、导入调度（@Observable）
    ├── Services/
    │   ├── FolderRef.swift           # security-scoped URL 与 bookmark
    │   ├── DocumentPickerPresenter.swift  # 全屏 UIKit 文件夹选择器
    │   ├── MediaScanner.swift        # 递归扫描 + 同名配对
    │   ├── LivePhotoImporter.swift   # PhotoKit 合成 Live Photo
    │   └── ThumbnailLoader.swift     # JPG 缩略图
    ├── Views/
    │   ├── ContentView.swift
    │   ├── FolderCardView.swift
    │   └── PairRowView.swift
    └── Assets.xcassets               # GR 风格图标（1024×1024）
```

---

## 三、构建运行

> 当前代码是在 Windows 环境编写的，**没有在 Xcode 中编译、也没有真机验证过**。首次编译如果遇到 Swift/Xcode 版本差异导致的报错，把报错原文发给我即可快速修正。

### 环境

- Mac + Xcode 15 或更高版本
- 一台 iOS 17+ 真机（模拟器无法访问 U 盘）
- 建议 USB-C 接口的 iPhone（iPhone 15 及以后）直连 U 盘；Lightning 机型需要供电足够的转换器

### 方式 A：XcodeGen（推荐）

```bash
brew install xcodegen
cd "live photo maker"
xcodegen generate
open LivePhotoMaker.xcodeproj
```

然后在 Xcode 中：

1. Target → Signing & Capabilities → 选择你的 Team；
2. 修改 Bundle Identifier（`project.yml` 里默认是 `com.example.livephotomaker`）；
3. 选择真机 → Run。

### 方式 B：手动新建 Xcode 工程

1. Xcode → File → New → Project → **iOS App**；
2. Product Name 填 `LivePhotoMaker`，Interface 选 **SwiftUI**，Language 选 **Swift**；
3. 删除模板自带的 `LivePhotoMakerApp.swift` 和 `ContentView.swift`（移到废纸篓）；
4. 把本仓库 `LivePhotoMaker/` 下的 `App`、`Models`、`Services`、`Views` 文件夹拖进工程（勾选 Copy items if needed、Add to target）；`Assets.xcassets` 可用本仓库的替换模板同名文件，或直接沿用模板资源；
5. Deployment Target 设为 **iOS 17.0**；
6. 在 Target → Info 中添加/修改：
   - **Privacy - Photo Library Additions Usage Description**
     `用于将合成后的实况照片保存到你的系统相册。`
   - **Application supports iTunes file sharing**（`UIFileSharingEnabled`）= `YES`
   - **Supports opening documents in place**（`LSSupportsOpeningDocumentsInPlace`）= `YES`
   - **Bundle display name** = `GRliveinport`
   - 确认 **Launch Screen** 存在（模板工程默认有），否则 iPhone 15 Pro 可能以兼容分辨率运行、出现黑边。
7. Signing 选择 Team，真机运行。

> XcodeGen 方式会自动使用仓库里的 `Config/Info.plist`，上面的键已经配好；手动方式按第 6 步补上即可。

---

## 四、使用步骤

1. 把 U 盘格式化为 **exFAT / FAT32 / APFS**（NTFS 在 iOS 上不可写，甚至可能不可见），确认“文件”App 左侧能看到该磁盘；
2. 连接 iPhone，打开本 App；
3. 点“选择文件夹”，在系统文件选择器中进入 U 盘，**点进** `GRLIFE` 文件夹，再点右上角“打开”；
4. 同样方式**点进** `DCIM` 文件夹 → 右上角“打开”；
5. 等待扫描，核对“匹配结果”和文件列表；
6. 点击底部“合成 N 张实况照片”；
7. 首次会弹出相册权限，选择允许添加；
8. 完成后打开系统“照片”App，在最近项目中查看，长按照片即可播放实况效果。

> 测试时如果没有 U 盘，可以把这两个文件夹放到“文件”App 能访问的位置（例如 iCloud 云盘）里，效果相同。

---

## 五、注意事项与已知限制

- **必须真机测试**：iOS 模拟器不能挂载 U 盘。
- **Live Photo 时长**：iOS 的实况照片惯例时长为约 3 秒。如果 MOV 非常长，系统可能截断、播放异常或拒绝导入。建议先用 1–2 对短视频验证。
- **视频编码**：MOV 必须是 iOS 支持的编码（常见 H.264 / HEVC）。部分相机/记录仪的特殊编码会导入失败，失败详情里会显示系统错误。
- **处理耗时**：每对文件都要读取 JPG、重封装 MOV（视频音频不转码，但仍需完整读写一遍），长视频会比较慢，请逐对等待进度。
- **磁盘占用**：临时目录会生成处理后的 JPG + MOV，保存到相册时系统还会再存一份，请预留足够空间。导入结束后临时文件会自动清理。
- **画质**：MOV 采用 passthrough 重封装，视频/音频数据不重新编码；JPG 为写入 MakerNote 会重新封装，质量设为 1.0。
- **保持前台**：导入过程没有申请后台长任务，请让 App 保持在前台，并保持 U 盘连接稳定。
- **只读 U 盘**：App 不会修改、移动或删除 U 盘上的文件。
- **默认只匹配 JPG/JPEG**：如相机实际输出 HEIC，可在 `MediaScanner.photoExtensions` 中加入 `"heic"`（同时需要把 `LivePhotoImporter.writeStillImage` 的输出类型改成 HEIC）。
- **重复导入判断**依据“文件夹名 + 文件名 + 文件大小”，换一台同名同结构、文件大小完全相同的 U 盘会被当成同一批文件，可在右上角菜单清除导入记录。
- **分辨率**：界面已适配 iPhone 15 Pro 安全区并配置启动屏，原生全屏显示；合成出的实况照片保留原图/原视频分辨率，不强制缩放。
- **权限**：若拒绝过相册权限，可到“设置 → 隐私与安全性 → 照片 → GRliveinport”中重新打开。

---

## 六、常见问题

**在文件选择器里找不到 U 盘？**
先确认“文件”App 能否看到它。检查 U 盘格式、供电和转接头；NTFS 通常不支持。部分 Lightning 机型需要带供电的相机转换器。

**选择文件夹时点不进去 / 无法选中 / 看不到“打开”？**
1. 确认操作是：进入 U 盘 → **点进** GRLIFE/DCIM → 点右上角“打开”。单击文件夹只是进入下一层；
2. 当前版本已改为直接全屏 present 系统选择器（不再嵌在 SwiftUI sheet 里），并补上了 `LSSupportsOpeningDocumentsInPlace`，请使用最新构建；
3. iOS 的文件夹选择模式下，部分第三方/外接文件提供者会被系统置灰，这是平台行为，App 无法绕过；
4. 如果仍然无法选中，用备用方案：在“文件”App 中把 U 盘的 `GRLIFE`、`DCIM` 复制到 **我的 iPhone → GRliveinport**，然后点 App 里的“使用 App 内的 GRLIFE / DCIM（备用）”。

**提示“无法读取文件夹”？**
U 盘被拔掉、文件夹权限失效或书签过期。重新插好 U 盘后重新选择两个文件夹即可。

**保存后不是实况照片？**
先确认这个 MOV 能否在 iPhone 上直接播放（文件 App 里点开）。iOS 不支持的编码无法作为 Live Photo 视频。失败详情会给出原因；也建议用短视频先验证。若错误里出现 `PHPhotosErrorDomain Code=-1`，通常是元数据写入未生效，请把该文件对发我排查。

**会不会把 U 盘里的原文件删掉？**
不会。App 对 U 盘只有读取操作，导入使用的是临时目录中处理后的副本。

**视频会不会被压缩？**
视频和音频使用 passthrough 重封装，不重新编码；JPG 为了写入实况照片标记会重新封装，质量设为 1.0。

---

## 七、如何生成 IPA

> 说明：IPA 必须在 macOS + Xcode 上编译并签名。当前仓库是在 Windows 上编写的，**没有可直接下载的 IPA 文件**。下面给出两条路：本机 Mac 构建，或让 GitHub Actions 构建未签名 IPA。

### 方式 A：在自己的 Mac 上构建未签名 IPA

```bash
cd "live photo maker"
bash scripts/build-unsigned-ipa.sh
```

产物：`dist/LivePhotoMaker-unsigned.ipa`。

### 方式 B：GitHub Actions 构建（没有 Mac 也能用）

> 详细到每一步的图文说明见 [`docs/github-upload.md`](docs/github-upload.md)（含建仓库、上传文件清单、命令行/网页/GitHub Desktop 三种上传方式）。

仓库已带上 `.github/workflows/build-ipa.yml`：

1. 把整个目录推送到一个 GitHub 仓库；
2. 打开仓库的 **Actions → Build unsigned IPA → Run workflow**；
3. 构建完成后下载 `LivePhotoMaker-unsigned-ipa` 构建产物（artifact），里面是 `LivePhotoMaker-unsigned.ipa`。

### 安装未签名 IPA（Windows 也可以）

未签名 IPA **不能直接双击安装**，需要用你自己的 Apple ID 重新签名：

1. Windows 上安装 [Sideloadly](https://sideloadly.io/)（或 AltStore），以及 Apple 的 iTunes / iPhone 驱动；
2. iPhone 用数据线连接电脑；
3. 把 IPA 拖进 Sideloadly，输入你的 Apple ID，点击 Start 完成签名并安装；
4. iOS 16+ 需要先在 iPhone 上打开 **设置 → 隐私与安全性 → 开发者模式**（安装一次后出现，重启生效）；
5. 若提示不受信任，到 **设置 → 通用 → VPN 与设备管理** 信任你的 Apple ID 开发者证书。

注意：免费 Apple ID 签名的 App 通常 **7 天过期**，到期后重新签名安装即可；自用没有问题，不要用这种方式公开分发。

### 方式 C：有 Apple Developer 账号（签名 IPA / TestFlight）

在 Xcode 中选中 Target → Signing & Capabilities → 选择 Team，然后：

```bash
xcodebuild archive \
  -project LivePhotoMaker.xcodeproj \
  -scheme LivePhotoMaker \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/LivePhotoMaker.xcarchive

xcodebuild -exportArchive \
  -archivePath build/LivePhotoMaker.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath dist
```

把仓库里的 `ExportOptions.plist.example` 复制为 `ExportOptions.plist`，设置 `method`（development / ad-hoc / app-store-connect）和 `teamID`，并确保已配置好证书与描述文件。也可以直接在 Xcode 里 Archive → Distribute App。

---

## 八、如果需要继续扩展

- 支持 HEIC / PNG 等照片格式；
- 视频超过 3 秒时自动裁剪（注意 Live Photo 的 still-image-time 要随裁剪位置调整）；
- 导入完成后自动创建“GRliveinport”相册（需要 read-write 相册权限）；
- 后台任务支持、失败自动重试；
- 增加“直接多选 MOV / JPG 文件”的导入模式，彻底绕过外接 provider 的文件夹选择限制；
- 导入前用 `PHLivePhoto.request(withResourceFileURLs:)` 做配对预览。
