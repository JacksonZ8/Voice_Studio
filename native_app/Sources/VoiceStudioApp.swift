import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct VoiceInfo {
    let voiceId: String
    let engine: String
    let version: String
    let language: String
    let referenceText: String
    let referenceAudio: String
    let referenceLanguage: String
    let targetLanguage: String
    let gptWeight: String
    let sovitsWeight: String
    let packageRoot: URL
    let samples: [VoiceSample]
}

struct TTSEngineConfig {
    let python: String
    let gptSovitsRoot: String       // GPT-SoVITS 安装根目录（包含 GPT_SoVITS/ 子目录）
    let runtimeRoot: String         // gpt_sovits_runtime/ 工作目录
    let inferenceCLI: String
    let asrPython: String?
}

struct RuntimeCheckItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let ok: Bool
}

struct VoiceSample {
    let file: String
    let text: String
}

enum TTSProcessResult {
    case success
    case failure(String)
}

enum TrainingSmokeResult {
    case success(URL)
    case failure(String)
}

struct SliceAnnotation: Identifiable {
    let id = UUID()
    var fileName: String
    var path: String
    var text: String
    var duration: Double
    var confirmed: Bool = false
    var skipped: Bool = false
}

struct QualityReport {
    let fileName: String
    let duration: Double
    let sampleRate: Double
    let channels: Int
    let peak: Float
    let rms: Float
    let silenceRatio: Float
    let grade: String
    let score: Int
    let suggestions: [String]
}

struct PipelineLog: Identifiable {
    let id = UUID()
    let text: String
}

enum StudioStep: Int, CaseIterable {
    case importAudio = 0
    case separate = 1
    case annotate = 2
    case train = 3
    case tts = 4

    var title: String {
        switch self {
        case .importAudio: return "导入音频"
        case .separate: return "BGM/人声分离"
        case .annotate: return "ASR 标注审核"
        case .train: return "训练 GPT-SoVITS"
        case .tts: return "TTS 使用"
        }
    }
}

// MARK: - Project discovery & auto-detection

enum DetectedStage: Int, Comparable {
    case empty = -1
    case created = 0
    case sourceImported = 1
    case separated = 2
    case sliced = 3
    case asrDrafted = 4
    case confirmed = 5
    case trained = 6
    case ttsReady = 7

    static func < (lhs: DetectedStage, rhs: DetectedStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .empty:          return "空项目"
        case .created:        return "已创建"
        case .sourceImported: return "已导入素材"
        case .separated:      return "已分离人声"
        case .sliced:         return "已切片"
        case .asrDrafted:     return "已标注"
        case .confirmed:      return "已确认"
        case .trained:        return "已训练"
        case .ttsReady:       return "TTS就绪"
        }
    }

    var icon: String {
        switch self {
        case .empty:          return "folder"
        case .created:        return "folder.badge.plus"
        case .sourceImported: return "arrow.down.doc"
        case .separated:      return "waveform"
        case .sliced:         return "scissors"
        case .asrDrafted:     return "text.bubble"
        case .confirmed:      return "checkmark.circle"
        case .trained:        return "gearshape.2"
        case .ttsReady:       return "speaker.wave.2"
        }
    }
}

struct ProjectMeta: Identifiable, Hashable {
    let id: String
    let displayName: String
    let voiceId: String
    let language: String
    let sourcePath: String
    let detectedStage: DetectedStage
    let directoryURL: URL
    let sliceCount: Int
    let hasConfirmedList: Bool
    let hasExports: Bool
    let exportNames: [String]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ProjectMeta, rhs: ProjectMeta) -> Bool { lhs.id == rhs.id }
}

final class ProcessRegistry {
    static let shared = ProcessRegistry()
    private var processes = [Process]()
    private let lock = NSLock()

    func register(_ process: Process) {
        lock.lock()
        processes.append(process)
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }

    var hasRunningProcesses: Bool {
        lock.lock()
        let running = processes.contains { $0.isRunning }
        lock.unlock()
        return running
    }

    func terminateAll() {
        lock.lock()
        let running = processes.filter { $0.isRunning }
        lock.unlock()
        for process in running {
            process.terminate()
        }
    }
}

final class VoiceStudioModel: ObservableObject {
    @Published var projectName = "训练音色"
    @Published var voiceId = "training_voice_native"
    @Published var sourcePath = ""
    @Published var status = "未创建"
    @Published var qualityReport: QualityReport?
    @Published var voiceInfo: VoiceInfo?
    @Published var ttsText = "你好，这是训练音色的测试语音。"
    @Published var ttsOutputPath = ""
    @Published var previewSampleText = ""
    @Published var autoPlayWhileTyping = true
    @Published var isGeneratingTTS = false
    @Published var isTrainingSmoke = false
    @Published var isSlicing = false
    @Published var isSeparating = false
    @Published var isRunningASR = false
    @Published var currentStep: StudioStep = .importAudio
    @Published var vocalPath = ""
    @Published var bgmPath = ""
    @Published var annotations: [SliceAnnotation] = []
    @Published var logs: [PipelineLog] = []
    @Published var alertMessage: String?
    @Published var taskProgress = 0.0
    @Published var taskStage = ""
    @Published var taskStatusLabel = ""
    @Published var runtimeGPTSoVITSPath = ""
    @Published var runtimePythonPath = ""
    @Published var runtimeASRPythonPath = ""
    @Published var isCreatingRuntimeVenv = false
    @Published var runtimeSetupStatus = "未检测"
    @Published var runtimeCheckItems: [RuntimeCheckItem] = []

    // One-click download / install
    @Published var isDownloadingModels = false
    @Published var isInstallingDeps = false
    @Published var isInstallingASR = false
    @Published var downloadProgress = 0.0
    @Published var downloadStatusLabel = ""
    @Published var installProgress = 0.0
    @Published var installStatusLabel = ""

    /// True when any install operation is in progress (deps or ASR).
    var isAnyInstalling: Bool { isInstallingDeps || isInstallingASR }

    // Project discovery
    @Published var discoveredProjects: [ProjectMeta] = []
    @Published var selectedProjectId: String? = nil

    let root: URL
    private var ttsDebounceTimer: Timer?
    private var sound: NSSound?
    private var taskStartTime: Date?
    private var taskTimer: Timer?
    private var taskEstimatedSeconds: Double = 0

    init() {
        self.root = VoiceStudioModel.findProjectRoot()
        self.sourcePath = ""
        self.voiceInfo = loadVoiceInfo()
        ensureDirectory(root.appendingPathComponent("voice_projects"))
        loadRuntimeSettingsFromConfig()
        addLog("Voice Studio 已就绪。请导入音频/视频素材开始。")

        // Auto-discover projects and restore last session
        self.discoveredProjects = discoverProjects()
        if !discoveredProjects.isEmpty {
            loadLastSelectedProject()
        }
    }

    // MARK: - Project discovery & stage detection

    private var projectsRoot: URL {
        root.appendingPathComponent("voice_projects")
    }

    func discoverProjects() -> [ProjectMeta] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { url in
                guard url.hasDirectoryPath else { return false }
                let name = url.lastPathComponent
                if name.hasPrefix("_") { return false }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
                return fm.fileExists(atPath: url.appendingPathComponent("project.json").path)
            }
            .compactMap { parseProjectMeta(at: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func parseProjectMeta(at url: URL) -> ProjectMeta? {
        let fm = FileManager.default
        let projectJSON = url.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let voiceId = obj["voice_id"] as? String ?? url.lastPathComponent
        let displayName = obj["display_name"] as? String ?? url.lastPathComponent
        let language = obj["language"] as? String ?? "zh"
        let sourcePath = obj["source_path"] as? String ?? ""

        let stage = detectStage(for: url, voiceId: voiceId)

        let slicesURL = url.appendingPathComponent("dataset/slices")
        let sliceCount: Int
        if fm.fileExists(atPath: slicesURL.path),
           let files = try? fm.contentsOfDirectory(at: slicesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            sliceCount = files.filter { $0.pathExtension.lowercased() == "wav" }.count
        } else { sliceCount = 0 }

        let hasConfirmed = fm.fileExists(atPath: url.appendingPathComponent("lists/train.confirmed.list").path)

        let exportsURL = url.appendingPathComponent("exports")
        var exportNames: [String] = []
        var hasExports = false
        if fm.fileExists(atPath: exportsURL.path),
           let exportDirs = try? fm.contentsOfDirectory(at: exportsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for ed in exportDirs where ed.hasDirectoryPath {
                let weightsURL = ed.appendingPathComponent("weights")
                if fm.fileExists(atPath: weightsURL.path) {
                    exportNames.append(ed.lastPathComponent)
                }
            }
        }
        hasExports = !exportNames.isEmpty

        return ProjectMeta(
            id: url.lastPathComponent,
            displayName: displayName,
            voiceId: voiceId,
            language: language,
            sourcePath: sourcePath,
            detectedStage: stage,
            directoryURL: url,
            sliceCount: sliceCount,
            hasConfirmedList: hasConfirmed,
            hasExports: hasExports,
            exportNames: exportNames
        )
    }

    private func detectStage(for projectURL: URL, voiceId: String) -> DetectedStage {
        let fm = FileManager.default

        func dirHasFiles(_ dir: URL, ext: String? = nil) -> Bool {
            guard fm.fileExists(atPath: dir.path),
                  let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
            return files.contains { url in
                guard let ext else { return !url.lastPathComponent.hasPrefix(".") }
                return url.pathExtension.lowercased() == ext.lowercased()
            }
        }

        func hasVoicePackage(in exportsDir: URL) -> Bool {
            guard fm.fileExists(atPath: exportsDir.path),
                  let subdirs = try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
            for sub in subdirs where sub.hasDirectoryPath {
                let configsDir = sub.appendingPathComponent("configs")
                if fm.fileExists(atPath: configsDir.path),
                   let cfgs = try? fm.contentsOfDirectory(at: configsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                   cfgs.contains(where: { $0.pathExtension.lowercased() == "json" }) {
                    return true
                }
            }
            return false
        }

        func hasWeights(in exportsDir: URL) -> Bool {
            guard fm.fileExists(atPath: exportsDir.path),
                  let subdirs = try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
            for sub in subdirs where sub.hasDirectoryPath {
                let weightsDir = sub.appendingPathComponent("weights")
                if fm.fileExists(atPath: weightsDir.path),
                   let wf = try? fm.contentsOfDirectory(at: weightsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    let hasCkpt = wf.contains { $0.pathExtension.lowercased() == "ckpt" }
                    let hasPth  = wf.contains { $0.pathExtension.lowercased() == "pth" }
                    if hasCkpt && hasPth { return true }
                }
            }
            return false
        }

        // Detect from highest stage down

        // Stage 7: TTS-ready — exports with parseable voice config
        let exportsURL = projectURL.appendingPathComponent("exports")
        if hasVoicePackage(in: exportsURL) {
            // also try loading voiceInfo to confirm
            if fm.fileExists(atPath: exportsURL.path),
               let subdirs = try? fm.contentsOfDirectory(at: exportsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for sub in subdirs where sub.hasDirectoryPath {
                    if loadVoiceInfoFromPackage(packageRoot: sub) != nil {
                        return .ttsReady
                    }
                }
            }
            // fall through — has exports but couldn't parse config
        }

        // Stage 6: Trained — exports with weights
        if hasWeights(in: exportsURL) {
            return .trained
        }

        // Stage 5: Confirmed — train.confirmed.list has content
        let confirmedList = projectURL.appendingPathComponent("lists/train.confirmed.list")
        if fm.fileExists(atPath: confirmedList.path),
           let content = try? String(contentsOf: confirmedList, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .confirmed
        }

        // Stage 4: ASR drafted
        if fm.fileExists(atPath: projectURL.appendingPathComponent("asr/asr_drafts.json").path) {
            return .asrDrafted
        }

        // Stage 3: Sliced
        if dirHasFiles(projectURL.appendingPathComponent("dataset/slices"), ext: "wav") {
            return .sliced
        }

        // Stage 2: Separated
        if fm.fileExists(atPath: projectURL.appendingPathComponent("separated/vocals.wav").path) {
            return .separated
        }

        // Stage 1: Source imported
        if dirHasFiles(projectURL.appendingPathComponent("sources")) {
            return .sourceImported
        }

        // Stage 0: Created (project.json exists — guaranteed by caller)
        return .created
    }

    // MARK: - Project loading

    func loadProject(_ meta: ProjectMeta) {
        guard selectedProjectId != meta.id else { return }

        selectedProjectId = meta.id
        projectName = meta.displayName
        voiceId = meta.voiceId

        let projURL = meta.directoryURL
        let fm = FileManager.default

        // Restore source path
        if !meta.sourcePath.isEmpty && fm.fileExists(atPath: meta.sourcePath) {
            sourcePath = meta.sourcePath
        } else {
            let sourcesDir = projURL.appendingPathComponent("sources")
            if let files = try? fm.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
               let first = files.first(where: { !$0.lastPathComponent.hasPrefix(".") }) {
                sourcePath = first.path
            } else {
                sourcePath = ""
            }
        }

        // Restore vocal/bgm paths
        let vocalsWav = projURL.appendingPathComponent("separated/vocals.wav")
        let bgmWav = projURL.appendingPathComponent("separated/bgm.wav")
        vocalPath = fm.fileExists(atPath: vocalsWav.path) ? vocalsWav.path : ""
        bgmPath = fm.fileExists(atPath: bgmWav.path) ? bgmWav.path : ""

        // Restore annotations
        let asrJSON = projURL.appendingPathComponent("asr/asr_drafts.json")
        if fm.fileExists(atPath: asrJSON.path) {
            loadASRDrafts(from: asrJSON)
            applyConfirmedState(projectURL: projURL)
        } else {
            let manifestURL = projURL.appendingPathComponent("dataset/manifest.csv")
            if fm.fileExists(atPath: manifestURL.path) {
                loadAnnotationsFromManifest(datasetURL: projURL.appendingPathComponent("dataset"))
                applyConfirmedState(projectURL: projURL)
            } else {
                annotations = []
            }
        }

        // Restore voiceInfo from exports
        voiceInfo = nil
        let exportsURL = projURL.appendingPathComponent("exports")
        if fm.fileExists(atPath: exportsURL.path),
           let exportDirs = try? fm.contentsOfDirectory(at: exportsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for ed in exportDirs where ed.hasDirectoryPath {
                if let info = loadVoiceInfoFromPackage(packageRoot: ed) {
                    voiceInfo = info
                    break
                }
            }
        }
        if voiceInfo == nil {
            voiceInfo = loadVoiceInfo()
        }
        ttsOutputPath = latestTTSOutputPath()?.path ?? ""
        previewSampleText = ""

        // Map detected stage to StudioStep
        currentStep = mapStageToStep(meta.detectedStage)

        // Persist
        saveLastSelectedProject(meta.id)

        status = "已加载：\(meta.displayName)"
        addLog("已切换至项目：\(meta.displayName)（\(meta.detectedStage.displayName)）")
    }

    private func mapStageToStep(_ stage: DetectedStage) -> StudioStep {
        switch stage {
        case .ttsReady, .trained:
            return .tts
        case .confirmed:
            return .train
        case .asrDrafted, .sliced:
            return .annotate
        case .separated:
            return .annotate
        case .sourceImported:
            return .separate
        case .created, .empty:
            return .importAudio
        }
    }

    private func applyConfirmedState(projectURL: URL) {
        let confirmedList = projectURL.appendingPathComponent("lists/train.confirmed.list")
        guard let content = try? String(contentsOf: confirmedList, encoding: .utf8) else { return }
        let confirmedPaths = Set(content.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "|")
            guard parts.count >= 1 else { return nil }
            return String(parts[0])
        })
        for i in annotations.indices {
            if confirmedPaths.contains(annotations[i].path) {
                annotations[i].confirmed = true
                annotations[i].skipped = false
            }
        }
    }

    private func loadVoiceInfoFromPackage(packageRoot: URL) -> VoiceInfo? {
        guard let configURL = findVoiceConfig(in: packageRoot) else { return nil }
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let weights = object["weights"] as? [String: Any] ?? [:]
        let reference = object["reference"] as? [String: Any] ?? [:]
        let sampleObjects = object["validated_samples"] as? [[String: Any]] ?? []
        let samples = sampleObjects.compactMap { item -> VoiceSample? in
            guard let file = item["file"] as? String else { return nil }
            return VoiceSample(file: file, text: item["text"] as? String ?? "")
        }
        return VoiceInfo(
            voiceId: object["voice_id"] as? String ?? packageRoot.lastPathComponent,
            engine: object["engine"] as? String ?? "GPT-SoVITS",
            version: object["version"] as? String ?? "v2",
            language: object["language"] as? String ?? "zh",
            referenceText: reference["text"] as? String ?? "",
            referenceAudio: reference["audio"] as? String ?? "reference/reference.wav",
            referenceLanguage: reference["language"] as? String ?? "中文",
            targetLanguage: (object["inference"] as? [String: Any])?["default_target_language"] as? String ?? "中文",
            gptWeight: weights["gpt"] as? String ?? "",
            sovitsWeight: weights["sovits"] as? String ?? "",
            packageRoot: packageRoot,
            samples: samples
        )
    }

    // MARK: - Persistence

    private func saveLastSelectedProject(_ projectId: String) {
        UserDefaults.standard.set(projectId, forKey: "VoiceStudio.lastVoiceId")
    }

    private func loadLastSelectedProject() {
        guard let lastId = UserDefaults.standard.string(forKey: "VoiceStudio.lastVoiceId") else { return }
        if let project = discoveredProjects.first(where: { $0.id == lastId }) {
            loadProject(project)
        }
    }

    private var currentVoiceId: String {
        voiceId.isEmpty ? "voice_native" : voiceId
    }

    private var currentProjectURL: URL {
        root.appendingPathComponent("voice_projects/\(currentVoiceId)")
    }

    private var currentTTSOutputDir: URL {
        currentProjectURL.appendingPathComponent("inference/tts_outputs")
    }

    private var currentTTSWorkDir: URL {
        currentProjectURL.appendingPathComponent("inference/tts_work")
    }

    var canRunSeparation: Bool {
        !sourcePath.isEmpty && FileManager.default.fileExists(atPath: sourcePath)
    }

    var canRunASR: Bool {
        !vocalPath.isEmpty && FileManager.default.fileExists(atPath: vocalPath)
    }

    var canTrain: Bool {
        annotations.contains { $0.confirmed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text != "[需手动输入]" }
    }

    func confirmAllAnnotations() {
        for i in annotations.indices {
            annotations[i].confirmed = true
            annotations[i].skipped = false
        }
        status = "已全部确认"
    }

    func skipAllAnnotations() {
        for i in annotations.indices {
            annotations[i].skipped = true
            annotations[i].confirmed = false
        }
        status = "已全部跳过"
    }

    private var voicePackageStorageURL: URL {
        let currentExports = currentProjectURL.appendingPathComponent("exports")
        if FileManager.default.fileExists(atPath: currentExports.path) {
            return currentExports
        }
        let smokeExports = root.appendingPathComponent("voice_projects/app_training_smoke/exports")
        if FileManager.default.fileExists(atPath: smokeExports.path) {
            return smokeExports
        }
        return root.appendingPathComponent("voice_projects")
    }

    static func findProjectRoot() -> URL {
        let bundleURL = Bundle.main.bundleURL
        let candidates = [
            bundleURL.deletingLastPathComponent(),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]
        // Marker that is always present: git clone AND release zip both include this
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("gpt_sovits_runtime/smoke_overrides").path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func createProject(name: String? = nil, voiceId vid: String? = nil) {
        let safeName = name ?? projectName
        let safeId = vid ?? currentVoiceId

        // Update current identity
        projectName = safeName
        voiceId = safeId

        let projectURL = currentProjectURL
        ["sources", "dataset", "inference", "exports", "separated", "asr", "gpt_sovits"].forEach {
            ensureDirectory(projectURL.appendingPathComponent($0))
        }

        let json = """
        {
          "voice_id": "\(safeId)",
          "display_name": "\(safeName)",
          "language": "zh",
          "status": "created_native",
          "source_path": "\(sourcePath)",
          "pipeline": {
            "separation": "placeholder_bs_roformer",
            "slice_min_sec": 3,
            "slice_max_sec": 10,
            "tts_engine": "GPT-SoVITS",
            "rvc_enabled": false
          }
        }
        """
        do {
            try json.write(to: projectURL.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

            // Refresh project list and auto-select
            discoveredProjects = discoverProjects()
            if let newProject = discoveredProjects.first(where: { $0.id == safeId }) {
                loadProject(newProject)
            }

            status = "项目已创建"
            addLog("已创建项目目录：\(projectURL.path)")
        } catch {
            alertMessage = "创建项目失败：\(error.localizedDescription)"
        }
    }

    func importSourceFile() {
        let panel = NSOpenPanel()
        panel.title = "导入音频或视频素材"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["wav", "aiff", "aif", "mp3", "m4a", "flac", "mp4", "mov", "mkv"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let selected = panel.url else {
            return
        }

        let projectURL = currentProjectURL
        let sourcesURL = projectURL.appendingPathComponent("sources")
        ensureDirectory(sourcesURL)
        let target = sourcesURL.appendingPathComponent(selected.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: selected, to: target)
            addLog("已导入素材：\(target.lastPathComponent)")

            // Convert non-WAV / video to WAV via ffmpeg
            let ext = target.pathExtension.lowercased()
            if isVideo(url: target) || (ext != "wav" && ext != "aiff" && ext != "aif") {
                let wavTarget = target.deletingPathExtension().appendingPathExtension("wav")
                if let ffmpeg = findFFmpeg() {
                    addLog("正在用 ffmpeg 提取/转换为 WAV...")
                    let result = runProcess(executable: ffmpeg, arguments: [
                        "-y", "-i", target.path,
                        "-vn", "-ac", "1", "-ar", "44100",
                        wavTarget.path
                    ], currentDirectory: root)
                    if result.ok, FileManager.default.fileExists(atPath: wavTarget.path) {
                        sourcePath = wavTarget.path
                        status = "素材已导入并转换为 WAV"
                        addLog("已转换为 WAV：\(wavTarget.lastPathComponent)")
                    } else {
                        sourcePath = target.path
                        status = "素材已导入（转换失败，保留原格式）"
                        addLog("ffmpeg 转换失败：\(result.output)")
                    }
                } else {
                    sourcePath = target.path
                    status = "素材已导入（缺少 ffmpeg，无法转换格式）"
                    addLog("缺少 ffmpeg，非 WAV/视频格式可能无法质检和分离。")
                }
            } else {
                sourcePath = target.path
                status = "素材已导入"
            }

            analyzeSource()
            currentStep = .separate
        } catch {
            alertMessage = "导入素材失败：\(error.localizedDescription)"
        }
    }

    func importVoicePackage() {
        let panel = NSOpenPanel()
        panel.title = "选择语音包目录"
        panel.prompt = "导入语音包"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = voicePackageStorageURL
        guard panel.runModal() == .OK, let selected = panel.url else {
            return
        }
        guard let info = loadVoiceInfo(packageRoot: selected) else {
            alertMessage = "未在该目录找到 configs/*.json，或配置无法解析。"
            return
        }
        voiceInfo = info
        ttsOutputPath = latestTTSOutputPath()?.path ?? ""
        previewSampleText = ""
        status = "语音包已导入"
        addLog("已导入语音包：\(info.voiceId)")
    }

    func analyzeSource() {
        let url = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "素材路径不存在。"
            return
        }
        if isVideo(url: url) {
            qualityReport = nil
            status = "视频已导入"
            addLog("视频素材已登记：\(url.lastPathComponent)。后续将接入 ffmpeg 抽音轨。")
            return
        }
        do {
            let report = try analyzeAudio(url: url)
            qualityReport = report
            status = "质检完成"
            currentStep = .separate
            addLog("质检完成：\(report.fileName)，等级 \(report.grade)，\(report.score) 分。")
        } catch {
            alertMessage = "当前原生 MVP 优先支持 WAV/常见音频：\(error.localizedDescription)"
        }
    }

    func separateVocalsAndBGM() {
        guard !isSeparating else {
            return
        }
        guard let engine = loadEngineConfig() else {
            alertMessage = "缺少 GPT-SoVITS 引擎配置，无法启动真实分离。"
            return
        }
        createProject()
        let source = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            alertMessage = "请先导入音频/视频素材。"
            return
        }

        let separatedURL = currentProjectURL.appendingPathComponent("separated")
        ensureDirectory(separatedURL)

        isSeparating = true
        taskProgress = 0.02
        taskStatusLabel = "启动人声/BGM 分离"
        startTaskTimer()
        status = "真实分离运行中"
        addLog("开始真实人声/BGM 分离：优先 UVR/BS-RoFormer，备选 Demucs。")

        let script = root.appendingPathComponent("scripts/run_separation.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: engine.python)
        process.currentDirectoryURL = root
        process.arguments = [script.path, "--source", source.path, "--output-dir", separatedURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = "\(engine.gptSovitsRoot):\(URL(fileURLWithPath: engine.gptSovitsRoot).appendingPathComponent("tools/uvr5").path)"
        env["TEMP"] = root.appendingPathComponent("gpt_sovits_runtime/cache").path
        process.environment = env

        runProcessWithProgress(process, onLine: { [weak self] line in
            if line.hasPrefix("SEPARATION_PROGRESS=") {
                if let pct = Double(line.replacingOccurrences(of: "SEPARATION_PROGRESS=", with: "")) {
                    self?.taskProgress = pct
                }
            } else if line.contains("[run]") {
                self?.taskStatusLabel = "正在运行分离模型"
                self?.taskProgress = max(self?.taskProgress ?? 0.15, 0.25)
            } else if line.contains("SEPARATION_VOCALS") || line.contains("\"ok\": true") {
                self?.taskProgress = 0.92
                self?.taskStatusLabel = "分离完成，保存输出"
            }
        }, completion: { [weak self] ok, output in
            self?.isSeparating = false
            if ok {
                let vocals = separatedURL.appendingPathComponent("vocals.wav")
                let bgm = separatedURL.appendingPathComponent("bgm.wav")
                self?.vocalPath = vocals.path
                self?.bgmPath = bgm.path
                self?.currentStep = .annotate
                self?.status = "真实分离完成"
                self?.addLog("真实分离完成。")
                self?.finishTaskProgress(stage: "分离完成")
            } else {
                self?.status = "真实分离失败"
                self?.alertMessage = output
                self?.addLog("真实分离失败：\(output)")
                self?.finishTaskProgress(stage: "分离失败")
            }
        })
    }

    func separatePlaceholderVocalsAndBGM() {
        createProject()
        let source = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            alertMessage = "请先导入音频/视频素材。"
            return
        }
        guard let ffmpeg = findFFmpeg() else {
            alertMessage = "找不到 ffmpeg，无法执行占位分离。"
            return
        }

        let separatedURL = currentProjectURL.appendingPathComponent("separated")
        ensureDirectory(separatedURL)
        let vocals = separatedURL.appendingPathComponent("vocals.wav")
        let bgm = separatedURL.appendingPathComponent("bgm.wav")
        let duration = (try? audioDuration(url: source)) ?? 8

        let vocalResult = runProcess(
            executable: ffmpeg,
            arguments: ["-y", "-i", source.path, "-vn", "-ac", "1", "-ar", "44100", vocals.path],
            currentDirectory: root
        )
        guard vocalResult.ok else {
            alertMessage = "生成人声训练轨失败：\(vocalResult.output)"
            return
        }

        let bgmResult = runProcess(
            executable: ffmpeg,
            arguments: ["-y", "-f", "lavfi", "-i", "anullsrc=channel_layout=mono:sample_rate=44100", "-t", String(format: "%.2f", min(duration, 60)), bgm.path],
            currentDirectory: root
        )
        guard bgmResult.ok else {
            alertMessage = "生成 BGM 占位轨失败：\(bgmResult.output)"
            return
        }

        vocalPath = vocals.path
        bgmPath = bgm.path
        currentStep = .annotate
        status = "占位分离完成"
        addLog("已生成占位训练人声轨：\(vocals.lastPathComponent)。")
    }

    func buildEditableAnnotations() {
        guard !isSlicing, !isRunningASR else { return }
        if vocalPath.isEmpty || !FileManager.default.fileExists(atPath: vocalPath) {
            separatePlaceholderVocalsAndBGM()
        }
        let vocals = URL(fileURLWithPath: vocalPath.isEmpty ? sourcePath : vocalPath)
        guard FileManager.default.fileExists(atPath: vocals.path) else {
            alertMessage = "请先生成人声训练轨。"
            return
        }

        // Prefer VAD-based slicing; fall back to equal-length ffmpeg slicing
        if let engine = loadEngineConfig() {
            isSlicing = true
            status = "VAD 切片中"
            addLog("开始 VAD 智能切片（基于语音活动检测）...")
            runVADSlicing(engine: engine, vocals: vocals)
            return
        }

        // Fallback: equal-length ffmpeg slicing
        guard let ffmpeg = findFFmpeg() else {
            alertMessage = "找不到 ffmpeg，无法切片。"
            return
        }
        isSlicing = true
        defer { isSlicing = false }

        let slicesURL = currentProjectURL.appendingPathComponent("dataset/slices")
        ensureDirectory(slicesURL)
        let duration = max(3, (try? audioDuration(url: vocals)) ?? 8)
        let sliceLength = 8.0
        let count = max(1, min(5, Int(ceil(duration / sliceLength))))
        var nextAnnotations: [SliceAnnotation] = []

        for index in 0..<count {
            let start = Double(index) * sliceLength
            let length = min(sliceLength, max(0.1, duration - start))
            let slice = slicesURL.appendingPathComponent(String(format: "slice_%03d.wav", index + 1))
            let result = runProcess(
                executable: ffmpeg,
                arguments: ["-y", "-ss", String(format: "%.2f", start), "-i", vocals.path, "-t", String(format: "%.2f", length), "-ac", "1", "-ar", "32000", slice.path],
                currentDirectory: root
            )
            if result.ok {
                nextAnnotations.append(SliceAnnotation(
                    fileName: slice.lastPathComponent,
                    path: slice.path,
                    text: "[需手动输入]",
                    duration: length
                ))
            }
        }

        annotations = nextAnnotations
        currentStep = .annotate
        status = "切片标注待确认（ffmpeg 等长切片）"
        addLog("已生成 \(nextAnnotations.count) 条切片（等长切分）。建议使用 VAD 切片获得更好结果。")
    }

    private func runVADSlicing(engine: TTSEngineConfig, vocals: URL) {
        let script = root.appendingPathComponent("scripts/run_slicing.py")
        let datasetURL = currentProjectURL.appendingPathComponent("dataset")
        ensureDirectory(datasetURL)

        guard FileManager.default.fileExists(atPath: script.path) else {
            isSlicing = false
            addLog("缺少 VAD 切片脚本，回退到等长切片。")
            buildEditableAnnotationsFallback(vocals: vocals)
            return
        }

        taskProgress = 0.02
        taskStatusLabel = "VAD 分析语音活动"
        startTaskTimer()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: engine.python)
            process.currentDirectoryURL = self.root
            process.arguments = [script.path, "--source", vocals.path, "--output-dir", datasetURL.path, "--min-chunk", "3", "--max-chunk", "10", "--target-sr", "32000"]
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var allOutput = ""
            var sliceCount = 0
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let chunk = String(data: data, encoding: .utf8) {
                    allOutput += chunk
                    for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                        let s = String(line)
                        DispatchQueue.main.async {
                            if s.contains("[slice]") {
                                if s.contains("Loading") { self.taskProgress = 0.08; self.taskStatusLabel = "加载音频中" }
                                else if s.contains("Resampling") { self.taskProgress = 0.18; self.taskStatusLabel = "重采样到 32kHz" }
                                else if s.contains("Duration:") { self.taskProgress = 0.30; self.taskStatusLabel = "分析语音活动" }
                                else if s.contains("Speech threshold") { self.taskProgress = 0.40; self.taskStatusLabel = "检测语音段" }
                                else if s.contains("speech segments") { self.taskProgress = 0.50; self.taskStatusLabel = "检测到语音段，划分切片中" }
                                else if s.hasPrefix("[slice] slice_") {
                                    sliceCount += 1
                                    self.taskProgress = min(0.90, 0.50 + Double(sliceCount) * 0.02)
                                    self.taskStatusLabel = "生成切片 (\(sliceCount) 条)"
                                }
                                else if s.contains("Produced") {
                                    self.taskProgress = 0.92
                                    self.taskStatusLabel = "写入切片文件"
                                }
                            }
                        }
                    }
                }
            }
            do {
                try process.run()
                ProcessRegistry.shared.register(process)
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if let rest = String(data: remaining, encoding: .utf8), !rest.isEmpty { allOutput += rest }
                ProcessRegistry.shared.unregister(process)
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
            }

            let ok = process.terminationStatus == 0
            DispatchQueue.main.async {
                self.isSlicing = false
                if ok {
                    self.loadAnnotationsFromManifest(datasetURL: datasetURL)
                    self.currentStep = .annotate
                    self.status = "VAD 切片完成"
                    self.addLog("VAD 切片完成：\(self.annotations.count) 条人声片段。")
                    self.finishTaskProgress(stage: "切片完成 (\(self.annotations.count) 条)")
                    // Auto-chain ASR if configured
                    if engine.asrPython != nil {
                        self.addLog("自动启动 ASR 草稿标注...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.runASRAfterSlicing() }
                    }
                } else {
                    self.addLog("VAD 切片失败：\(allOutput)，回退到等长切片。")
                    self.finishTaskProgress(stage: "切片失败")
                    self.buildEditableAnnotationsFallback(vocals: vocals)
                }
            }
        }
    }

    private func runASRAfterSlicing() {
        guard let engine = loadEngineConfig(), let asrPython = engine.asrPython else { return }
        let slicesURL = currentProjectURL.appendingPathComponent("dataset/slices")
        guard FileManager.default.fileExists(atPath: slicesURL.path) else { return }
        let outputJSON = currentProjectURL.appendingPathComponent("asr/asr_drafts.json")
        ensureDirectory(outputJSON.deletingLastPathComponent())

        let totalSlices = annotations.count
        isRunningASR = true
        taskProgress = Double(max(1, totalSlices)) * 0.001
        taskStatusLabel = "ASR 启动中"
        startTaskTimer()
        status = "ASR 草稿生成中"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: asrPython)
        process.currentDirectoryURL = root
        process.arguments = [
            root.appendingPathComponent("scripts/run_asr.py").path,
            "--input-dir", slicesURL.path,
            "--output-json", outputJSON.path,
            "--model", "small", "--language", "zh"
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        process.environment = env

        var asrCount = 0
        var firstSliceTime: Date?
        runProcessWithProgress(process, onLine: { [weak self] line in
            if line.contains("\t") {
                asrCount += 1
                if firstSliceTime == nil { firstSliceTime = Date() }
                let pct = totalSlices > 0 ? Double(asrCount) / Double(totalSlices) : 0
                self?.taskProgress = pct
                self?.taskStatusLabel = "ASR 标注 \(asrCount)/\(totalSlices)"
            }
        }, completion: { [weak self] ok, output in
            self?.isRunningASR = false
            if ok {
                self?.loadASRDrafts(from: outputJSON)
                self?.currentStep = .train
                self?.status = "ASR 草稿完成"
                self?.addLog("ASR 草稿已写入：\(outputJSON.path)")
                self?.finishTaskProgress(stage: "ASR 完成 (\(totalSlices) 条)")
            } else {
                self?.status = "ASR 草稿失败"
                self?.addLog("ASR 草稿失败：\(output)")
                self?.finishTaskProgress(stage: "ASR 失败")
            }
        })
    }

    private func buildEditableAnnotationsFallback(vocals: URL) {
        guard let ffmpeg = findFFmpeg() else {
            alertMessage = "找不到 ffmpeg，无法切片。"
            return
        }
        let slicesURL = currentProjectURL.appendingPathComponent("dataset/slices")
        ensureDirectory(slicesURL)
        let duration = max(3, (try? audioDuration(url: vocals)) ?? 8)
        let sliceLength = 8.0
        let count = max(1, min(5, Int(ceil(duration / sliceLength))))
        var nextAnnotations: [SliceAnnotation] = []
        for index in 0..<count {
            let start = Double(index) * sliceLength
            let length = min(sliceLength, max(0.1, duration - start))
            let slice = slicesURL.appendingPathComponent(String(format: "slice_%03d.wav", index + 1))
            let result = runProcess(
                executable: ffmpeg,
                arguments: ["-y", "-ss", String(format: "%.2f", start), "-i", vocals.path, "-t", String(format: "%.2f", length), "-ac", "1", "-ar", "32000", slice.path],
                currentDirectory: root
            )
            if result.ok {
                nextAnnotations.append(SliceAnnotation(fileName: slice.lastPathComponent, path: slice.path, text: "[需手动输入]", duration: length))
            }
        }
        annotations = nextAnnotations
        currentStep = .annotate
        status = "切片待确认（等长回退）"
        addLog("已用等长切分生成 \(nextAnnotations.count) 条切片。建议安装 scipy 后使用 VAD 切片。")
    }

    private func runVADSlicingProcess(engine: TTSEngineConfig, script: URL, vocals: URL, outputDir: URL) -> (ok: Bool, output: String) {
        let pythonURL = URL(fileURLWithPath: engine.python)
        let process = Process()
        process.executableURL = pythonURL
        process.currentDirectoryURL = root
        process.arguments = [
            script.path,
            "--source", vocals.path,
            "--output-dir", outputDir.path,
            "--min-chunk", "3",
            "--max-chunk", "10",
            "--target-sr", "32000"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        return runProcess(process)
    }

    private func loadAnnotationsFromManifest(datasetURL: URL) {
        let manifestURL = datasetURL.appendingPathComponent("manifest.csv")
        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            annotations = []
            return
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { annotations = []; return }

        // Parse CSV header
        let header = lines[0].split(separator: ",").map { String($0) }
        guard let pathIdx = header.firstIndex(of: "path"),
              let durIdx = header.firstIndex(of: "duration") else {
            annotations = []
            return
        }

        var results: [SliceAnnotation] = []
        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count > max(pathIdx, durIdx) else { continue }
            let path = cols[pathIdx]
            let dur = Double(cols[durIdx]) ?? 0
            let fname = URL(fileURLWithPath: path).lastPathComponent
            results.append(SliceAnnotation(fileName: fname, path: path, text: "[需手动输入]", duration: dur))
        }
        annotations = results
    }

    func generateASRDrafts() {
        guard !isRunningASR else {
            return
        }
        guard let engine = loadEngineConfig(), let asrPython = engine.asrPython else {
            alertMessage = "缺少 ASR Python 配置，无法生成草稿标注。"
            return
        }
        let slicesURL = currentProjectURL.appendingPathComponent("dataset/slices")
        if !FileManager.default.fileExists(atPath: slicesURL.path) || annotations.isEmpty {
            // Need to slice first — VAD slicing is async, so return and let user retry
            buildEditableAnnotations()
            addLog("切片尚未就绪，请等待 VAD 切片完成后再点击 ASR 草稿标注。")
            return
        }

        let outputJSON = currentProjectURL.appendingPathComponent("asr/asr_drafts.json")
        ensureDirectory(outputJSON.deletingLastPathComponent())

        let totalSlices = annotations.count
        isRunningASR = true
        taskProgress = Double(max(1, totalSlices)) * 0.001
        taskStatusLabel = "ASR 启动中"
        startTaskTimer()
        status = "ASR 草稿生成中"
        addLog("开始 ASR 草稿标注：faster-whisper small（\(totalSlices) 条切片）。")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: asrPython)
        process.currentDirectoryURL = root
        process.arguments = [
            root.appendingPathComponent("scripts/run_asr.py").path,
            "--input-dir", slicesURL.path,
            "--output-json", outputJSON.path,
            "--model", "small", "--language", "zh"
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        process.environment = env

        var asrCount = 0
        runProcessWithProgress(process, onLine: { [weak self] line in
            if line.contains("\t") {
                asrCount += 1
                let pct = totalSlices > 0 ? Double(asrCount) / Double(totalSlices) : 0
                self?.taskProgress = pct
                self?.taskStatusLabel = "ASR 标注 \(asrCount)/\(totalSlices)"
            }
        }, completion: { [weak self] ok, output in
            self?.isRunningASR = false
            if ok {
                self?.loadASRDrafts(from: outputJSON)
                self?.currentStep = .train
                self?.status = "ASR 草稿完成"
                self?.addLog("ASR 草稿已写入：\(outputJSON.path)")
                self?.finishTaskProgress(stage: "ASR 完成 (\(totalSlices) 条)")
            } else {
                self?.status = "ASR 草稿失败"
                self?.alertMessage = output
                self?.addLog("ASR 草稿失败：\(output)")
                self?.finishTaskProgress(stage: "ASR 失败")
            }
        })
    }

    func runTraining() {
        guard !isTrainingSmoke else {
            return
        }
        guard let engine = loadEngineConfig() else {
            alertMessage = "缺少 GPT-SoVITS 引擎配置，无法启动训练。"
            return
        }
        let script = root.appendingPathComponent("scripts/run_training.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            alertMessage = "缺少训练脚本：\(script.path)"
            return
        }

        isTrainingSmoke = true
        taskProgress = 0.01
        taskStatusLabel = "训练准备中"
        startTaskTimer()
        status = "训练运行中"
        addLog("开始 GPT-SoVITS 训练：读取切片与标注 → 特征提取 → SoVITS → GPT → 导出语音包。")

        // Write confirmed list first
        let confirmed = annotations.filter { $0.confirmed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text != "[需手动输入]" }
        if !confirmed.isEmpty {
            let listsDir = currentProjectURL.appendingPathComponent("lists")
            ensureDirectory(listsDir)
            let lines = confirmed.map { "\($0.path)|voice_train|zh|\($0.text)" }
            let confirmedList = listsDir.appendingPathComponent("train.confirmed.list")
            try? lines.joined(separator: "\n").write(to: confirmedList, atomically: true, encoding: .utf8)
            addLog("已写入确认训练列表：\(confirmed.count) 条")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: engine.python)
        process.currentDirectoryURL = root
        process.arguments = [script.path, "--project", currentProjectURL.path, "--exp-name", "voice_studio_\(currentVoiceId)", "--preset", "standard"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        // Weighted progress model: cumulative after each stage
        // [1]=3%, [2]=8%, [3]=13%, [4]=15%, [5]=60%, [6]=98%, export=100%
        let stageBaseWeights = [0.03, 0.08, 0.13, 0.15, 0.60, 0.98]
        let stageLabels = [
            "提取文本/BERT 特征", "提取 CN-HuBERT 特征",
            "提取语义特征", "生成训练配置",
            "训练 SoVITS", "训练 GPT"
        ]

        var currentStage = 0
        var sovitsEpochs = 12   // default for standard preset
        var gptEpochs = 8       // default for standard preset

        runProcessWithProgress(process, onLine: { [weak self] line in
            guard let self else { return }
            // Parse explicit TRAINING_PROGRESS= markers from script (authoritative)
            if line.hasPrefix("TRAINING_PROGRESS=") {
                let val = line.replacingOccurrences(of: "TRAINING_PROGRESS=", with: "")
                if let pct = Double(val) {
                    self.taskProgress = pct
                }
                return
            }
            // Parse [N/6] stage markers
            if let match = line.range(of: #"\[(\d+)/6\]"#, options: .regularExpression) {
                if let num = Int(line[match].filter(\.isNumber).prefix(1)), num >= 1, num <= 6 {
                    currentStage = num
                    let base = stageBaseWeights[num - 1]
                    self.taskProgress = base
                    self.taskStatusLabel = "训练 [\(num)/6] \(stageLabels[num - 1])"
                    self.addLog(stageLabels[num - 1])
                    // Parse epoch counts from stage header lines
                    if num == 5, let epochRange = line.range(of: #"(\d+)\s*epochs"#, options: .regularExpression) {
                        let s = String(line[epochRange])
                        sovitsEpochs = Int(s.filter(\.isNumber)) ?? sovitsEpochs
                    }
                    if num == 6, let epochRange = line.range(of: #"(\d+)\s*epochs"#, options: .regularExpression) {
                        let s = String(line[epochRange])
                        gptEpochs = Int(s.filter(\.isNumber)) ?? gptEpochs
                    }
                }
            }
            // Within SoVITS stage (5): parse "Epoch: N" for finer progress
            if currentStage == 5, line.contains("Epoch:"),
               let range = line.range(of: #"Epoch:\s*(\d+)"#, options: .regularExpression) {
                let epochStr = line[range].replacingOccurrences(of: "Epoch: ", with: "")
                if let epoch = Int(epochStr) {
                    let stagePct = sovitsEpochs > 0 ? Double(epoch) / Double(sovitsEpochs) : 0
                    // Stage 5 maps to progress 0.15 → 0.60
                    self.taskProgress = 0.15 + stagePct * 0.45
                    self.taskStatusLabel = "训练 [5/6] 训练 SoVITS (\(epoch)/\(sovitsEpochs) epochs)"
                    self.addLog("SoVITS epoch \(epoch)/\(sovitsEpochs)")
                }
            }
            // Within GPT stage (6): parse epoch progress
            if currentStage == 6, let epochRange = line.range(of: #"Epoch:\s*(\d+)/(\d+)"#, options: .regularExpression) {
                let parts = String(line[epochRange]).split(separator: "/")
                if parts.count == 2,
                   let cur = Int(parts[0].replacingOccurrences(of: "Epoch: ", with: "")),
                   let tot = Int(parts[1]) {
                    gptEpochs = tot
                    let stagePct = Double(cur) / Double(tot)
                    // Stage 6 maps to progress 0.60 → 0.98
                    self.taskProgress = 0.60 + stagePct * 0.38
                    self.taskStatusLabel = "训练 [6/6] 训练 GPT (\(cur)/\(tot) epochs)"
                    self.addLog("GPT epoch \(cur)/\(tot)")
                }
            }
            // Detect export phase
            if line.hasPrefix("[export]") {
                self.taskProgress = 0.98
                self.taskStatusLabel = "导出语音包"
            }
        }, completion: { [weak self] ok, output in
            self?.isTrainingSmoke = false
            if ok {
                // Parse TRAINING_EXPORT= from output
                if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("TRAINING_EXPORT=") }) {
                    let value = line.replacingOccurrences(of: "TRAINING_EXPORT=", with: "")
                    let packageRoot = URL(fileURLWithPath: value)
                    self?.status = "训练完成"
                    self?.addLog("训练完成，导出语音包：\(packageRoot.path)")
                    if let info = self?.loadVoiceInfo(packageRoot: packageRoot) {
                        self?.voiceInfo = info
                        self?.currentStep = .tts
                        self?.addLog("已自动切换 TTS 语音包：\(info.voiceId)")
                    }
                } else if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("SMOKE_TRAIN_EXPORT=") }) {
                    let value = line.replacingOccurrences(of: "SMOKE_TRAIN_EXPORT=", with: "")
                    let packageRoot = URL(fileURLWithPath: value)
                    self?.status = "训练完成"
                    self?.addLog("训练完成，导出语音包：\(packageRoot.path)")
                    if let info = self?.loadVoiceInfo(packageRoot: packageRoot) {
                        self?.voiceInfo = info
                        self?.currentStep = .tts
                    }
                }
                self?.finishTaskProgress(stage: "训练完成")
            } else {
                self?.status = "训练失败"
                self?.alertMessage = output
                self?.addLog("训练失败：\(output)")
                self?.finishTaskProgress(stage: "训练失败")
            }
        })
    }

    private func loadASRDrafts(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            alertMessage = "ASR 完成，但草稿 JSON 无法读取。"
            return
        }
        annotations = objects.map { item in
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return SliceAnnotation(
                fileName: item["fileName"] as? String ?? "",
                path: item["path"] as? String ?? "",
                text: text.isEmpty ? "ASR未识别，请手动补充。" : text,
                duration: item["duration"] as? Double ?? 0
            )
        }
    }

    func generateTTS() {
        guard !isGeneratingTTS else {
            return
        }
        guard let voiceInfo else {
            alertMessage = "未加载语音包配置。"
            return
        }
        if let engine = loadEngineConfig() {
            generateRealTTS(voiceInfo: voiceInfo, engine: engine)
            return
        }
        generateSampleTTS(voiceInfo: voiceInfo)
    }

    private func generateSampleTTS(voiceInfo: VoiceInfo) {
        guard let sampleInfo = bestSample(for: ttsText, voiceInfo: voiceInfo) else {
            alertMessage = "当前语音包没有可用于占位试听的 sample wav。"
            return
        }
        let sample = voiceInfo.packageRoot.appendingPathComponent(sampleInfo.file)
        guard FileManager.default.fileExists(atPath: sample.path) else {
            alertMessage = "找不到占位 sample wav。"
            return
        }
        let outputDir = currentTTSOutputDir
        ensureDirectory(outputDir)
        cleanupTTSOutputs(in: outputDir, keeping: 20)
        let cacheKey = Self.stableHash("\(currentVoiceId)|\(voiceInfo.voiceId)|\(ttsText)")
        let output = outputDir.appendingPathComponent("\(voiceInfo.voiceId)_\(cacheKey).wav")
        do {
            if !FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.copyItem(at: sample, to: output)
            }
            ttsOutputPath = output.path
            previewSampleText = sampleInfo.text
            status = "TTS 已生成"
            addLog("TTS 输出已生成：\(output.lastPathComponent)，预览 sample：\(sampleInfo.text)")
            play(url: output)
            cleanupTTSOutputs(in: outputDir, keeping: 20)
        } catch {
            alertMessage = "生成 TTS 输出失败：\(error.localizedDescription)"
        }
    }

    private func generateRealTTS(voiceInfo: VoiceInfo, engine: TTSEngineConfig) {
        let trimmed = ttsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "请输入要合成的文字。"
            return
        }

        let outputDir = currentTTSOutputDir
        let workDir = currentTTSWorkDir
        let cacheDir = root.appendingPathComponent("gpt_sovits_runtime/cache")
        ensureDirectory(outputDir)
        ensureDirectory(workDir)
        ensureDirectory(cacheDir)
        cleanupTTSOutputs(in: outputDir, keeping: 20)

        let cacheKey = Self.stableHash("\(currentVoiceId)|\(voiceInfo.voiceId)|real|\(trimmed)")
        let finalOutput = outputDir.appendingPathComponent("\(voiceInfo.voiceId)_real_\(cacheKey).wav")
        if FileManager.default.fileExists(atPath: finalOutput.path) {
            ttsOutputPath = finalOutput.path
            status = "TTS 缓存命中"
            addLog("复用已生成的真实 TTS：\(finalOutput.lastPathComponent)")
            play(url: finalOutput)
            return
        }

        let jobDir = workDir.appendingPathComponent(cacheKey)
        ensureDirectory(jobDir)
        let targetTextURL = jobDir.appendingPathComponent("target.txt")
        let refTextURL = jobDir.appendingPathComponent("ref_text.txt")
        let tempOutput = jobDir.appendingPathComponent("output.wav")

        do {
            try trimmed.write(to: targetTextURL, atomically: true, encoding: .utf8)
            try voiceInfo.referenceText.write(to: refTextURL, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: tempOutput.path) {
                try FileManager.default.removeItem(at: tempOutput)
            }
        } catch {
            alertMessage = "准备 TTS 文本失败：\(error.localizedDescription)"
            return
        }

        isGeneratingTTS = true
        taskProgress = 0.05
        taskStatusLabel = "GPT-SoVITS 推理中"
        startTaskTimer()
        status = "真实 TTS 生成中"
        addLog("开始真实 GPT-SoVITS 推理：\(trimmed)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runInferenceProcess(
                voiceInfo: voiceInfo,
                engine: engine,
                targetTextURL: targetTextURL,
                refTextURL: refTextURL,
                outputDir: jobDir,
                cacheDir: cacheDir
            )
            DispatchQueue.main.async {
                self.isGeneratingTTS = false
                switch result {
                case .success:
                    do {
                        if FileManager.default.fileExists(atPath: finalOutput.path) {
                            try FileManager.default.removeItem(at: finalOutput)
                        }
                        try FileManager.default.moveItem(at: tempOutput, to: finalOutput)
                        self.ttsOutputPath = finalOutput.path
                        self.status = "真实 TTS 已生成"
                        self.addLog("真实 TTS 输出已生成：\(finalOutput.lastPathComponent)")
                        self.play(url: finalOutput)
                        self.cleanupTTSOutputs(in: outputDir, keeping: 20)
                        self.finishTaskProgress(stage: "TTS 生成完成")
                    } catch {
                        self.alertMessage = "保存真实 TTS 输出失败：\(error.localizedDescription)"
                        self.finishTaskProgress(stage: "保存失败")
                    }
                case .failure(let message):
                    self.status = "真实 TTS 失败"
                    self.alertMessage = message
                    self.addLog("真实 TTS 失败：\(message)")
                    self.finishTaskProgress(stage: "TTS 生成失败")
                }
            }
        }
    }

    private func runInferenceProcess(
        voiceInfo: VoiceInfo,
        engine: TTSEngineConfig,
        targetTextURL: URL,
        refTextURL: URL,
        outputDir: URL,
        cacheDir: URL
    ) -> TTSProcessResult {
        let runtimeURL = URL(fileURLWithPath: engine.gptSovitsRoot)
        let pythonURL = URL(fileURLWithPath: engine.python)
        let cliURL = runtimeURL.appendingPathComponent(engine.inferenceCLI)
        let gptModel = voiceInfo.packageRoot.appendingPathComponent(voiceInfo.gptWeight)
        let sovitsModel = voiceInfo.packageRoot.appendingPathComponent(voiceInfo.sovitsWeight)
        let refAudio = voiceInfo.packageRoot.appendingPathComponent(voiceInfo.referenceAudio)

        for required in [pythonURL, cliURL, gptModel, sovitsModel, refAudio] {
            guard FileManager.default.fileExists(atPath: required.path) else {
                return .failure("缺少推理文件：\(required.path)")
            }
        }

        let process = Process()
        process.executableURL = pythonURL
        process.currentDirectoryURL = runtimeURL
        process.arguments = [
            cliURL.path,
            "--gpt_model", gptModel.path,
            "--sovits_model", sovitsModel.path,
            "--ref_audio", refAudio.path,
            "--ref_text", refTextURL.path,
            "--ref_language", voiceInfo.referenceLanguage,
            "--target_text", targetTextURL.path,
            "--target_language", voiceInfo.targetLanguage,
            "--output_path", outputDir.path
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = "\(runtimeURL.path):\(runtimeURL.appendingPathComponent("GPT_SoVITS").path)"
        environment["MPLCONFIGDIR"] = cacheDir.path
        environment["NUMBA_CACHE_DIR"] = cacheDir.path
        environment["XDG_CACHE_HOME"] = cacheDir.path
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            ProcessRegistry.shared.register(process)
            defer { ProcessRegistry.shared.unregister(process) }
            process.waitUntilExit()
        } catch {
            return .failure("启动 GPT-SoVITS 失败：\(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return .failure(output.isEmpty ? "GPT-SoVITS 推理失败，退出码 \(process.terminationStatus)" : output)
        }
        let outputWav = outputDir.appendingPathComponent("output.wav")
        guard FileManager.default.fileExists(atPath: outputWav.path) else {
            return .failure("GPT-SoVITS 结束但没有生成 output.wav。\n\(output)")
        }
        return .success
    }

    func previewTTSWithoutWriting() {
        guard let voiceInfo, let sampleInfo = bestSample(for: ttsText, voiceInfo: voiceInfo) else {
            return
        }
        let sample = voiceInfo.packageRoot.appendingPathComponent(sampleInfo.file)
        guard FileManager.default.fileExists(atPath: sample.path) else {
            return
        }
        previewSampleText = sampleInfo.text
        status = "TTS 预览播放"
        play(url: sample)
    }

    func scheduleAutoTTS() {
        ttsDebounceTimer?.invalidate()
        guard autoPlayWhileTyping, !ttsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        ttsDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.previewTTSWithoutWriting()
        }
    }

    func playLastOutput() {
        if ttsOutputPath.isEmpty || !FileManager.default.fileExists(atPath: ttsOutputPath) {
            ttsOutputPath = latestTTSOutputPath()?.path ?? ""
        }
        guard !ttsOutputPath.isEmpty else {
            alertMessage = "当前项目还没有 TTS 输出。"
            return
        }
        play(url: URL(fileURLWithPath: ttsOutputPath))
    }

    func playSlice(path: String) {
        play(url: URL(fileURLWithPath: path))
    }

    private func play(url: URL) {
        sound = NSSound(contentsOf: url, byReference: true)
        sound?.play()
    }

    private func bestSample(for text: String, voiceInfo: VoiceInfo) -> VoiceSample? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = voiceInfo.samples.first(where: { $0.text == trimmed }) {
            return exact
        }
        let scored = voiceInfo.samples.map { sample in
            (sample: sample, score: similarityScore(trimmed, sample.text))
        }
        if let best = scored.max(by: { $0.score < $1.score }), best.score > 0 {
            return best.sample
        }
        if trimmed.count <= 12, let short = voiceInfo.samples.first(where: { $0.file.contains("short") }) {
            return short
        }
        if trimmed.count <= 36, let medium = voiceInfo.samples.first(where: { $0.file.contains("medium") }) {
            return medium
        }
        if let long = voiceInfo.samples.first(where: { $0.file.contains("long") }) {
            return long
        }
        return voiceInfo.samples.first
    }

    private func similarityScore(_ input: String, _ sampleText: String) -> Int {
        let inputSet = Set(input.filter { !$0.isWhitespace && !$0.isPunctuation })
        let sampleSet = Set(sampleText.filter { !$0.isWhitespace && !$0.isPunctuation })
        return inputSet.intersection(sampleSet).count
    }

    private func loadVoiceInfo() -> VoiceInfo? {
        loadVoiceInfo(packageRoot: root.appendingPathComponent("training_voice_assets"))
    }

    private func loadVoiceInfo(packageRoot: URL) -> VoiceInfo? {
        guard let configURL = findVoiceConfig(in: packageRoot) else {
            return nil
        }
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let weights = object["weights"] as? [String: Any] ?? [:]
        let reference = object["reference"] as? [String: Any] ?? [:]
        let sampleObjects = object["validated_samples"] as? [[String: Any]] ?? []
        let samples = sampleObjects.compactMap { item -> VoiceSample? in
            guard let file = item["file"] as? String else { return nil }
            return VoiceSample(file: file, text: item["text"] as? String ?? "")
        }
        return VoiceInfo(
            voiceId: object["voice_id"] as? String ?? "training_voice_v1",
            engine: object["engine"] as? String ?? "GPT-SoVITS",
            version: object["version"] as? String ?? "v2",
            language: object["language"] as? String ?? "zh",
            referenceText: reference["text"] as? String ?? "",
            referenceAudio: reference["audio"] as? String ?? "reference/reference.wav",
            referenceLanguage: reference["language"] as? String ?? "中文",
            targetLanguage: (object["inference"] as? [String: Any])?["default_target_language"] as? String ?? "中文",
            gptWeight: weights["gpt"] as? String ?? "",
            sovitsWeight: weights["sovits"] as? String ?? "",
            packageRoot: packageRoot,
            samples: samples
        )
    }

    private func loadEngineConfig() -> TTSEngineConfig? {
        let configURL = root.appendingPathComponent("gpt_sovits_runtime/engine_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let python = object["python"] as? String else {
            return nil
        }
        // gpt_sovits_root (new key) takes priority; fall back to runtime_root (old behavior)
        let gptSovitsRoot: String
        if let explicit = object["gpt_sovits_root"] as? String, !explicit.isEmpty {
            gptSovitsRoot = explicit
        } else if let legacy = object["runtime_root"] as? String, !legacy.isEmpty {
            gptSovitsRoot = legacy
        } else {
            return nil
        }
        let runtimeRoot = (object["runtime_root"] as? String) ?? root.appendingPathComponent("gpt_sovits_runtime").path
        return TTSEngineConfig(
            python: python,
            gptSovitsRoot: gptSovitsRoot,
            runtimeRoot: runtimeRoot,
            inferenceCLI: object["inference_cli"] as? String ?? "GPT_SoVITS/inference_cli.py",
            asrPython: object["asr_python"] as? String
        )
    }

    func chooseGPTSoVITSRoot() {
        let panel = NSOpenPanel()
        panel.title = "选择 GPT-SoVITS 根目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !runtimeGPTSoVITSPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: runtimeGPTSoVITSPath)
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        runtimeGPTSoVITSPath = selected.path
        if runtimePythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let guessed = guessPython(in: selected) {
            runtimePythonPath = guessed.path
        }
        // Also auto-detect ASR Python when selecting GPT-SoVITS root
        if runtimeASRPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let foundASR = findASRPython(nearGPTRoot: selected) {
            runtimeASRPythonPath = foundASR.path
            addLog("自动检测到 ASR Python：\(foundASR.path)")
        }
        detectRuntime()
    }

    func createRuntimeVenv() {
        let gptRoot = runtimeGPTSoVITSPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gptRoot.isEmpty else {
            alertMessage = "请先选择 GPT-SoVITS 根目录。"
            return
        }
        let gptRootURL = URL(fileURLWithPath: gptRoot)
        guard FileManager.default.fileExists(atPath: gptRootURL.appendingPathComponent("GPT_SoVITS/inference_cli.py").path) else {
            alertMessage = "未找到 GPT_SoVITS/inference_cli.py，请确认选择的是 GPT-SoVITS 根目录。"
            return
        }
        guard let python = ensureRuntimePython(gptRootURL: gptRootURL, preferExisting: false) else {
            return
        }
        runtimePythonPath = python
        runtimeSetupStatus = "已创建 venv"
        addLog("已创建/选择 GPT-SoVITS 虚拟环境：\(python)")
        detectRuntime()
    }

    func chooseRuntimePython() {
        let panel = NSOpenPanel()
        panel.title = "选择 GPT-SoVITS Python"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !runtimePythonPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: runtimePythonPath).deletingLastPathComponent()
        } else if !runtimeGPTSoVITSPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: runtimeGPTSoVITSPath)
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        runtimePythonPath = selected.path
        detectRuntime()
    }

    func chooseASRPython() {
        let panel = NSOpenPanel()
        panel.title = "选择 ASR Python（可选）"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !runtimeASRPythonPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: runtimeASRPythonPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        runtimeASRPythonPath = selected.path
        detectRuntime()
    }

    func configureRuntime() {
        let gptRoot = runtimeGPTSoVITSPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrPython = runtimeASRPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gptRoot.isEmpty, FileManager.default.fileExists(atPath: gptRoot) else {
            alertMessage = "请先选择 GPT-SoVITS 根目录（当前路径无效或为占位符）。"
            return
        }

        let gptRootURL = URL(fileURLWithPath: gptRoot)
        guard let python = ensureRuntimePython(gptRootURL: gptRootURL, preferExisting: true) else {
            return
        }
        runtimePythonPath = python
        let pythonURL = URL(fileURLWithPath: python)
        let cliURL = gptRootURL.appendingPathComponent("GPT_SoVITS/inference_cli.py")
        guard FileManager.default.fileExists(atPath: cliURL.path) else {
            alertMessage = "未找到 GPT_SoVITS/inference_cli.py，请确认选择的是 GPT-SoVITS 根目录。"
            return
        }
        guard FileManager.default.fileExists(atPath: pythonURL.path) else {
            alertMessage = "Python 路径不存在：\(python)"
            return
        }

        let runtimeDir = root.appendingPathComponent("gpt_sovits_runtime")
        ensureDirectory(runtimeDir)
        var object: [String: Any] = [
            "python": python,
            "gpt_sovits_root": gptRoot,
            "runtime_root": runtimeDir.path,
            "inference_cli": "GPT_SoVITS/inference_cli.py"
        ]
        if !asrPython.isEmpty {
            object["asr_python"] = asrPython
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: runtimeDir.appendingPathComponent("engine_config.json"), options: .atomic)
            runtimeSetupStatus = "已写入配置"
            status = "运行环境已配置"
            addLog("已生成 GPT-SoVITS 配置：\(runtimeDir.appendingPathComponent("engine_config.json").path)")
            detectRuntime()
        } catch {
            alertMessage = "写入 engine_config.json 失败：\(error.localizedDescription)"
        }
    }

    /// Download GPT-SoVITS pretrained models + G2P + UVR5 weights from HuggingFace.
    func downloadModels() {
        guard !isDownloadingModels else { return }
        let script = root.appendingPathComponent("scripts/download_models.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            alertMessage = "缺少下载脚本：\(script.path)"
            return
        }

        isDownloadingModels = true
        downloadProgress = 0.0
        downloadStatusLabel = "准备下载..."
        addLog("开始下载 GPT-SoVITS 模型（约 5.7GB，支持断点续传）...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = root
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        runProcessWithProgress(process, onLine: { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("DOWNLOAD_PROGRESS=") {
                if let pct = Double(line.replacingOccurrences(of: "DOWNLOAD_PROGRESS=", with: "")) {
                    self.downloadProgress = pct
                    self.downloadStatusLabel = "下载模型 \(Int(pct * 100))%"
                }
            } else if line.hasPrefix("DOWNLOAD_FILE=") {
                let name = line.replacingOccurrences(of: "DOWNLOAD_FILE=", with: "")
                self.downloadStatusLabel = "下载中: \(name)"
                self.addLog("下载: \(name)")
            } else if line.hasPrefix("[download]") || line.hasPrefix("[warn]") {
                self.addLog(String(line.dropFirst(0)))
            }
        }, completion: { [weak self] ok, output in
            self?.isDownloadingModels = false
            if ok {
                self?.downloadProgress = 1.0
                self?.downloadStatusLabel = "下载完成"
                self?.addLog("GPT-SoVITS 模型下载完成")
                self?.detectRuntime()
            } else {
                self?.alertMessage = "模型下载失败。请检查网络连接后重试（支持断点续传）。\n\n\(output)"
                self?.addLog("模型下载失败")
            }
        })
    }

    /// Install Python dependencies into the bundled venv.
    func installDependencies() {
        guard !isInstallingDeps else { return }
        let script = root.appendingPathComponent("scripts/setup_environment.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            alertMessage = "缺少安装脚本：\(script.path)"
            return
        }

        // Check that GPT-SoVITS exists
        let gptRoot = root.appendingPathComponent("external/GPT-SoVITS")
        guard FileManager.default.fileExists(atPath: gptRoot.appendingPathComponent("requirements.txt").path) else {
            alertMessage = "未找到 GPT-SoVITS。请先下载模型（模型包内含 GPT-SoVITS 源码）。"
            return
        }

        isInstallingDeps = true
        installProgress = 0.0
        installStatusLabel = "创建虚拟环境..."
        addLog("开始安装 Python 依赖（约 5-10 分钟）...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = root
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        runProcessWithProgress(process, onLine: { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("SETUP_PROGRESS=") {
                if let pct = Double(line.replacingOccurrences(of: "SETUP_PROGRESS=", with: "")) {
                    self.installProgress = pct
                    if pct < 0.15 { self.installStatusLabel = "创建虚拟环境..." }
                    else if pct < 0.35 { self.installStatusLabel = "安装 PyTorch..." }
                    else if pct < 0.85 { self.installStatusLabel = "安装依赖包..." }
                    else { self.installStatusLabel = "验证安装..." }
                }
            } else if line.hasPrefix("[setup]") {
                self.addLog(String(line.dropFirst(0)))
            }
        }, completion: { [weak self] ok, output in
            guard let self else { return }
            self.isInstallingDeps = false
            if ok {
                self.installProgress = 1.0
                self.installStatusLabel = "环境就绪"
                self.addLog("Python 依赖安装完成")
                // Update runtime paths
                let gptRootPath = self.root.appendingPathComponent("external/GPT-SoVITS").path
                let pythonPath = "\(gptRootPath)/.venv/bin/python"
                if FileManager.default.fileExists(atPath: pythonPath) {
                    self.runtimeGPTSoVITSPath = gptRootPath
                    self.runtimePythonPath = pythonPath
                    self.autoWriteEngineConfig()
                }
                self.detectRuntime()
            } else {
                self.alertMessage = "依赖安装失败。\n\n\(output)"
                self.addLog("依赖安装失败")
            }
        })
    }

    /// Install faster-whisper into a dedicated ASR venv.
    func installASR() {
        guard !isInstallingASR, !isInstallingDeps else { return }
        let script = root.appendingPathComponent("scripts/setup_asr.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            alertMessage = "缺少 ASR 安装脚本：\(script.path)"
            return
        }

        isInstallingASR = true
        installProgress = 0.0
        installStatusLabel = "安装 ASR 环境..."
        addLog("开始安装 ASR 环境（faster-whisper）...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = root
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        runProcessWithProgress(process, onLine: { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("SETUP_PROGRESS=") {
                if let pct = Double(line.replacingOccurrences(of: "SETUP_PROGRESS=", with: "")) {
                    self.installProgress = pct
                    self.installStatusLabel = "安装 ASR 环境..."
                }
            } else if line.hasPrefix("[asr]") {
                self.addLog(String(line.dropFirst(0)))
            }
        }, completion: { [weak self] ok, output in
            guard let self else { return }
            self.isInstallingASR = false
            if ok {
                self.installProgress = 1.0
                self.installStatusLabel = "ASR 就绪"
                let asrPython = self.root.appendingPathComponent("external/asr/.venv-asr/bin/python").path
                if FileManager.default.fileExists(atPath: asrPython) {
                    self.runtimeASRPythonPath = asrPython
                    self.autoWriteEngineConfig()
                }
                self.addLog("ASR 环境安装完成")
                self.detectRuntime()
            } else {
                self.alertMessage = "ASR 安装失败。\n\n\(output)"
                self.addLog("ASR 安装失败")
            }
        })
    }

    /// Silently write engine_config.json from current runtime settings (no alerts).
    private func autoWriteEngineConfig() {
        let gptRoot = runtimeGPTSoVITSPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let python = runtimePythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrPython = runtimeASRPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gptRoot.isEmpty, !python.isEmpty else { return }

        let runtimeDir = root.appendingPathComponent("gpt_sovits_runtime")
        ensureDirectory(runtimeDir)
        var object: [String: Any] = [
            "python": python,
            "gpt_sovits_root": gptRoot,
            "runtime_root": runtimeDir.path,
            "inference_cli": "GPT_SoVITS/inference_cli.py"
        ]
        if !asrPython.isEmpty {
            object["asr_python"] = asrPython
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runtimeDir.appendingPathComponent("engine_config.json"), options: .atomic)
        }
    }

    func detectRuntime() {
        var items: [RuntimeCheckItem] = []
        let fm = FileManager.default
        let configURL = root.appendingPathComponent("gpt_sovits_runtime/engine_config.json")

        // ── Seed config from example template on first launch ──
        let exampleURL = root.appendingPathComponent("configs/engine_config.example.json")
        if !fm.fileExists(atPath: configURL.path), fm.fileExists(atPath: exampleURL.path) {
            let runtimeDir = root.appendingPathComponent("gpt_sovits_runtime")
            ensureDirectory(runtimeDir)
            try? fm.copyItem(at: exampleURL, to: configURL)
        }

        if runtimeGPTSoVITSPath.isEmpty || runtimePythonPath.isEmpty {
            loadRuntimeSettingsFromConfig()
        }

        // ── Auto-detect when paths are empty or obvious placeholders ──
        let gptPath = runtimeGPTSoVITSPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let pythonPath = runtimePythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrPath = runtimeASRPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Consider a path "real" only if the file/directory actually exists
        let gptReal = !gptPath.isEmpty && fm.fileExists(atPath: gptPath)
        let pythonReal = !pythonPath.isEmpty && fm.fileExists(atPath: pythonPath)
        let asrReal = !asrPath.isEmpty && fm.fileExists(atPath: asrPath)

        if !gptReal || !pythonReal || !asrReal {
            var didAutoDetect = false

            // 1. Auto-detect GPT-SoVITS root
            if !gptReal, let found = findGPTSoVITSRoot() {
                runtimeGPTSoVITSPath = found.path
                didAutoDetect = true
                addLog("自动检测到 GPT-SoVITS：\(found.path)")
            }

            let currentGptRoot = runtimeGPTSoVITSPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let gptRootURL = URL(fileURLWithPath: currentGptRoot)

            // 2. Auto-detect Python inside GPT-SoVITS root
            if !pythonReal, !currentGptRoot.isEmpty {
                if let guessed = guessPython(in: gptRootURL) {
                    runtimePythonPath = guessed.path
                    didAutoDetect = true
                    addLog("自动检测到 Python：\(guessed.path)")
                }
            }

            // 3. Auto-detect ASR Python
            if !asrReal, !currentGptRoot.isEmpty {
                if let foundASR = findASRPython(nearGPTRoot: gptRootURL) {
                    runtimeASRPythonPath = foundASR.path
                    didAutoDetect = true
                    addLog("自动检测到 ASR Python：\(foundASR.path)")
                }
            }

            // 4. If we auto-detected enough, write the config
            if didAutoDetect {
                let updatedGptRoot = runtimeGPTSoVITSPath.trimmingCharacters(in: .whitespacesAndNewlines)
                let updatedPython = runtimePythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if !updatedGptRoot.isEmpty, !updatedPython.isEmpty,
                   fm.fileExists(atPath: URL(fileURLWithPath: updatedGptRoot).appendingPathComponent("GPT_SoVITS/inference_cli.py").path) {
                    autoWriteEngineConfig()
                }
            }
        }

        let gptRoot = runtimeGPTSoVITSPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let python = runtimePythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrPython = runtimeASRPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let gptRootURL = URL(fileURLWithPath: gptRoot)
        let cliURL = gptRootURL.appendingPathComponent("GPT_SoVITS/inference_cli.py")

        items.append(RuntimeCheckItem(
            title: "engine_config.json",
            detail: configURL.path,
            ok: fm.fileExists(atPath: configURL.path)
        ))
        items.append(RuntimeCheckItem(
            title: "GPT-SoVITS 根目录",
            detail: gptRoot.isEmpty ? "未选择" : gptRoot,
            ok: !gptRoot.isEmpty && fm.fileExists(atPath: gptRoot)
        ))
        items.append(RuntimeCheckItem(
            title: "inference_cli.py",
            detail: cliURL.path,
            ok: !gptRoot.isEmpty && fm.fileExists(atPath: cliURL.path)
        ))
        items.append(RuntimeCheckItem(
            title: "GPT-SoVITS Python",
            detail: python.isEmpty ? "未选择" : python,
            ok: !python.isEmpty && fm.fileExists(atPath: python)
        ))

        if !python.isEmpty && fm.fileExists(atPath: python) {
            let version = runProcess(executable: python, arguments: ["--version"], currentDirectory: root)
            items.append(RuntimeCheckItem(
                title: "Python 可执行性",
                detail: version.output.trimmingCharacters(in: .whitespacesAndNewlines),
                ok: version.ok
            ))
        }

        if let ffmpeg = findFFmpeg() {
            items.append(RuntimeCheckItem(title: "ffmpeg", detail: ffmpeg, ok: true))
        } else {
            items.append(RuntimeCheckItem(title: "ffmpeg", detail: "未找到，视频/非 WAV 转换会受限", ok: false))
        }

        if asrPython.isEmpty {
            items.append(RuntimeCheckItem(title: "ASR Python", detail: "未配置，ASR 草稿标注不可用", ok: false))
        } else {
            items.append(RuntimeCheckItem(title: "ASR Python", detail: asrPython, ok: fm.fileExists(atPath: asrPython)))
        }

        // UVR weights: check multiple possible locations
        //  1) gptRoot/tools/uvr5/uvr5_weights/  (if zip extracted with subdir)
        //  2) gptRoot/tools/uvr5/                (if zip extracted files directly)
        //  3) root/external/GPT-SoVITS/tools/uvr5/uvr5_weights/ (download destination)
        func hasWeights(in dir: URL) -> Bool {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .contains { ["pth", "ckpt"].contains($0.pathExtension.lowercased()) }
        }
        let uvrCandidates: [URL] = [
            gptRootURL.appendingPathComponent("tools/uvr5/uvr5_weights"),
            gptRootURL.appendingPathComponent("tools/uvr5"),
            root.appendingPathComponent("external/GPT-SoVITS/tools/uvr5/uvr5_weights"),
            root.appendingPathComponent("external/GPT-SoVITS/tools/uvr5"),
        ]
        let uvrFound = uvrCandidates.first(where: { fm.fileExists(atPath: $0.path) && hasWeights(in: $0) })
        items.append(RuntimeCheckItem(
            title: "UVR/BS-RoFormer 权重",
            detail: uvrFound?.path ?? (uvrCandidates.first?.path ?? "未找到"),
            ok: uvrFound != nil
        ))

        runtimeCheckItems = items
        let requiredOK = items
            .filter { ["engine_config.json", "GPT-SoVITS 根目录", "inference_cli.py", "GPT-SoVITS Python", "Python 可执行性"].contains($0.title) }
            .allSatisfy(\.ok)
        runtimeSetupStatus = requiredOK ? "核心 TTS 环境可用" : "需要配置"
    }

    private func loadRuntimeSettingsFromConfig() {
        guard let engine = loadEngineConfig() else { return }
        runtimeGPTSoVITSPath = engine.gptSovitsRoot
        runtimePythonPath = engine.python
        runtimeASRPythonPath = engine.asrPython ?? ""
    }

    private func ensureRuntimePython(gptRootURL: URL, preferExisting: Bool) -> String? {
        let existingPath = runtimePythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingPath.isEmpty, FileManager.default.fileExists(atPath: existingPath) {
            return existingPath
        }
        if preferExisting, let guessed = guessPython(in: gptRootURL) {
            return guessed.path
        }

        let venvURL = gptRootURL.appendingPathComponent(".venv")
        let pythonURL = venvURL.appendingPathComponent("bin/python")
        if FileManager.default.fileExists(atPath: pythonURL.path) {
            return pythonURL.path
        }
        guard let systemPython = findSystemPython3() else {
            alertMessage = "未找到系统 python3，无法自动创建虚拟环境。请先安装 Python 3。"
            return nil
        }

        runtimeSetupStatus = "创建 venv 中"
        isCreatingRuntimeVenv = true
        defer { isCreatingRuntimeVenv = false }
        let result = runProcess(executable: systemPython, arguments: ["-m", "venv", venvURL.path], currentDirectory: gptRootURL)
        guard result.ok, FileManager.default.fileExists(atPath: pythonURL.path) else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            alertMessage = detail.isEmpty ? "创建 GPT-SoVITS 虚拟环境失败。" : "创建 GPT-SoVITS 虚拟环境失败：\n\(detail)"
            return nil
        }
        return pythonURL.path
    }

    private func findSystemPython3() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private func guessPython(in gptRoot: URL) -> URL? {
        let candidates = [
            gptRoot.appendingPathComponent(".venv/bin/python"),
            gptRoot.appendingPathComponent(".venv-gpt-sovits/bin/python"),
            gptRoot.appendingPathComponent("venv/bin/python"),
            gptRoot.appendingPathComponent("env/bin/python")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Auto-detect GPT-SoVITS root by searching common locations.
    /// Returns the first directory that contains `GPT_SoVITS/inference_cli.py`.
    private func findGPTSoVITSRoot() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let projectParent = root.deletingLastPathComponent()

        // Check a single candidate
        func check(_ url: URL) -> URL? {
            let cli = url.appendingPathComponent("GPT_SoVITS/inference_cli.py")
            return fm.fileExists(atPath: cli.path) ? url : nil
        }

        // Scan parent directories for `*/external/GPT-SoVITS` or `*/GPT-SoVITS`
        func scanParent(_ parent: URL) -> URL? {
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            for child in children where child.hasDirectoryPath {
                if let found = check(child.appendingPathComponent("external/GPT-SoVITS")) { return found }
                if let found = check(child.appendingPathComponent("GPT-SoVITS")) { return found }
            }
            return nil
        }

        // 0. Bundled inside the app release (external/GPT-SoVITS/)
        if let found = check(root.appendingPathComponent("external/GPT-SoVITS")) { return found }

        // 1. Direct paths (project sibling / home)
        let directs: [URL] = [
            projectParent.appendingPathComponent("GPT-SoVITS"),
            projectParent.appendingPathComponent("external/GPT-SoVITS"),
            home.appendingPathComponent("GPT-SoVITS"),
            home.appendingPathComponent("external/GPT-SoVITS"),
        ]
        for d in directs { if let found = check(d) { return found } }

        // 2. Scan sibling directories (e.g. TTS_voice_train/external/GPT-SoVITS)
        if let found = scanParent(projectParent) { return found }

        // 3. Scan one level up
        let upper = projectParent.deletingLastPathComponent()
        if let found = scanParent(upper) { return found }

        // 4. Scan Desktop and home
        let desktop = home.appendingPathComponent("Desktop")
        if let found = scanParent(desktop) { return found }
        if let found = scanParent(home) { return found }

        return nil
    }

    /// Auto-detect ASR Python relative to the GPT-SoVITS root or project.
    private func findASRPython(nearGPTRoot gptRoot: URL) -> URL? {
        let fm = FileManager.default
        let projectParent = root.deletingLastPathComponent()

        // Check a single candidate
        func check(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

        // Scan a directory for `*/training/asr/.venv-asr/bin/python` or `*/.venv-asr/bin/python`
        func scanParent(_ parent: URL) -> URL? {
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            for child in children where child.hasDirectoryPath {
                let asrA = child.appendingPathComponent("training/asr/.venv-asr/bin/python")
                if check(asrA) { return asrA }
                let asrB = child.appendingPathComponent(".venv-asr/bin/python")
                if check(asrB) { return asrB }
                let asrC = child.appendingPathComponent("asr/.venv-asr/bin/python")
                if check(asrC) { return asrC }
            }
            return nil
        }

        // 1. Relative to GPT-SoVITS root
        let nearCandidates: [URL] = [
            gptRoot.appendingPathComponent(".venv-asr/bin/python"),
            gptRoot.deletingLastPathComponent().appendingPathComponent("training/asr/.venv-asr/bin/python"),
            gptRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("training/asr/.venv-asr/bin/python"),
        ]
        for c in nearCandidates { if check(c) { return c } }

        // 2. Inside project root (bundled + custom)
        let inProject: [URL] = [
            root.appendingPathComponent("external/asr/.venv-asr/bin/python"),
            root.appendingPathComponent(".venv-asr/bin/python"),
            root.appendingPathComponent("asr/.venv-asr/bin/python"),
        ]
        for c in inProject { if check(c) { return c } }

        // 3. Scan sibling directories (e.g. TTS_voice_train/training/asr/.venv-asr)
        if let found = scanParent(projectParent) { return found }
        if let found = scanParent(projectParent.deletingLastPathComponent()) { return found }

        return nil
    }

    private func analyzeAudio(url: URL) throws -> QualityReport {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "VoiceStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建音频缓冲区"])
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw NSError(domain: "VoiceStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取浮点音频数据"])
        }

        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        var squareSum: Double = 0
        var silenceCount = 0
        let sampleCount = max(1, frames * channelCount)

        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frame in 0..<frames {
                let value = channel[frame]
                let absValue = abs(value)
                peak = max(peak, absValue)
                squareSum += Double(value * value)
                if absValue < 0.01 {
                    silenceCount += 1
                }
            }
        }

        let duration = Double(file.length) / format.sampleRate
        let rms = Float(sqrt(squareSum / Double(sampleCount)))
        let silenceRatio = Float(silenceCount) / Float(sampleCount)
        let quality = grade(duration: duration, sampleRate: format.sampleRate, channels: channelCount, peak: peak, rms: rms, silenceRatio: silenceRatio)
        return QualityReport(
            fileName: url.lastPathComponent,
            duration: duration,
            sampleRate: format.sampleRate,
            channels: channelCount,
            peak: peak,
            rms: rms,
            silenceRatio: silenceRatio,
            grade: quality.grade,
            score: quality.score,
            suggestions: quality.suggestions
        )
    }

    private func grade(duration: Double, sampleRate: Double, channels: Int, peak: Float, rms: Float, silenceRatio: Float) -> (grade: String, score: Int, suggestions: [String]) {
        var score = 100
        var suggestions = [String]()
        if duration < 600 {
            score -= 25
            suggestions.append("有效素材少于 10 分钟，可以做流程试跑，但不建议正式训练。")
        } else if duration < 1200 {
            score -= 10
            suggestions.append("素材达到最低试训门槛，建议补充到 20-40 分钟。")
        }
        if channels > 1 {
            score -= 5
            suggestions.append("检测到多声道，训练前建议统一为单声道 32k WAV。")
        }
        if sampleRate < 24000 {
            score -= 10
            suggestions.append("采样率偏低，建议准备 32k 或 44.1k 以上素材。")
        }
        if peak > 0.98 {
            score -= 10
            suggestions.append("峰值接近削波，建议降低增益或换用未压限素材。")
        }
        if rms < 0.015 {
            score -= 10
            suggestions.append("整体音量偏低，建议做响度规范化。")
        }
        if silenceRatio > 0.45 {
            score -= 15
            suggestions.append("静音比例偏高，建议先删除长静音或使用 VAD 切片。")
        }
        suggestions.append("BGM 和多说话人风险当前需人工复听，后续可接入分离模型和说话人聚类。")
        let grade = score >= 90 ? "S" : score >= 75 ? "A" : score >= 55 ? "B" : "C"
        return (grade, max(0, score), suggestions)
    }

    private func findVoiceConfig(in packageRoot: URL) -> URL? {
        let configsURL = packageRoot.appendingPathComponent("configs")
        guard let files = try? FileManager.default.contentsOfDirectory(at: configsURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files.first { $0.pathExtension.lowercased() == "json" }
    }

    private func isVideo(url: URL) -> Bool {
        ["mp4", "mov", "mkv"].contains(url.pathExtension.lowercased())
    }

    private func audioDuration(url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func findFFmpeg() -> String? {
        // 1. Hardcoded common paths first (fast)
        let hardcoded = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        if let found = hardcoded.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        // 2. Search PATH (handles MacPorts, custom installs, conda, etc.)
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        for dir in pathDirs {
            let candidate = "\(dir)/ffmpeg"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func runProcess(executable: String, arguments: [String], currentDirectory: URL) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = currentDirectory
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            ProcessRegistry.shared.register(process)
            defer { ProcessRegistry.shared.unregister(process) }
            process.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output)
    }

    private func runProcess(_ process: Process) -> (ok: Bool, output: String) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            ProcessRegistry.shared.register(process)
            defer { ProcessRegistry.shared.unregister(process) }
            process.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output)
    }

    // Run a Process reading stdout line by line, with a callback for progress.
    // The callback receives each line and can update @Published state on the main thread.
    private func runProcessWithProgress(
        _ process: Process,
        onLine: @escaping (String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var allOutput = ""

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let chunk = String(data: data, encoding: .utf8) {
                allOutput += chunk
                let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    DispatchQueue.main.async { onLine(String(line)) }
                }
            }
        }

        do {
            try process.run()
            ProcessRegistry.shared.register(process)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { completion(false, error.localizedDescription) }
            return
        }

        // Wait for completion on a background queue
        DispatchQueue.global(qos: .utility).async { [process] in
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            // Drain any remaining data
            let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
            if let rest = String(data: remaining, encoding: .utf8), !rest.isEmpty {
                allOutput += rest
            }
            let ok = process.terminationStatus == 0
            ProcessRegistry.shared.unregister(process)
            DispatchQueue.main.async { completion(ok, allOutput) }
        }
    }

    // MARK: - Progress timing helpers

    private func startTaskTimer() {
        taskStartTime = Date()
        taskEstimatedSeconds = 0
        taskTimer?.invalidate()
        taskTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.taskStartTime, self.taskProgress >= 0 else { return }
            let elapsed = Int(-start.timeIntervalSinceNow)
            let em = elapsed / 60
            let es = elapsed % 60
            let timing = "⏱ \(em):\(String(format: "%02d", es))"

            // Compute ETA from current progress
            var etaStr = ""
            let pct = self.taskProgress
            if pct > 0.03 && pct < 0.99 {
                let totalEst = Double(elapsed) / pct
                let remaining = totalEst - Double(elapsed)
                self.taskEstimatedSeconds = remaining
                let rSec = Int(max(0, remaining))
                if rSec >= 3600 {
                    etaStr = "  预计剩余 \(rSec / 3600) 小时 \((rSec % 3600) / 60) 分"
                } else if rSec >= 60 {
                    etaStr = "  预计剩余 \(rSec / 60) 分 \(rSec % 60) 秒"
                } else if rSec > 0 {
                    etaStr = "  预计剩余 \(rSec) 秒"
                }
            } else if pct >= 0.99 {
                etaStr = "  即将完成"
            } else {
                etaStr = "  正在估算..."
            }

            let label = self.taskStatusLabel.isEmpty ? "运行中" : self.taskStatusLabel
            self.taskStage = "\(label)  \(timing)\(etaStr)"
        }
    }

    private func stopTaskTimer() {
        taskTimer?.invalidate()
        taskTimer = nil
    }

    private func finishTaskProgress(stage: String) {
        taskProgress = 1.0
        taskStatusLabel = ""
        taskStage = stage
        stopTaskTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.taskStage = ""
            self?.taskProgress = 0
            self?.taskStatusLabel = ""
            self?.taskStartTime = nil
        }
    }

    private func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func cleanupTTSOutputs(in outputDir: URL, keeping limit: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let wavs = files.filter { $0.pathExtension.lowercased() == "wav" }
        let sorted = wavs.sorted {
            let left = ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            let right = ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            return left > right
        }
        for file in sorted.dropFirst(limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func latestTTSOutputPath() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: currentTTSOutputDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted {
                let left = ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                let right = ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                return left > right
            }
            .first
    }

    private func addLog(_ text: String) {
        logs.insert(PipelineLog(text: text), at: 0)
        logs = Array(logs.prefix(24))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

struct ContentView: View {
    @StateObject private var model = VoiceStudioModel()
    @State private var showNewProjectSheet = false
    @State private var showRuntimeSheet = false
    @State private var newProjectName = ""
    @State private var newProjectVoiceId = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.72, green: 0.86, blue: 0.92), Color(red: 0.42, green: 0.62, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            HStack(spacing: 14) {
                sidebar
                VStack(spacing: 14) {
                    header
                    stageStrip
                    activeStepPanel
                }
            }
            .padding(18)
        }
        .frame(minWidth: 1120, minHeight: 760)
        .alert("Voice Studio", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Branding
            HStack(spacing: 12) {
                Diamond()
                    .fill(Color(red: 0.84, green: 0.71, blue: 0.39))
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading) {
                    Text("Voice Studio")
                        .font(.title2.bold())
                    Text("本地原生应用")
                        .foregroundStyle(.secondary)
                }
            }

            Divider().overlay(Color.white.opacity(0.2))

            // Section header
            HStack {
                Text("项目列表")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.discoveredProjects.isEmpty {
                    Text("\(model.discoveredProjects.count) 个项目")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Project list
            if model.discoveredProjects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.68).opacity(0.4))
                    Text("暂无项目")
                        .foregroundStyle(.secondary)
                    Text("点击下方按钮创建第一个项目")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.discoveredProjects) { project in
                            projectRow(project)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Divider().overlay(Color.white.opacity(0.2))

            // New project button
            Button { showNewProjectSheet = true } label: {
                Label("新建项目", systemImage: "plus.circle")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                model.detectRuntime()
                showRuntimeSheet = true
            } label: {
                Label("运行环境", systemImage: "gearshape.2")
            }
            .buttonStyle(SecondaryButtonStyle())

            // Status
            Label(model.status, systemImage: "record.circle")
                .foregroundStyle(Color(red: 0.96, green: 0.91, blue: 0.79))
                .font(.footnote)
        }
        .padding(18)
        .frame(width: 280)
        .panelStyle()
        .onAppear {
            model.discoveredProjects = model.discoverProjects()
            model.detectRuntime()  // auto-detect GPT-SoVITS, Python, ASR on launch
        }
        .sheet(isPresented: $showNewProjectSheet) {
            VStack(spacing: 18) {
                Text("创建新项目")
                    .font(.title2.bold())
                TextField("项目名（中文）", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                TextField("Voice ID（英文/拼音）", text: $newProjectVoiceId)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 16) {
                    Button("取消") {
                        showNewProjectSheet = false
                    }
                    Button("创建") {
                        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let vid  = newProjectVoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty && !vid.isEmpty {
                            model.createProject(name: name, voiceId: vid)
                            showNewProjectSheet = false
                            newProjectName = ""
                            newProjectVoiceId = ""
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newProjectVoiceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 360)
            .background(Color(red: 0.72, green: 0.86, blue: 0.92))
        }
        .sheet(isPresented: $showRuntimeSheet) {
            runtimeSetupSheet
        }
    }

    private var runtimeSetupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("运行环境配置")
                        .font(.title2.bold())
                    Text("先选 GPT-SoVITS 根目录；App 会自动创建 GPT-SoVITS 专用 venv，ASR Python 可先不选。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.runtimeSetupStatus)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(model.runtimeSetupStatus.contains("可用") ? Color.green : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((model.runtimeSetupStatus.contains("可用") ? Color.green : Color.orange).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            VStack(alignment: .leading, spacing: 10) {
                runtimePathRow(
                    title: "1. GPT-SoVITS 根目录（必选）",
                    help: "选择包含 GPT_SoVITS 文件夹和 inference_cli.py 的目录。通常就是你下载/clone 的 GPT-SoVITS 项目根目录。",
                    placeholder: "/path/to/GPT-SoVITS",
                    text: $model.runtimeGPTSoVITSPath,
                    buttonTitle: "选择目录",
                    action: model.chooseGPTSoVITSRoot
                )
                runtimePathRow(
                    title: "2. GPT-SoVITS Python（必选）",
                    help: "给训练和 TTS 推理使用。通常不用手选：点击「生成配置并检测」时，App 会在 GPT-SoVITS 根目录自动创建 .venv/bin/python。",
                    placeholder: "/path/to/GPT-SoVITS/.venv/bin/python",
                    text: $model.runtimePythonPath,
                    buttonTitle: "选择 Python",
                    action: model.chooseRuntimePython
                )
                runtimePathRow(
                    title: "3. ASR Python（可选）",
                    help: "只用于“ASR 草稿标注”。如果你暂时只想用已有语音包做 TTS，可以先不选；不影响 TTS 生成。",
                    placeholder: "/path/to/faster-whisper-venv/bin/python",
                    text: $model.runtimeASRPythonPath,
                    buttonTitle: "选择 Python",
                    action: model.chooseASRPython
                )
            }

            HStack {
                Button(model.isCreatingRuntimeVenv ? "创建 venv 中..." : "生成配置并检测") { model.configureRuntime() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isCreatingRuntimeVenv || model.isDownloadingModels || model.isAnyInstalling)
                Button("重新检测") { model.detectRuntime() }
                    .buttonStyle(SheetSecondaryButtonStyle())
                Spacer()
                Button("完成") { showRuntimeSheet = false }
                    .buttonStyle(SheetSecondaryButtonStyle())
            }

            Divider().overlay(Color.white.opacity(0.3))

            // ── One-click download & install ──
            // Detect local state to show appropriate button labels
            let extGptRoot = model.root.appendingPathComponent("external/GPT-SoVITS")
            let extASR = model.root.appendingPathComponent("external/asr/.venv-asr/bin/python")
            let fm = FileManager.default
            // Check both source code AND model weights are present
            let sourceReady = fm.fileExists(atPath: extGptRoot.appendingPathComponent("GPT_SoVITS/inference_cli.py").path)
                && fm.fileExists(atPath: extGptRoot.appendingPathComponent("requirements.txt").path)
            let weightsReady = fm.fileExists(atPath: extGptRoot.appendingPathComponent("GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large/pytorch_model.bin").path)
                && fm.fileExists(atPath: extGptRoot.appendingPathComponent("GPT_SoVITS/pretrained_models/chinese-hubert-base/pytorch_model.bin").path)
                && fm.fileExists(atPath: extGptRoot.appendingPathComponent("GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth").path)
            let modelsReady = sourceReady && weightsReady
            let depsReady = fm.fileExists(atPath: extGptRoot.appendingPathComponent(".venv/bin/python").path)
            let asrReady = fm.fileExists(atPath: extASR.path)

            // ── One-click setup section ──
            Text("一键安装")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                if model.isDownloadingModels {
                    VStack(spacing: 4) {
                        ProgressView(value: model.downloadProgress)
                            .tint(Color(red: 0.95, green: 0.88, blue: 0.68))
                            .frame(width: 220)
                        Text(model.downloadStatusLabel).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if model.isAnyInstalling {
                    VStack(spacing: 4) {
                        ProgressView(value: model.installProgress)
                            .tint(Color(red: 0.95, green: 0.88, blue: 0.68))
                            .frame(width: 220)
                        Text(model.installStatusLabel).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    if modelsReady {
                        Label("GPT-SoVITS 模型已就绪", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    } else {
                        Button("下载 GPT-SoVITS 模型 (~5.7GB)") { model.downloadModels() }
                            .buttonStyle(DownloadButtonStyle())
                            .disabled(model.isDownloadingModels || model.isAnyInstalling)
                    }
                    if depsReady {
                        Label("Python 依赖已安装", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    } else {
                        Button("安装 Python 依赖") { model.installDependencies() }
                            .buttonStyle(DownloadButtonStyle())
                            .disabled(model.isDownloadingModels || model.isAnyInstalling)
                    }
                    if asrReady {
                        Label("ASR 环境已就绪", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    } else {
                        Button("安装 ASR 环境 (faster-whisper)") { model.installASR() }
                            .buttonStyle(DownloadButtonStyle())
                            .disabled(model.isDownloadingModels || model.isAnyInstalling)
                    }
                }
            }
            .padding(.vertical, 4)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.runtimeCheckItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(item.ok ? Color.green : Color.orange)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.footnote.weight(.semibold))
                                Text(item.detail.isEmpty ? "无详情" : item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(height: 210)

            Text("新用户只需依次点击上方三个按钮即可完成全部环境安装。已有 GPT-SoVITS 的用户可手动选择路径后点击「生成配置并检测」。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 780, height: 700)
        .background(Color(red: 0.72, green: 0.86, blue: 0.92))
    }

    private func runtimePathRow(
        title: String,
        help: String,
        placeholder: String,
        text: Binding<String>,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                Button(buttonTitle, action: action)
                    .buttonStyle(CompactButtonStyle())
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.50))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func projectRow(_ project: ProjectMeta) -> some View {
        let isSelected = model.selectedProjectId == project.id
        return Button {
            model.loadProject(project)
        } label: {
            HStack(spacing: 10) {
                // Selection indicator
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 0.95, green: 0.88, blue: 0.68))
                        .frame(width: 3, height: 32)
                } else {
                    Spacer().frame(width: 3)
                }

                Image(systemName: project.detectedStage.icon)
                    .frame(width: 22)
                    .foregroundStyle(stageColor(project.detectedStage))

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color(red: 0.95, green: 0.88, blue: 0.68) : .primary)
                    HStack(spacing: 6) {
                        Text(project.detectedStage.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if project.sliceCount > 0 {
                            Text("· \(project.sliceCount)条")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // Mini progress bar (5 steps)
                HStack(spacing: 2) {
                    ForEach(0..<5) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i <= progressStepIndex(project.detectedStage)
                                  ? stageColor(project.detectedStage)
                                  : Color.white.opacity(0.2))
                            .frame(width: 10, height: 4)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color(red: 0.95, green: 0.88, blue: 0.68).opacity(0.15)
                    : Color.white.opacity(0.04)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color(red: 0.95, green: 0.88, blue: 0.68).opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func progressStepIndex(_ stage: DetectedStage) -> Int {
        switch stage {
        case .ttsReady, .trained:  return 4
        case .confirmed:           return 3
        case .asrDrafted, .sliced: return 2
        case .separated:           return 1
        default:                   return 0
        }
    }

    private func stageColor(_ stage: DetectedStage) -> Color {
        switch stage {
        case .ttsReady:            return .green
        case .trained:             return Color(red: 0.95, green: 0.88, blue: 0.68)
        case .confirmed:           return .blue.opacity(0.8)
        case .asrDrafted:          return .cyan.opacity(0.8)
        case .sliced:              return .orange.opacity(0.8)
        case .separated:           return .purple.opacity(0.8)
        case .sourceImported:      return .yellow.opacity(0.8)
        default:                   return .gray.opacity(0.6)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.projectName)
                    .font(.largeTitle.bold())
                Text("音色训练审核向导")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.status)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(red: 0.95, green: 0.88, blue: 0.68))
                .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
        }
        .padding(18)
        .panelStyle()
    }

    private var stageStrip: some View {
        HStack(spacing: 8) {
            ForEach(StudioStep.allCases, id: \.rawValue) { step in
                Button {
                    if step.rawValue < model.currentStep.rawValue {
                        model.currentStep = step
                    }
                } label: {
                    Text(step.title)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(step == model.currentStep ? Color(red: 0.95, green: 0.88, blue: 0.68) : Color.white.opacity(step.rawValue < model.currentStep.rawValue ? 0.72 : 0.35))
                .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
                .disabled(step.rawValue > model.currentStep.rawValue)
            }
        }
    }

    @ViewBuilder
    private var activeStepPanel: some View {
        switch model.currentStep {
        case .importAudio:
            qualityPanel
        case .separate:
            separationPanel
        case .annotate:
            annotationPanel
        case .train:
            trainPanel
        case .tts:
            ttsPanel
        }
    }

    private var qualityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("素材导入与质检", icon: "waveform")

            // Import section
            let hasFile = !model.sourcePath.isEmpty && FileManager.default.fileExists(atPath: model.sourcePath)
            let fileName = URL(fileURLWithPath: model.sourcePath).lastPathComponent

            if hasFile {
                // File imported — show info + re-import option
                HStack {
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.title2)
                        .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.68))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已导入素材")
                            .font(.headline)
                        Text(fileName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("重新导入") { model.importSourceFile() }
                }
            } else {
                // No file — show import button
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.68).opacity(0.6))
                    Button("导入音频/视频") { model.importSourceFile() }
                        .buttonStyle(PrimaryButtonStyle())
                    Text("支持 wav、mp3、m4a、flac、mp4、mov、mkv。非 WAV/视频格式自动用 ffmpeg 转换。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            // Manual path entry (collapsed for advanced use)
            if hasFile || !model.sourcePath.isEmpty {
                DisclosureGroup("手动路径") {
                    TextField("WAV 素材路径", text: $model.sourcePath)
                        .textFieldStyle(.roundedBorder)
                    Button("手动分析此路径") { model.analyzeSource() }
                }
            }

            // Quality report
            if let report = model.qualityReport {
                Divider().overlay(Color.white.opacity(0.15))
                HStack {
                    Text(report.grade)
                        .font(.system(size: 44, weight: .black))
                        .frame(width: 76, height: 76)
                        .background(gradeColor(report.grade))
                        .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
                    VStack(alignment: .leading) {
                        Text(report.fileName).font(.headline)
                        Text("\(report.score) 分")
                        Text(String(format: "%.2fs · %.0f Hz · %d 声道", report.duration, report.sampleRate, report.channels))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                metricGrid(report)
                ForEach(report.suggestions, id: \.self) { item in
                    Text("• \(item)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 330)
        .panelStyle()
    }

    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "S": return Color(red: 0.95, green: 0.88, blue: 0.68)
        case "A": return Color.green.opacity(0.55)
        case "B": return Color.orange.opacity(0.55)
        default: return Color.red.opacity(0.45)
        }
    }

    private var trainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("训练 GPT-SoVITS 权重", icon: "play.circle")
            Text("使用全部已确认标注的切片进行 GPT-SoVITS 训练（SoVITS + GPT 两阶段），训练完成后自动导出语音包并注册到 TTS。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(model.isTrainingSmoke ? "训练运行中..." : "开始训练并注册语音包") { model.runTraining() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isTrainingSmoke || !model.canTrain)
            taskProgressBar
            if !model.canTrain {
                Text("请先完成 ASR 草稿并确认至少一条文本标注。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.logs) { log in
                        Text(log.text)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 520)
        .panelStyle()
    }

    private var separationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("BGM/人声分离", icon: "person.wave.2")
            Text("先使用真实 UVR 分离得到 vocals.wav 和 bgm.wav，再进入 ASR 标注审核。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(model.isSeparating ? "真实分离中..." : "真实人声/BGM分离") { model.separateVocalsAndBGM() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isSeparating || !model.canRunSeparation)
            Button("占位分离试跑") { model.separatePlaceholderVocalsAndBGM() }
                .disabled(!model.canRunSeparation)
            taskProgressBar
            if !model.vocalPath.isEmpty {
                Text("人声：\(model.vocalPath)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("BGM：\(model.bgmPath)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            logList
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 520)
        .panelStyle()
    }

    private var annotationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("ASR 标注审核", icon: "text.bubble")
            HStack {
                Button(model.isSlicing ? "VAD切片中..." : "生成切片+标注") { model.buildEditableAnnotations() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isSlicing || model.isRunningASR || !model.canRunASR)
                Button(model.isRunningASR ? "ASR运行中..." : "仅重新ASR标注") { model.generateASRDrafts() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isRunningASR || model.isSlicing || !model.canRunASR)
                Button("确认标注，进入训练") { model.currentStep = .train }
                    .disabled(!model.canTrain)
            }
            taskProgressBar
            if model.annotations.isEmpty {
                Text("点「生成切片+标注」一键完成 VAD 切片和 ASR 草稿。播放每条音频，修改文本后点「确认」标记可用于训练。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("✓ 全部确认") { model.confirmAllAnnotations() }
                        .disabled(model.annotations.allSatisfy { $0.confirmed })
                    Button("✗ 全部跳过") { model.skipAllAnnotations() }
                    Spacer()
                    Text("已确认 \(model.annotations.filter(\.confirmed).count) / \(model.annotations.count) 条")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                annotationList
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 520)
        .panelStyle()
    }

    private var annotationList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach($model.annotations) { $item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileName)
                                .font(.footnote.weight(.semibold))
                            Text(String(format: "%.1fs", item.duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 100, alignment: .leading)
                        TextField("修改这段文本标注", text: $item.text)
                            .textFieldStyle(.roundedBorder)
                            .disabled(item.skipped)
                        Button("播放") { model.playSlice(path: item.path) }
                        Button(item.confirmed ? "已确认" : "确认") {
                            item.confirmed = true
                            item.skipped = false
                        }
                        .disabled(item.confirmed)
                        Button(item.skipped ? "已跳过" : "跳过") {
                            item.skipped = true
                            item.confirmed = false
                        }
                        .disabled(item.skipped)
                    }
                    .padding(8)
                    .background(item.confirmed ? Color.green.opacity(0.12) : item.skipped ? Color.red.opacity(0.08) : Color.white.opacity(0.06))
                }
            }
        }
    }

    private var logList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.logs) { log in
                    Text(log.text)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.white.opacity(0.06))
                }
            }
        }
    }

    private var ttsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("TTS 解码试听", icon: "speaker.wave.2")
            if let voice = model.voiceInfo {
                HStack {
                    VStack(alignment: .leading) {
                        Text(voice.voiceId).font(.headline)
                        Text("\(voice.engine) \(voice.version) · \(voice.language)")
                            .foregroundStyle(.secondary)
                        Text("语音包：\(voice.packageRoot.path)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("参考文本：\(voice.referenceText)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("sample 占位输出")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                }
                if !model.previewSampleText.isEmpty {
                    Text("当前预览 sample：\(model.previewSampleText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            HStack {
                Button("导入语音包") { model.importVoicePackage() }
                Toggle("输入后自动预览", isOn: $model.autoPlayWhileTyping)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            TextEditor(text: $model.ttsText)
                .frame(height: 86)
                .scrollContentBackground(.hidden)
                .background(Color(red: 0.95, green: 0.91, blue: 0.82))
                .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
                .onChange(of: model.ttsText) { _, _ in
                    model.scheduleAutoTTS()
                }
            HStack {
                Button(model.isGeneratingTTS ? "真实推理中..." : "真实生成并播放 WAV") { model.generateTTS() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isGeneratingTTS)
                Button("重播最近输出") { model.playLastOutput() }
                if !model.ttsOutputPath.isEmpty {
                    Text(model.ttsOutputPath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            taskProgressBar
            Text("自动预览只播放语音包 sample，不写文件；手动生成会调用 GPT-SoVITS 真实推理，输出保存在当前项目并最多保留 20 个 wav。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .panelStyle()
    }

    @ViewBuilder
    private var taskProgressBar: some View {
        if !model.taskStage.isEmpty {
            VStack(spacing: 6) {
                ProgressView(value: max(0, min(1.0, model.taskProgress)), total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(Color(red: 0.95, green: 0.88, blue: 0.68))
                HStack {
                    Text(model.taskStatusLabel.isEmpty ? "运行中" : model.taskStatusLabel)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.68))
                        .lineLimit(1)
                    if model.taskProgress <= 0 {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(Color(red: 0.95, green: 0.88, blue: 0.68))
                    }
                    Spacer()
                    if model.taskProgress > 0 {
                        Text("\(Int(model.taskProgress * 100))%")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                // ETA / elapsed line
                let parts = model.taskStage.split(separator: "  ").map(String.init)
                if parts.count >= 2 {
                    Text(parts.dropFirst().joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
        }
    }

    private func panelTitle(_ text: String, icon: String) -> some View {
        HStack {
            Label(text, systemImage: icon)
                .font(.title3.bold())
            Spacer()
        }
    }

    private func metricGrid(_ report: QualityReport) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                metric("峰值", String(format: "%.3f", report.peak))
                metric("RMS", String(format: "%.3f", report.rms))
                metric("静音", String(format: "%.1f%%", report.silenceRatio * 100))
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08))
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(red: 0.13, green: 0.21, blue: 0.27))
            .foregroundStyle(Color(red: 0.93, green: 0.96, blue: 0.98))
            .overlay(Rectangle().stroke(Color(red: 0.84, green: 0.71, blue: 0.39).opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 12)
    }
}

extension View {
    func panelStyle() -> some View {
        modifier(PanelModifier())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? Color(red: 0.84, green: 0.71, blue: 0.39) : Color(red: 0.95, green: 0.88, blue: 0.68))
            .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? Color.white.opacity(0.18) : Color.white.opacity(0.10))
            .foregroundStyle(Color(red: 0.93, green: 0.96, blue: 0.98))
            .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(configuration.isPressed ? Color.white.opacity(0.25) : Color.white.opacity(0.15))
            .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct DownloadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? Color(red: 0.84, green: 0.71, blue: 0.39) : Color(red: 0.95, green: 0.88, blue: 0.68))
            .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Secondary button for use on light-colored sheets (runtime panel).
/// Dark text on translucent background — readable on light blue.
struct SheetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? Color.black.opacity(0.12) : Color.black.opacity(0.06))
            .foregroundStyle(Color(red: 0.12, green: 0.20, blue: 0.26))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProcessRegistry.shared.hasRunningProcesses else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Voice Studio 仍有任务在运行"
        alert.informativeText = "关闭 App 会终止正在运行的分离、ASR、训练或 TTS 推理进程。确定要关闭吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "终止并关闭")
        alert.addButton(withTitle: "继续等待")
        if alert.runModal() == .alertFirstButtonReturn {
            ProcessRegistry.shared.terminateAll()
            return .terminateNow
        }
        return .terminateCancel
    }
}

@main
struct VoiceStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
    }
}
