# HANDOFF — GenieSim 数据采集 → LeRobot 数据集（写给零上下文的新会话）

最后更新：2026-09-09。所有后台任务已结束，无采集容器在跑。

---

## 1. 当前任务目标

在 GenieSim（Isaac Sim 5.1，G2 双臂机器人）里**自动采集**桌面积木操作数据，归档到 NAS，用 **ERSI-Bench** 的转换器转成 **LeRobot v2.1** 数据集，供 **openpi / π0.5** 训练（用户已放弃 ACT）。评测走 ERSI-Bench 的 corobot WebSocket 协议。

分工（用户拍板的）：
- **采集** 在 `/home/tianran/Repos/GenieSim`（本仓库）
- **转换** 在 `/home/tianran/Repos/ERSI-Bench`（GenieSim 的 fork，各自演化过；**用户明确要求不要改它的代码**，除非他说动）
- 原始数据和数据集都在 **NAS**

已采两个任务：`pick_biggest_block` 100 条、`pick_smallest_block` 25 条。用户正在考虑下一个任务（见 §7）。

---

## 2. 已完成的内容

### 环境
- RTX 5090 D v2（Blackwell **sm_120**）、driver 580、CUDA 13。Docker + NVIDIA Container Toolkit 装好。
- Isaac Sim 5.1 数据采集镜像 `registry.agibot.com/genie-sim/geniesim3-data-collection:latest`，`dockerfile` 里 `TORCH_CUDA_ARCH_LIST="12.0"`，已重建。
- cuRobo 的 LBFGS CUDA kernel 在 sm_120 上起不来 → `config/curobo/configs/task/{gradient,finetune}_trajopt.yml` 里 `use_cuda_kernel: False`（容器启动时 `entry_point.sh` 会把这个目录拷进 site-packages）。ERSI 用的是另一套绕法（关 cuda_graph + 跳过 warmup），**故意不对齐**，我们的更快。
- NAS：`192.168.110.60:/volume1/data` → `/nas`，`/etc/fstab` 里 systemd automount（`vers=3,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600`）。`~/NAS` → `/nas/users/tianran`。
- `HF_HOME=/nas/users/tianran/HuggingFace`（用户 shell 里设的；新会话的 shell 可能看不到，用绝对路径）。
- conda 环境：`geniesim`（采集 CLI、转换）、`lerobot`（lerobot **0.3.3** editable，来自 `/home/tianran/Repos/lerobot` 分支 `v21-act`，+ torchcodec 0.16 + torch 2.11 cu130；这是最后一个原生 v2.1 的版本）。

### 采集流程（全部在 `source/data_collection/`，已提交 `4c93442`）
- `omniagent.py`：布局**在线逐条生成**（不再预生成整批），成功才保留数据+布局，失败当场删；**编号只在成功后前进**，所以 episode 编号连续无空档；编号从本地录制目录 + 归档目录（只读挂载）扫最大值接续。录制目录名沿用上游的方括号格式 `[<task>_N]`。
- `run_data_collection.py`：不再预生成；支持 `recording_setting.num_of_success`（够了提前停）。
- `run_data_collection.sh`：录制根目录可由 `GENIESIM_RECORDING_ROOT` 指定（bind-mount 到容器的 `recording_data`），归档目录 `GENIESIM_RECORDING_ARCHIVE` 只读挂到 `recording_archive`。
- `command_controller.py`：**修复 republish 参数**（根因见 §8/§9），bag 排除 `/out*` 和原始 `_rgb`。
- `extract_ros_bag.py`：只认 `format` 含 jpeg 的 CompressedImage。
- `data_collection_entrypoint.sh`：`umask 000`（容器写的文件宿主机才能删/搬）。
- 与 ERSI 对齐：`robot_cfg/G2_omnipicker_fixed_dual.json`（head 相机 **1280×800**、`closed_velocities` -1.5）、`place.py`、`rotate.py`、`grpc_server.py`。
- `scripts/collect.sh`（**未提交的 29 行改动**：并行归档 + `SRC_TASK` 可配）：循环采集直到 NAS 上够 N 条；每轮起一次容器跑 `BATCH` 次尝试；轮末**后台并行** rsync 到 NAS（每集一个进程）、布局按集搬走、本地不留；轮间检查 `STOP` 文件。

### 数据（NAS，`~/NAS/GenieSim/` 是 `data_collection/` 的镜像）
```
~/NAS/GenieSim/
├── recording_data/pick_biggest_block/    [pick_biggest_block_0]…[_99]   100 集，116 GB，编号连续
├── recording_data/pick_smallest_block/   [pick_smallest_block_0]…[_24]   25 集
├── saved_task/pick_biggest_block/        pick_biggest_block_0…_99.json   与 episode 1:1
└── saved_task/pick_smallest_block/       _0…_24.json
```
全部 head 1280×800、hand 1280×1056、**0 坏帧**、有 aligned_joints.h5。约 10% 的集某一路相机带高斯噪声增广（`noised_probability: 0.1`，这是有意的）。

### LeRobot 数据集
`/nas/users/tianran/HuggingFace/lerobot/ERSI/pick_biggest_block`（repo_id `ERSI/pick_biggest_block`）：v2.1，100 集 / 25991 帧 / 30 fps，`observation.images.top_head [800,1280,3]`、`hand_left/right [1056,1280,3]`、`observation.state [159]`、`action [40]`。验收全过（见 §5）。**smallest 还没转**。

---

## 3. 修改过的文件

| 文件 | 状态 | 说明 |
|---|---|---|
| `source/data_collection/scripts/collect.sh` | **未提交**（+18/−11） | 并行归档、`SRC_TASK` 可配。已提交版本是串行归档 |
| `source/data_collection/tasks/ERSI/pick_smallest_block/` | **未提交**（untracked） | smallest 任务副本，脚本自动生成 |
| 以下均在提交 `4c93442`： | | |
| `client/agent/omniagent.py` | 已提交 | 在线布局、编号规则 |
| `scripts/run_data_collection.py` / `.sh` | 已提交 | 见 §2 |
| `server/command_controller.py` | 已提交 | republish 修复、bag 排除 |
| `server/recording/extract_ros_bag.py` | 已提交 | jpeg 守卫 |
| `scripts/data_collection_entrypoint.sh` | 已提交 | umask 000 |
| `config/robot_cfg/G2_omnipicker_fixed_dual.json` | 已提交 | 1280×800、closed_velocities |
| `config/curobo/configs/task/*.yml` | 已提交 | sm_120 绕法 |
| `dockerfile` | 已提交 | arch 12.0 |
| `client/planner/action/place.py`、`rotate.py`、`server/grpc_server.py` | 已提交 | 从 ERSI 整文件拷贝 |
| `tasks/ERSI/pick_biggest_block/g2/pick_biggest_block.json` | 已提交 | 任务副本（脚本每轮会改它的 `num_of_episode`/`num_of_success`） |
| `.gitignore` | 已提交 | 加 `recording_archive` |
| `source/geniesim_benchmark/.../agibot_to_lerobot.py` | **已回退到 HEAD**，改动在 **`git stash@{0}`** | 坏帧顶替、真实图像统计、`--episode-list`。**用户决定 GenieSim 不再维护转换器** |

ERSI-Bench：工作区**干净**，一行没改。lerobot 仓库：分支 `v21-act` = tag `v0.3.3`。

宿主机其它：`~/.config/bash/50-geniesim.bash`（`gsinto` 进容器带 starship）、`/etc/fstab` NAS 行、`~/NAS` 软链接。

---

## 4. 运行环境和启动方法

```bash
cd /home/tianran/Repos/GenieSim

# 采集（TARGET 是 NAS 上的总数，含已有的）
TARGET=150 ./source/data_collection/scripts/collect.sh                                   # biggest 再采 50
TASK=pick_smallest_block SRC_TASK=pick_building_block_of_specific_size_small TARGET=50 \
  ./source/data_collection/scripts/collect.sh                                            # smallest 再采 25

# 放后台
setsid nohup env TARGET=150 ./source/data_collection/scripts/collect.sh > /tmp/collect.log 2>&1 < /dev/null &

# 优雅停止（本轮跑完、归档完自动退出）
touch source/data_collection/recording_data/<task>/STOP

# 转换（在 ERSI-Bench，转换器是他们原版）
rm -rf /nas/users/tianran/HuggingFace/lerobot/ERSI/<task>        # 它不清旧目录
cd /home/tianran/Repos/ERSI-Bench && source scripts/ersibench_env.sh
geniesim dataset convert agibot-to-lerobot \
    --agibot-dir /nas/users/tianran/GenieSim/recording_data/<task> \
    --output-dir /nas/users/tianran/HuggingFace/lerobot/ERSI/<task>
# 转完必做：info.json 的 top_head shape 从 [400,640,3] 改成 [800,1280,3]（ERSI 写死了旧值）
```

参数：`BATCH`（默认 5，每轮尝试次数=容器复位周期）、`MAX_ROUNDS`（默认 25，保险丝；采 80 条要设 60）、`NAS_ROOT`、`REC`。

时间：一轮 ≈ 6 min（100 s 起容器 + 5 次尝试），成功率 50–80%，20 条约 30 min，80 条约 3.5 h。归档在后台与下一轮重叠。

验收脚本（scratchpad，随会话可能丢，逻辑简单可重写）：`verify_lerobot.py <dataset_dir>` —— 按 `info.json` 模板解析每个视频、`-count_packets` 核对帧数 = parquet 行数、shape 声明 = 视频实际尺寸。

---

## 5. 已经验证的结果

- 采集流水线：140 条采集（biggest 100 + smallest 25 + 验证集）零坏帧、编号连续、布局 1:1、本地中转清空。
- 并行归档：7 集并行 < 一轮采集时间，第 3 轮起零等待（串行时一集要 4 min，追不上）。
- republish 修复后 bag 里只有 `/<cam>_rgb_compressed [CompressedImage]`，`/out/*` 被排除。
- ERSI 转换器产物用 lerobot 0.3.3 端到端加载 OK：`LeRobotDataset("ERSI/pick_biggest_block", root=...)`，`delta_timestamps` 取 50 步动作块，第 0 集末帧可读，图像张量 `(3, 800, 1280)`。
- openpi 的 lerobot pin（`0cf86487`，2025-05-28，`CODEBASE_VERSION v2.1`）与本数据集格式一致，可直接用。
- `BATCH=5` 五轮实测 13/25、后 20 轮 ~70%：第 4、5 次尝试经常成功，拐点不再是 3。

---

## 6. 尚未解决的问题

1. **ERSI 转换器的两个自身问题**（与采集无关，用户说"先不修"）：
   - 图像统计写死为零（`agibot_to_lerobot.py:665`）→ lerobot 聚合成 NaN。**不用 ACT 就无所谓**（openpi 自己归一化）。
   - head shape 写死 `[400,640,3]`（`:800`）→ 每次转完手改 `info.json`。
2. **多任务混合数据集做不了**：ERSI 转换器 `task_index` 全写 0（`:462`）、`tasks.jsonl` 只写第一集的任务名（`_dataset_task_name`）、`detect_episodes` 只扫一层。要混 biggest + smallest 需改约 15 行（多目录输入、每集按 `data_info.json` 的 `english_task_name` 分配 `task_index`、写全部任务）。**用户尚未批准改 ERSI**。
3. `pick_smallest_block` 25 条还没转成 LeRobot。
4. openpi 侧：`observation.state` 159 维 / `action` 40 维里大部分评测时拿不到（corobot 协议只给关节 14 + 夹爪 2 + 头 3 + 腰 5 + 末端位姿），要在 openpi 的 `DataConfig`/`Inputs` 里挑维度；维度布局在 ERSI 转换器 `agibot_to_lerobot.py:70-92` 的常量块。
5. NAS 写慢的根因未处理：NFS `WRITE` 平均 **82.8 ms**（Synology 导出是 sync 模式，每个写请求等落盘）。并行归档是绕过去的；治本是 DSM → 共享文件夹 → NFS 权限 → 勾"异步"。
6. Isaac Sim 偶发启动段错误（`data_collector_server.py` 起来 51 ms 崩），100 条里出现 1 次，重启即好；`collect.sh` 的 60 秒守卫会把它当配置故障 `die`，需要手动重启脚本。
7. ERSI 评测侧：`set_bottle_upright_g2`、`rotate_and_place_bottle_g2` 没注册打分步骤（`eval_utils.py` 的 `TASK_STEPS`），README 写的默认配置 `g2op_if_pick_block_color.yaml` 不存在。评测我们的任务需要自建 `eval_tasks/*.json` + yaml。

---

## 7. 下一步计划

用户最后在选下一个任务，已调研三个：

| 任务 | 上游有无 | 结论 |
|---|---|---|
| **PlacePotStove**（双臂抬锅放灶台） | 无 | 采集框架每个 stage 单臂、无双臂原语；锅无抓取标注；无灶台资产。ERSI 评测有 `hold_pot` 但无场景。基本不可行，除非 VR 遥操作（ERSI 有 `teleop/vr_server.py`） |
| **PutObjIntoDrawer**（左臂开抽屉→放积木→关抽屉） | 无 | `pull` 只在 `stage.py:230` 分类里，**没实现**；关节柜子有（`benchmark_cabinet_016/017/018`，含 PrismaticJoint，016/017 有 interaction 标注但需确认是把手）；server 有关节 API（`GetPartDofJoint`）。需写一个"抓把手→沿关节轴平移→松开"原语（~100 行）+ 抽屉内放置标注 + 模板。一天量级 |
| **ArrangeBlocks 从小到大排一排** | 无 | 用现成原语可搭：以 `tasks/ERSI/pick_biggest_block/g2/pick_biggest_block.json` 为底（用户明确说**不要以 stack_bowls 为底**），改 `task_related_objects`（抽 3 块不同尺寸档）、`stages`（多段 pick/place）、`task_metric`（`is_object_relative_position_in_target`）、prompt。两种目标位置方案：A 三个 `coaster` 当固定槽位（`fix_objects`，零代码）；B `pre_place_pose_offset` 相对前一块偏移（`place.py:65/345`，**要先确认偏移是在物体局部系还是世界系**，读 `Action` 怎么用第三个参数）。半天 |

其它待办：转 smallest；决定是否改 ERSI 转换器（多任务 + shape + 统计）；openpi `DataConfig`；评测配置。

---

## 8. 失败过的方法及原因

| 方法 | 为什么失败 |
|---|---|
| 直接把 NAS 目录 bind-mount 成录制目录 | 录制码率 ≈ 480 MB/s（三路 32FC1 原始深度占 94%），NAS 只 28–111 MB/s；`ros2 bag record` 收尾刷不完被 SIGKILL（`command_controller.py` SIGINT 后只等 5 s），`metadata.yaml` 写不出来，后处理必败。**所以录本地、归档 NAS** |
| 串行 rsync 归档（同步或异步都一样） | NFS 每个 WRITE 83 ms，一集 2400 个文件 ≈ 4 min，一轮 5 集 20 min > 采集 6 min，异步也追不上。**改成每集一个 rsync 并行** |
| 用 SIGTERM 停 `collect.sh` | 信号落在归档阶段会打断 rsync（能续传但脏）；落在采集阶段要等整轮。**改用 STOP 文件** |
| 让 `_next_layout_index` 也扫 `saved_task` | 用户手动删过 saved_task，扫它反而不可靠；录制目录才是权威，且布局编号不可能高过录制 |
| 每次尝试都占一个编号 | 失败留空档（8、9 缺）；用户要求连续。**改成成功才 +1**；历史空档用 `compact_ids.py` 压过一次 |
| 用 `frame_state.json` 的 `target_pose` 匹配 episode 和布局 | 那是抓取位姿不是物体中心，最近/次近距离几乎一样。**用 `state.json` `frames[0].objects[*].pose` 的 XY** 才能精确匹配（Z 有 0.094 m 沉降偏移） |
| 在采集侧靠 `opencv` 模式修坏帧 | 坏 payload 解码得 None → 直接跳过该帧不写文件 → `camera/` 出空洞，ffmpeg `%d` 序列到第一个缺号就停，更糟 |
| 用干净容器测 republish 参数变体 | 插件是收到第一帧才懒 advertise，没图流的测试看不到 `/out/theora`、`/out/zstd`，结论误导。**必须用真实录制的 bag 验证** |
| `docker exec` 看容器 umask | exec 起的是新 shell，不继承 entrypoint 的 umask，读数无意义；看新建文件的权限才准 |
| `pkill -f 'collect.sh'` / `pkill -f 'agibot-to-lerobot'` | 模式匹配到自己的 `bash -c` 包装 shell，把自己杀了（exit 144）。用 `pgrep -f '^bash \./source/data_collection/scripts/collect\.sh'` 这种锚定模式 |
| 把 GenieSim 和 ERSI 的转换器合并 | 两边各自演化：ERSI 有夹爪编码还原 + 指令元数据（我们没有），我们有坏帧顶替 + 真实统计 + `--episode-list`（ERSI 没有）。用户定：转换归 ERSI，GenieSim 那份回退 |

---

## 9. 绝对不要重复踩的坑

1. **脚本在跑的时候不要编辑它**（`collect.sh`、任何 bash 脚本）。bash 按字节偏移增量读，中文注释一改长度就错位，会出现 `line 203: list: command not found` 之类的鬼错误。改 Python 文件是安全的（容器启动时才加载，下一轮生效）。
2. **`GENIESIM_DIAG_KEEP_RAW_RGB` 已删除**，别再录原始 RGB：五路原始流 ≈ 1 GB/s，只有本地 NVMe 吃得下；诊断用的那次 mcap 23 GB。
3. **坏 JPEG 的根因是 republish 参数**，不是编码器竞争、不是 NFS：Jazzy 忽略位置参数 `raw compressed`，`_out_transport` 不是参数 → 发全部插件到共享的 `/out/<plugin>`，提取器把 `/out/zstd` 当 JPEG（`format='zstd'`，payload 头是 高/宽/step/"rgb8"/gzip）。修法 `-p out_transport:=compressed --remap /out/compressed:=/<cam>_rgb_compressed`，且 bag 排除 `^/out(/|$)`。ERSI-Bench 的采集代码逐字相同，**同样有这个 bug**（没修）。
4. **容器用户是 uid 1234**：它建的目录宿主机删不掉、跨父目录移不动（同父目录改名可以）。已用 `umask 000` 解决新文件；老目录用 `docker run --rm -u 1234:1234 -v <dir>:/x <image> rm -rf ...` 处理。另：录制目录不存在时 docker 会以 **root** 把挂载点建出来，容器就写不进去 → `collect.sh` 前置已 `mkdir -p` + `chmod a+rwX` 并检查。
5. **`num_of_episode` 是尝试次数不是产量**；失败集被 server `shutil.rmtree`。仿真进程有状态累积，跑多了成功率归零 → 靠重启容器复位，`BATCH` 别开大（早期拐点 3，配置改后 5 合理）。
6. **NAS 上的 LeRobot 数据集要先删再转**：ERSI 转换器不清目录，episode 数变少时旧文件残留。
7. **ERSI 转换器写死 head shape `[400,640,3]`**，我们的数据是 1280×800，转完必须改 `info.json`（或改它第 800 行——需用户批准）。
8. **用户明确的约束**：不要软链接（symlink）；不要改 ERSI-Bench 代码（除非批准）；采集只在 GenieSim；NAS 布局必须和 `data_collection/` 一致（`recording_data/<task>/[<task>_N]`、`saved_task/<task>/<task>_N.json`）；录制目录名保留上游的中括号；编号连续；`rotate.py` 里 ERSI 的 DEBUG 日志保留。
9. **Ponytail 模式在会话中启用过**（用户调了 `/ponytail`）：他偏好最短能跑的改动，删过零产出早停、诊断插桩、选臂旋钮、统计计数；新会话别把这些加回去。
10. `list_done` 的 glob 必须用正则收紧到 `^\[<task>_[0-9]+\]`，否则 `pick_biggest_block_v2` 这类前缀相同的任务会被误数/误归档。

---

## 10. 关键输出、日志和路径

| 内容 | 路径 |
|---|---|
| 原始 episode（NAS） | `/nas/users/tianran/GenieSim/recording_data/<task>/[<task>_N]/`（= `~/NAS/GenieSim/...`） |
| 布局 JSON（NAS） | `/nas/users/tianran/GenieSim/saved_task/<task>/<task>_N.json` |
| LeRobot 数据集 | `/nas/users/tianran/HuggingFace/lerobot/ERSI/pick_biggest_block/` |
| 采集日志（宿主机脚本） | `/tmp/collect100b.log`、`/tmp/collect_small25.log` 等（`collect.sh` stdout） |
| 容器侧日志（**每次容器运行覆盖**） | `source/data_collection/logs/<task>/{run_data_collection.log, data_collector_server.log, run_data_collection_sh.log}` |
| Isaac Sim / Kit 日志与缓存 | `~/docker/isaac-sim/{logs,cache,config,data,pkg}`（bind mount 进容器） |
| 转换器改动（已回退） | `git stash show -p stash@{0}`（GenieSim 仓库） |
| 会话 scratchpad（可能已被清理） | `/tmp/claude-1000/-home-tianran-Repos-GenieSim/5e96d2f2-dd7d-4081-b28b-c1b781e169e5/scratchpad/`：`verify_lerobot.py`、`compact_ids.py`、`diag_zstd.py`、`diag_compare.py`、各版 `collect.sh.*.bak` |
| 每集内部结构 | `aligned_joints.h5`（159/40 维状态动作）、`camera/<n>/{head,hand_left,hand_right}_color.jpg` + depth png + 双目、`state.json`（含每帧物体位姿）、`data_info.json`（`english_task_name`）、`recording_info.json`（相机 `noised` 标记）、`task_result.json` |
| ERSI 评测入口 | `ERSI-Bench/scripts/run_benchmark.sh --config <yaml> --infer-host 127.0.0.1:8999`；协议在 `benchmark/policy/corobotpolicy.py`，离线校验 `scripts/check_inference.py` |
| openpi 的 lerobot pin | commit `0cf864870cf29f4738d3ade893e6fd13fbd7cdb5`（模块路径 `lerobot.common.datasets`，与 0.3.3 的 `lerobot.datasets` 不同） |
