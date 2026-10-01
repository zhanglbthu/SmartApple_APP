# Sensor Read

本仓库保存 iPhone、Apple Watch 数据采集 App 的源码、图标、配置与 Xcode 工程。
电脑端完整接收和可视化工具见 [SmartApple](https://github.com/zhanglbthu/SmartApple)；
本仓库也提供 `Tools/udp_receiver.py` 用于基础 UDP 接收。
构建产物、个人签名证书和录制数据不纳入版本管理。

在其他 Mac 上使用时，先安装 Xcode，打开 `SensorRead.xcodeproj`，并为两个 target
选择自己的 Signing Team；仓库中的 Team ID 仅为原开发环境配置。

当前版本（build 9）采用两端独立本地采集，取消 Watch 传感器实时批次及其后台排队。
WatchConnectivity 仅承载控制、状态、UWB 令牌和停止后的文件汇总。两端均需更新到新版。

原生 iOS + watchOS 多模态人体动作采集器。它可由统一的开始/结束按钮控制采集，把全部事件保存为
NDJSON，可选通过 UDP 将手机/AirPods 事件实时发送到电脑（默认关闭）。当前数据协议为 `schemaVersion: 2`，每个来源/模态都有独立的
`sequenceNumber`，电脑端可据此统计 UDP 丢包。

iPhone 与 Apple Watch 均提供全系统开始/结束按钮。Watch 按钮通过即时 WatchConnectivity 消息通知
iPhone，由 iPhone 创建统一会话并同时控制 iPhone、AirPods 和 Watch；接收端 IP、端口及可选人体
骨架和 UDP 开关沿用 iPhone App 中最后保存的设置。开始请求只做短时即时重试，30 秒过期；
停止请求持久保存、后台排队并即时重试，确认前不能开启下一段。旧会话停止请求不会停止新会话。

Watch 停止后独立完成 NDJSON/WAV，再传到手机；断连时原文件保留，连接恢复或空闲时重试。
手机按文件大小校验、暂存后替换，写入每个文件的 `*.receipt.json`，然后通知 Watch 确认。
手表“本地已停止”与“手机已确认停止”不同；文件全部确认后才显示已传到手机。
UDP 开启时也不包含手表实时事件；手机侧 UWB 仍可实时发送。两端 UWB 回调及本地记录保留，
令牌交换独立于 start，失败不再堆积旧握手消息。实际息屏测距连续性需要真机对照验证。
更新时会取消旧版本尚未完成的实时事件批次，不删除任何本地记录或整文件传输。

## 各设备模态、维度与帧率

下表的“维度”指一条事件中 `values` 的数值标量数量，不包含时间戳、序列号等元数据。`目标 Hz`
是应用向 Core Motion 请求的更新率，并非硬实时保证；“系统自适应/状态变化”表示 Apple API 不允许
应用指定固定帧率。带可选字段的数据使用范围或公式表示。

| 设备 | `sensor` | 数据内容 | 维度（标量/帧） | 读取帧率/触发方式 |
| --- | --- | --- | ---: | --- |
| iPhone | `accelerometer` | 三轴原始加速度（g） | 3 | 目标 100 Hz |
| iPhone | `gyroscope` | 三轴原始角速度（rad/s） | 3 | 目标 100 Hz |
| iPhone | `magnetometer` | 三轴原始磁场（µT） | 3 | 目标 50 Hz |
| iPhone | `device_motion` | 欧拉角 3、四元数 4、旋转矩阵 9、重力 3、用户加速度 3、角速度 3、校准磁场 3、磁场精度、航向、传感器位置 | 31 | 目标 100 Hz |
| iPhone | `audio_level` | 麦克风 RMS、峰值、线性幅度、录音进度和样本计数；原始信号另存 WAV | 6 | 约 20 Hz 遥测；WAV 为 16 kHz/单声道/16-bit PCM |
| iPhone | `audio_start` / `audio_stop` | 音频格式、同步计划时间、实际起点、延迟、时长和样本数 | 4–6 | 每段录音开始/结束各一次 |
| iPhone | `barometer` | 相对高度、气压 | 2 | 系统自适应 |
| iPhone | `absolute_altitude` | 绝对高度、精度、分辨精度 | 3 | 系统自适应 |
| iPhone | `pedometer` | 步数及可用时的距离、平均/当前配速、步频、上下楼层 | 1–7 | 系统统计更新 |
| iPhone | `motion_activity` | 静止、步行、跑步、乘车、骑行、未知、置信度 | 7 | 状态/分类更新 |
| iPhone | `location` | 经纬度、两种海拔、水平/垂直精度、速度/精度、方向/精度、楼层、来源信息 | 12–13 | 最佳导航精度，系统自适应 |
| iPhone | `heading` | 磁航向、真航向、精度、三轴原始磁场 | 6 | 无角度过滤，系统自适应 |
| iPhone | `uwb_ranging` | Phone–Watch 距离及支持时的三维方向向量 | 1–4 | 系统自适应；Phone–Watch 工程预期约 5 Hz，不保证 |
| iPhone | `body_skeleton` | 人体根节点、跟踪状态及 ARKit 全部关节三维坐标 | `4 + 3×关节数` | 可选，最高约 30 Hz，仅前台 |
| iPhone | `proximity` | 距离感应器近/远、监听状态 | 2 | 状态变化 |
| iPhone | `device_orientation` | 设备朝向枚举 | 1 | 状态变化 |
| iPhone | `battery` | 电量、充电状态 | 2 | 开始时一次，之后每 10 秒 |
| iPhone | `capabilities` | 当前硬件/API 支持项 | 18–20 | 每次开始时一次 |
| iPhone | `raw_motion_status` | 原始加速度计/陀螺仪/磁力计服务的可用性、激活状态、样本计数和重试次数 | 12 | 启动时及前 8 秒每秒一次 |
| Apple Watch | `accelerometer` | 三轴原始加速度（g） | 3 | 目标 50 Hz |
| Apple Watch | `gyroscope` | 三轴原始角速度（rad/s） | 3 | 目标 50 Hz |
| Apple Watch | `magnetometer` | 三轴原始磁场（µT） | 3 | 目标 25 Hz |
| Apple Watch | `device_motion` | 与 iPhone 相同的完整融合姿态和运动字段 | 31 | 目标 50 Hz |
| Apple Watch | `audio_level` | 麦克风 RMS、峰值、线性幅度、录音进度和样本计数；原始信号另存 WAV | 6 | 约 20 Hz 遥测；WAV 为 16 kHz/单声道/16-bit PCM |
| Apple Watch | `audio_start` / `audio_stop` | 音频格式、同步计划时间、实际起点、延迟、时长和样本数 | 4–6 | 每段录音开始/结束各一次 |
| Apple Watch | `barometer` | 相对高度、气压 | 2 | 系统自适应 |
| Apple Watch | `absolute_altitude` | 绝对高度、精度、分辨精度 | 3 | 系统自适应 |
| Apple Watch | `pedometer` | 步数、距离、配速、步频、上下楼层（按可用性） | 1–7 | 系统统计更新 |
| Apple Watch | `motion_activity` | 静止、步行、跑步、乘车、骑行、未知、置信度 | 7 | 状态/分类更新 |
| Apple Watch | `location` | 经纬度、海拔、精度、速度、方向及可选楼层 | 10–11 | 最佳导航精度，系统自适应 |
| Apple Watch | `heading` | 磁航向、真航向、精度、三轴原始磁场 | 6 | 无角度过滤，系统自适应 |
| Apple Watch | `uwb_ranging` | 与配对 iPhone 的距离 | 1 | 系统自适应；工程预期约 5 Hz，不保证 |
| Apple Watch | `heart_rate` | 心率（bpm） | 1 | HealthKit 实时更新，非固定 Hz |
| Apple Watch | `active_energy` / `workout_distance` / `workout_steps` | 累计能量、距离或步数；每种为独立事件 | 每种 1 | HealthKit 统计更新 |
| Apple Watch | `walking_speed` / `walking_step_length` | 步行速度或步长；每种为独立事件 | 每种 1 | HealthKit 在支持的步行状态下更新 |
| Apple Watch | `walking_asymmetry` / `walking_double_support` | 步态不对称率或双支撑率；每种为独立事件 | 每种 1 | HealthKit 在支持的步行状态下更新 |
| Apple Watch | `stair_ascent_speed` / `stair_descent_speed` | 上楼或下楼速度；每种为独立事件 | 每种 1 | HealthKit 在支持的楼梯活动下更新 |
| Apple Watch | `running_speed` / `running_power` | 跑速或跑步功率；每种为独立事件 | 每种 1 | HealthKit 在支持的跑步状态下更新 |
| Apple Watch | `running_vertical_oscillation` / `running_ground_contact` / `running_stride_length` | 垂直振幅、触地时间或步幅；每种为独立事件 | 每种 1 | HealthKit 在设备和跑步状态支持时更新 |
| Apple Watch | `battery` | 电量、充电状态 | 2 | 开始时一次，之后每 10 秒 |
| Apple Watch | `capabilities` | 当前硬件/API 支持项 | 15 | 每次开始时一次 |
| Apple Watch | `raw_motion_status` | 原始加速度计/陀螺仪/磁力计服务的可用性、激活状态、样本计数和重试次数 | 12 | 启动时及前 8 秒每秒一次 |
| Apple Watch | `control_event` | Watch 全系统按钮的开始、结束、执行结果和点击前手机状态 | 4 | 每次点击开始/结束时一次 |
| 兼容 AirPods | `head_motion` | 与 `device_motion` 同结构的融合头部姿态和运动 | 31 | 系统自适应，API 不提供 Hz 设置 |
| 兼容 AirPods | `headphone_activity` | 静止、步行、跑步、乘车、骑行、未知、置信度 | 7 | iOS 18+、兼容型号，分类更新 |
| 兼容 AirPods | `headphone_status` | 耳机状态枚举 | 1 | iOS 18+、兼容型号，状态变化 |

Watch 端按照原始采样时间戳本地保存，不再向 iPhone 发送实时批次。HealthKit 指标取决于手表型号、佩戴质量和运动状态，并非
每次会话都会产生。Apple 不开放 AirPods 每只耳塞的原始 IMU，只提供融合后的头部运动。

每次开始采集后的前 8 秒，iPhone 和 Watch 会对 raw IMU 服务做有限重试，并写入
`raw_motion_status` 事件。离线检查时应确认 `gyroscope_samples`、`magnetometer_samples` 大于 0；
若仍为 0，表示系统没有提供独立 raw 服务，不能用 `device_motion` 中的融合角速度/磁场字段冒充原始数据。

## 真机运行

本机已安装 Xcode，工程也已生成。连接已开启开发者模式的 iPhone 后：

1. 打开 `SensorRead.xcodeproj`。
2. 在顶部运行设备中选你的 iPhone。
3. 确认 `SensorRead` 与 `SensorReadWatch` target 的 Signing Team 都是你的 Personal Team。
4. 点击 Run。首次点击“开始采集”时，允许运动与健身、麦克风、定位、相机（仅骨架开关开启时）、
   本地网络和健康权限。iPhone 与 Watch 都会分别询问麦克风权限。
5. Watch 已与这台 iPhone 配对时，Watch App 会随 iPhone App 一起安装；也可从 Watch 上单独启动。

修改 `project.yml` 后运行 `Tools/prepare_project.sh` 重新生成工程。模拟器演示可运行：

```bash
Tools/run_simulator_demo.sh
```

模拟器没有真实 IMU、心率、UWB 或 AirPods，因此 Debug 模拟器版本只生成带模拟器来源标记的演示数据。

## 数据与电脑接收

如需实时观察，在 App 中开启 UDP 并填写电脑的局域网 IP 与端口（默认 9000）。
关闭时仍完整本地采集。每个 UDP 数据包是一条 UTF-8 JSON：

```json
{"schemaVersion":2,"sessionID":"...","source":"iphone","sensor":"accelerometer","timestampUnixNs":0,"monotonicSeconds":0,"sequenceNumber":0,"values":{"x_g":0,"y_g":0,"z_g":-1}}
```

`timestampUnixNs` 用于跨设备时间对齐，`timestampMonotonicS` 用于本设备内稳定计时，`source` 为
`iphone`、`apple_watch` 或 `airpods`。iPhone 和 Watch 的音频使用同一个由 iPhone 下发的计划起点；
`audio_start` 记录实际文件第 0 个样本对应的 Unix 时间，离线工具据此与 IMU 对齐。

原始音频不经过 UDP，而是保存为 16 kHz、单声道、16-bit PCM WAV；UDP 只传输约 20 Hz 的
`audio_level` 用于实时观察。Watch 同时本地保存完整事件 NDJSON，停止采集后自动将 Watch WAV 和
Watch NDJSON 传给 iPhone，避免 UDP 丢包影响离线序列。传输可能在停止后延迟数秒完成。

本地文件位于 App 的 `Documents/Recordings`。每次新采集会创建一个
`yyyy-MM-dd_HH-mm-ss_<session前8位>` 子目录，其中集中保存该序列的
iPhone/Apple Watch NDJSON、两端 WAV 音频和 `session-info.json` 时间清单，
可从“浏览和分享文件”按会话查看或导出。旧版本产生的顶层文件会原样保留。
本版同时开启了 iOS 文件共享与就地文档访问：连接 iPhone 后可在 Finder 的“文件”页面打开
Sensor Read，并复制 `Recordings` 文件夹；也可在 iPhone“文件”App 的“我的 iPhone/Sensor Read”中访问。
电脑端用法见相邻目录 `sensor_receiver/README.md`。

## API 与后台限制

- iPhone 锁屏后，普通 App 不能保证无限期执行任意 Core Motion 和 UDP 代码。本项目使用真实后台定位维持合规的后台活动；必须授予“始终允许”，系统仍可能回收进程。
- Watch 使用 `HKWorkoutSession` 获得较可靠的息屏持续运行；系统会显示运动状态并增加耗电。
- ARKit 骨架依赖后置相机，只能在前台工作；锁屏后停止。
- UWB 是 Phone–Watch 间的测距/方向估计，不是人体关节定位，并要求两端硬件和系统均支持。
- iOS/watchOS 26 上，第二代 UWB 的 Phone–Watch 组合使用标准精确测距；工程刻意不启用扩展距离模式，以规避会话启动后无距离更新的系统问题。iPhone 15 Pro + Apple Watch Series 9 实测约 6.6 Hz，实际频率由系统动态决定。
- 用户强制退出 App、设备重启或系统终止后，第三方 App 不能任意自动重启采集。
- 音频后台模式允许已经在前台启动的录音继续，但系统仍会显示麦克风隐私指示，用户强制退出后不会自动恢复。
- Watch 音频与 HealthKit 心率能否长期并行会受到系统资源调度和设备状态影响；真机实验应同时检查
  `audio_level` 与 `heart_rate` 是否持续。WatchKit 标准录音界面会中断心率，本项目未使用该界面，
  而是使用 `AVAudioRecorder` 直接写 WAV。
- 血氧、ECG、腕温等 HealthKit 数据不是可由普通 App 任意触发的高频实时流，因此没有伪装成动作捕捉实时模态。

实现依据为 Apple 的 [Core Motion](https://developer.apple.com/documentation/coremotion/)、
[AirPods Motion](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)、
[AirPods Activity](https://developer.apple.com/documentation/coremotion/getting-motion-activity-data-from-headphones)、
[HealthKit Workout Session](https://developer.apple.com/documentation/healthkit/hkworkoutsession)、
[Nearby Interaction](https://developer.apple.com/documentation/nearbyinteraction)、
[ARKit Body Tracking](https://developer.apple.com/documentation/arkit/arbodyanchor) 和
[Background Modes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes)、
[AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder) 文档。

## 导出给 WatchHAR

[WatchHAR](https://github.com/SPICExLAB/WatchHAR) 的公开预处理流程使用 1 秒、50 Hz 的 6 轴 IMU
窗口和 16 kHz 原始音频，并在预处理时降采样到 1 kHz、生成 64-bin Mel 频谱。本项目保留 16 kHz
原始 PCM，电脑端导出器负责按 `audio_start` 精确裁剪并把 IMU 重采样到 50 Hz。

先将同一会话的 `apple_watch-events-<session>.ndjson` 与
`apple_watch-audio-<session>.wav` 复制到电脑同一目录，然后运行：

```bash
cd /Users/zhanglb/WorkSpace/research/project/sensor_receiver
conda run --no-capture-output -n mobileposer python export_watchhar.py \
  --events recordings/apple_watch-events-<session>.ndjson \
  --source apple_watch --participant 1 --context Kitchen \
  --activity Chopping --trial 1 --output-dir watchhar_raw
```

输出文件名遵循 WatchHAR 的 `Participant---Context---Activity---Trial.pkl` 约定，pickle 中包含
`IMU`（`N×6`，acc XYZ + gyro XYZ）和 `Audio`（16 kHz `int16`），可放入 WatchHAR 的原始数据目录
后执行其 `preprocess.py`。旁边的 JSON 文件记录对齐起点、时长、列顺序和原始文件路径。
