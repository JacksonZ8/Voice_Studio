# Voice Studio

Voice Studio 是一个本地“一键音色训练与 TTS 解码”原型。当前主入口已改为 macOS 原生 SwiftUI 应用，不再要求用户打开网页或手动启动本地 Web 服务。

## 目录

```text
Voice_train/
  ONE_CLICK_TTS_TRAINER_PLAN.md
  training_voice_assets/            # 可选内置训练音色包模板
  Voice Studio.app                  # 推荐入口：原生 macOS App
  native_app/Sources/               # SwiftUI 原生应用源码
  voice_projects/                   # 新建音色项目和 TTS 输出
```

每个 voice project 会使用：

```text
voice_projects/{voice_id}/
  project.json
  sources/
  dataset/
  inference/
  exports/
  separated/
  asr/
  gpt_sovits/
```

## 启动方式：macOS 原生 App

双击：

```text
Voice Studio.app
```

它会在本机 App 窗口内完成：

- 导入音频/视频素材
- 创建训练音色项目
- WAV 素材质检
- 按步骤完成 BGM/人声分离、ASR 草稿标注、人工审核和 GPT-SoVITS 训练
- 导入并切换本地语音包
- 读取训练音色 GPT-SoVITS 音色包配置
- 输入文本后自动预览当前语音包的 sample wav，不反复写入文件
- 手动生成时调用 GPT-SoVITS 真实推理，输出输入文本对应的训练音色 wav

如果 macOS 第一次提示未签名应用，右键点 `Voice Studio.app`，选择“打开”，再确认打开。

推荐使用方式：

1. 打开 `Voice Studio.app`。
2. 在 **导入音频** 页面点击 **导入音频/视频**，选择本地素材；完成后进入分离页面。
3. 在 **BGM/人声分离** 页面点击 **真实人声/BGM分离**；完成后进入 ASR 标注页面。
4. 在 **ASR 标注审核** 页面点击 **生成切片标注** 和 **ASR草稿标注**。
5. 播放每条切片并修改文本标注；确认后进入训练页面。
6. 在 **训练 GPT-SoVITS** 页面点击 **开始训练并注册语音包**；成功后进入 TTS 页面。
7. 在 TTS 区域点击 **导入语音包** 会默认打开语音包存储目录；目录内需要包含 `configs/*.json`。
8. 关闭 App 时，如果仍有分离、ASR、训练或 TTS 推理进程在运行，会提示是否终止并关闭。
9. 在 TTS 区域输入文本，默认会在停止输入后自动预览当前语音包的 sample wav。
10. 点击 **真实生成并播放 WAV**，App 会调用 GPT-SoVITS 推理并播放输入文本对应的训练音色音频。

## 重新构建原生 App

```bash
./build_app.sh
```

## GitHub 打包边界

这个仓库建议只上传 Voice Studio 应用源码、脚本、文档和模板配置；不要上传训练数据、生成音频、模型权重、缓存和本机绝对路径配置。

可提交内容包括：

- `native_app/`
- `scripts/`
- `configs/engine_config.example.json`
- `docs/`
- `README.md`
- `build_app.sh`
- `training_voice_assets/README.md`
- `training_voice_assets/configs/`
- `training_voice_assets/docs/`

不要提交：

- `Voice Studio.app/`
- `voice_projects/`
- `gpt_sovits_runtime/engine_config.json`
- `gpt_sovits_runtime/cache/`、`logs/`、`TEMP/`
- `gpt_sovits_runtime/GPT_weights_v2/`、`SoVITS_weights_v2/`
- `training_voice_assets/reference/`、`samples/`、`weights/`
- `ONE_CLICK_TTS_TRAINER_PLAN.md`、`agent_handoff/`
- 本地测试媒体和训练输出

完整打包说明见 `docs/GITHUB_PACKAGING.md`。

## 当前真实实现

- 原生 macOS SwiftUI App 可双击启动。
- 原生 App 内可创建项目目录和 `project.json`。
- 原生 App 内可通过 macOS 文件选择器导入 wav、mp3、m4a、flac、mp4、mov、mkv。
- 原生 App 内可读取训练音色包配置。
- 原生 App 内可分析 WAV：时长、采样率、声道数、峰值、RMS、静音比例。
- 原生 App 内可展示 S/A/B/C 等级和行动建议。
- 原生 App 已改为步骤向导：导入音频、BGM/人声分离、ASR 标注审核、训练 GPT-SoVITS、TTS 使用。
- 原生 App 内已有 **分离与标注** 面板：支持真实人声/BGM 分离后端探测、ffmpeg 占位分离、8 秒切片、ASR 草稿标注，并可在 App 中编辑切片文本。
- ASR 草稿已接入 faster-whisper small；脚本会优先使用本机 Hugging Face 缓存，输出 `voice_projects/{voice_id}/asr/asr_drafts.json`。
- 原生 App 内已有 GPT-SoVITS 训练 smoke 测试入口：从 `测试语音.mp3` 截取 8 秒，生成特征，执行 1 epoch SoVITS/GPT 小训练，导出 `voice_studio_smoke` 语音包并自动注册到 TTS。
- 原生 App 内可导入包含 `configs/*.json` 的本地语音包目录，文件选择器会默认进入项目 exports/语音包存储目录。
- 原生 App 内可在输入文本后自动播放当前语音包 sample wav 预览，自动预览不会写文件。
- 手动生成 TTS wav 时会调用 GPT-SoVITS `inference_cli.py`，按文本缓存，同一文本复用同一个文件，并最多保留 20 个 wav 输出。
- 关闭最后一个 App 窗口会退出 App；若仍有后台任务，会提示确认并终止由 App 启动的子进程。
- GPT-SoVITS 引擎配置在 `gpt_sovits_runtime/engine_config.json`；App 不把旧项目路径写进 Swift 源码。

## 当前占位或预留

- mp3、m4a、flac 会尝试用 AVFoundation 读取；mp4、mkv、mov 当前先登记，后续通过 ffmpeg 抽音轨后再完整质检。
- 真实人声/BGM 分离已接入调用器：优先读取 `gpt_sovits_runtime/tools/uvr5/uvr5_weights` 中的 UVR/BS-RoFormer `.pth/.ckpt` 权重，备选系统 `demucs` 命令。当前已内置 `HP2_all_vocals.pth`，真实分离按钮可输出 `separated/vocals.wav` 和 `separated/bgm.wav`。
- ffmpeg **占位分离** 仍保留为试跑入口：`vocals.wav` 是抽取后的训练轨，`bgm.wav` 是静音占位。
- ASR 草稿可能为空或有错字，GPT-SoVITS 训练前仍需要人工复听并校正。
- 当前 GPT-SoVITS 训练仍是 smoke 训练参数，用于验证权重产出和 TTS 使用链路；正式长训练参数后续再扩展。
- 自动预览仍是 sample 预览；只有点击 **真实生成并播放 WAV** 才会跑真实 GPT-SoVITS 推理。
- RVC 仅保留目录和 pipeline 边界，第一版不做完整训练闭环。

## GPT-SoVITS 真实推理

原生 App 已接入 GPT-SoVITS CLI 推理。配置文件：

```text
gpt_sovits_runtime/engine_config.json
```

当前格式：

```json
{
  "python": "/path/to/GPT-SoVITS/.venv/bin/python",
  "runtime_root": "/path/to/Voice_train/gpt_sovits_runtime",
  "inference_cli": "GPT_SoVITS/inference_cli.py"
}
```

`runtime_root` 是 Voice Studio 自己的可写运行目录，里面可以放 GPT-SoVITS 代码资源的软链接和 `weight.json`、缓存文件，避免把输出写回旧项目目录。

点击 **真实生成并播放 WAV** 时，App 会：

1. 写入 target text 临时文件。
2. 写入语音包参考文本临时文件。
3. 读取所选语音包里的 GPT、SoVITS、参考音频配置。
4. 通过 `Process` 调用 GPT-SoVITS `inference_cli.py`。
5. 把 `output.wav` 移入 `voice_projects/_native_tts_outputs/`。
6. 播放生成音频，并按文本缓存输出文件。

## 接入真实训练 Pipeline

后续可以逐步替换模拟 job：

1. 分离：`SeparationService` 调用 BS-RoFormer、UVR 或 Demucs，输出 `separated/vocals.wav` 和 `separated/bgm.wav`。
2. 切片：`SliceService` 只使用人声轨，按 3-10 秒生成 `dataset/slices/` 和 `dataset/manifest.csv`。
3. ASR：`ASRService` 生成草稿文本。
4. 人工校对：App 展示每个切片、波形/播放按钮和可编辑文本，用户确认后写入训练 list。
5. GPT-SoVITS：`GPTSoVITSTrainer` 用已确认标注生成特征、semantic tokens 和训练配置。
6. 监控：解析训练日志，更新 App 中的 epoch、step、loss、最近权重和日志摘要。

## 接入 RVC

RVC 作为可选增强模块，建议放在高级选项中：

```text
文本 -> GPT-SoVITS -> 可选 RVC -> wav
```

第一版不要把 RVC 作为必选步骤。只有在 GPT-SoVITS 闭环稳定后，再添加 RVC `.pth`、`.index` 训练和组合推理。
