# Voice Studio v1.0.1 — 审查报告

> 审查日期: 2026-07-09 → 修复: v1.0.0 → UVR 补丁: v1.0.1

## 审查范围

- `native_app/Sources/VoiceStudioApp.swift` (~3700 行)
- `scripts/download_models.sh` → 重写
- `scripts/setup_environment.sh`
- `scripts/setup_asr.sh`
- `scripts/run_training.py`
- `scripts/run_separation.py` → 修复
- `scripts/run_slicing.py`
- `scripts/run_asr.py`
- `build_app.sh`
- 所有配置文件、.gitignore、README

---

## 🔴 致命缺陷 (Critical — 阻断了核心用户流程)

### C1. 模型下载不含 GPT-SoVITS 源码 — 新用户无法使用

**位置**: `scripts/download_models.sh`

`download_models.sh` 从 `XXXXRT/GPT-SoVITS-Pretrained` 只下载了预训练权重：
- `pretrained_models.zip` → 预训练模型
- `G2PWModel.zip` → G2P 模型
- `uvr5_weights.zip` → UVR5 权重

**但没有下载 GPT-SoVITS Python 源代码！** 源码在 `lj1995/GPT-SoVITS`，不在 `XXXXRT/GPT-SoVITS-Pretrained`。

后果链：
1. 用户点 "下载 GPT-SoVITS 模型 (~5.7GB)" → 下载成功
2. 用户点 "安装 Python 依赖" → `setup_environment.sh` 检查 `external/GPT-SoVITS/requirements.txt`
3. **失败**: `requirements.txt` 是源码的一部分，不在预训练模型包里
4. 即使手动安装依赖，训练也无法运行——没有 `GPT_SoVITS/inference_cli.py`、`s1_train.py`、`s2_train.py` 等

**当前用户** (在 Desktop 上有 `TTS_voice_train/external/GPT-SoVITS/`) 不受影响，因为 `findGPTSoVITSRoot()` 会扫描到兄弟目录的已有安装。

**修复方案**: `download_models.sh` 需要额外从 `lj1995/GPT-SoVITS` 下载源码 zip 到 `external/GPT-SoVITS/`。

### C2. curl 进度条解析不工作

**位置**: `scripts/download_models.sh` 第 66-70 行

```bash
if curl -L --continue-at - --progress-bar -o "$tmp_file" "$url" 2>&1 | while IFS= read -r line; do
```

问题: curl 的 `--progress-bar` 输出使用 `\r` (回车) 在同一行更新，不产生换行。`read -r line` 按换行符读取，所以进度百分比永远不会被正确解析。`DOWNLOAD_PROGRESS=` 行不会按预期发出。

**修复方案**: 改用 `curl --progress-bar` 的 `-#` 模式配合 `tr '\r' '\n'` 转换，或者用 `curl -#` 并直接用 stderr 解析。

### C3. `run_training.py` 推断 external_root 路径错误

**位置**: `scripts/run_training.py` 第 325 行

```python
external_root = python.parents[2]  # .venv/bin/python → GPT-SoVITS root
```

这假设 Python 路径一定是 `.venv/bin/python` (3 层)。如果用户使用系统 Python (`/usr/bin/python3` → `parents[2]` = `/`！) 或 Homebrew Python (`/opt/homebrew/bin/python3` → `parents[2]` = `/opt`！)，`external_root` 会是完全错误的路径，导致所有训练步骤失败。

**修复方案**: 从 `engine_config.json` 读取 `gpt_sovits_root` 字段，而不是从 Python 路径反推。

### C4. `installASR()` completion 中存在强制解包崩溃风险

**位置**: `native_app/Sources/VoiceStudioApp.swift` 第 2040 行

```swift
let asrPython = self!.root.appendingPathComponent(...)
```

`self!` 强制解包。如果 ViewModel 在 ASR 安装完成前被释放，App 崩溃。

---

## 🟠 严重问题 (Major — 功能不可用或体验严重受损)

### M1. 三个不同的 venv 路径，检测不一致

代码中存在 **三个不同的 venv 创建/检测路径**：

| 位置 | venv 路径 |
|------|----------|
| `setup_environment.sh` | `external/GPT-SoVITS/.venv/bin/python` |
| `ensureRuntimePython()` (Swift line 2226) | `gptRootURL/.venv-voice-studio/bin/python` |
| UI 检测 (Swift line 2884) | `external/GPT-SoVITS/.venv/bin/python` |
| `installDependencies()` 完成后 (line 1989) | `external/GPT-SoVITS/.venv/bin/python` |

`ensureRuntimePython` 创建 `.venv-voice-studio`，但 UI 检测 `.venv`。如果用户通过 "仅创建 venv" 按钮创建了 `.venv-voice-studio`，UI 的绿色勾不会显示，因为 UI 在找 `.venv`。

**修复方案**: 统一为 `external/GPT-SoVITS/.venv/bin/python`。`ensureRuntimePython` 中创建的 venv 路径应保持一致。

### M2. `setup_environment.sh` 安装 CPU-only PyTorch

**位置**: `scripts/setup_environment.sh` 第 47 行

```bash
"$PIP" install torch torchaudio --index-url https://download.pytorch.org/whl/cpu
```

在 Apple Silicon Mac 上使用 CPU-only PyTorch，训练速度会慢 5-10 倍。MPS 加速完全未使用。

**修复方案**: 检测 `uname -m`，Apple Silicon 上不指定 `--index-url`（默认安装 MPS 版本），或检测 macOS 版本。

### M3. `download_models.sh` unzip 失败被静默忽略

**位置**: `scripts/download_models.sh` 第 98-102 行

```bash
unzip -q -o "$DEST/pretrained_models/pretrained_models.zip" -d "$DEST/GPT_SoVITS/" 2>&1 || true
```

`|| true` 意味着解压失败也被忽略。如果 zip 损坏或磁盘空间不足，脚本仍报告成功，后续验证可能通过（如果已有旧文件）或以难以理解的方式失败。

### M4. `installDependencies()` 和 `installASR()` 共享状态标志

`isInstallingDeps`、`installProgress`、`installStatusLabel` 被两个操作共享。虽然它们不会同时运行，但:
- ASR 安装进度条显示 "安装依赖..." 等误导性标签
- ASR 失败时 `isInstallingDeps` 置 false，这是对的，但状态标签语义混乱

### M5. `run_training.py` 第 127 行重复代码

```python
link.symlink_to(target, target_is_directory=target.is_dir())  # line 126
link.symlink_to(target, target_is_directory=target.is_dir())  # line 127 — 重复!
```

### M6. `download_models.sh` 全局进度不准确

每个文件完成后 `DOWNLOAD_PROGRESS` 跳到 1/3、2/3、1.0，但文件大小差异巨大：
- `pretrained_models.zip`: 4.56GB
- `G2PWModel.zip`: 589MB
- `uvr5_weights.zip`: 523MB

第一个文件占 80% 的下载量但进度只显示 33%。

---

## 🟡 中等问题 (Medium — 影响体验但不阻断核心流程)

### MD1. `VoiceStudioModel.init()` 中 `loadRuntimeSettingsFromConfig()` 被调用两次

`init()` 调用一次，然后 `ContentView.onAppear` → `detectRuntime()` 中当路径为空时又调用一次。

### MD2. `build_app.sh` release zip 结构潜在问题

`zip` 命令包含 `external/` 目录（只有 `.gitkeep`），但 `-x "external/GPT-SoVITS/*"` 只排除子目录内容。如果 `external/GPT-SoVITS/` 存在（用户已下载模型），它不会被排除——但它应该在 `.gitignore` 中被排除。

### MD3. `findFFmpeg()` 只检查硬编码路径

Swift 代码中用硬编码路径列表找 ffmpeg，不像 Python 脚本用 `shutil.which`。如果用户通过 MacPorts 或自定义路径安装 ffmpeg，不会被检测到。

### MD4. UI 缺乏操作确认/取消机制

- 下载 5.7GB 没有确认弹窗
- 训练运行时关闭 App 有确认，但下载时没有
- 没有取消下载/安装的按钮

### MD5. runtime sheet 固定尺寸 780×700

在小屏幕 (13" MacBook) 上可能太大，在大屏幕上浪费空间。

---

## 🟢 小问题 (Minor)

### m1. `download_models.sh` 依赖 Python 做简单除法

第 69、93 行用 `python3 -c "print($pct/100)"` 做除法，可以用 `bc` 或 `awk`。

### m2. `run_training.py` 第 422-426 行多余的读回操作

写 `sem` 后立即读回再写，不必要的 I/O。

### m3. `detectStage()` 中 `parseProjectMeta` 对每个项目都完整扫描

项目列表刷新时可能阻塞主线程。

### m4. README 中 `--release` 文档缺失

README 没有说明如何用 `./build_app.sh --release` 打包。

### m5. 日志上限 24 条 (`logs.prefix(24)`) 可能不足

训练日志 24 条可能不够调试。

---

## 📋 修复计划

### 第 1 步: 修复致命缺陷 (C1-C4)

| # | 文件 | 修改 |
|---|------|------|
| C1 | `scripts/download_models.sh` | 新增下载 GPT-SoVITS 源码 (从 `lj1995/GPT-SoVITS` 下载 main branch zip，约 200MB) |
| C2 | `scripts/download_models.sh` | 修复 curl 进度解析：用 `curl -#` 替代 `--progress-bar`，将 `\r` 转为 `\n` |
| C3 | `scripts/run_training.py:325` | 从 `engine["gpt_sovits_root"]` 读取而非 `python.parents[2]` |
| C4 | `VoiceStudioApp.swift:2040` | `self!` → `self?.` |

### 第 2 步: 修复严重问题 (M1-M6)

| # | 文件 | 修改 |
|---|------|------|
| M1 | `VoiceStudioApp.swift:2226` | `ensureRuntimePython` 的 venv 路径统一为 `.venv` |
| M2 | `scripts/setup_environment.sh:47` | Apple Silicon 上不强制 CPU-only |
| M3 | `scripts/download_models.sh:98-102` | 移除 `|| true`，解压失败时 exit 1 |
| M4 | `VoiceStudioApp.swift` | 为 ASR 安装添加独立状态变量 |
| M5 | `scripts/run_training.py:127` | 删除重复行 |
| M6 | `scripts/download_models.sh` | 按文件大小加权进度 |

### 第 3 步: 修复中等问题 (MD1-MD5)

### 第 4 步: 构建 v1.0.0 并验证
