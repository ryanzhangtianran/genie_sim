#!/usr/bin/env bash
# 采集 N 条**成功**的 episode，归档到 NAS。转 LeRobot 在 ERSI-Bench 做。
#   TARGET=20 ./collect.sh
#   touch recording_data/<task>/STOP    # 本轮结束、归档完后退出
#
# 为什么要循环：num_of_episode 是尝试次数，失败的 episode 会被 server 删掉，
# 所以只能一轮轮补，每轮结束重新数磁盘上的成品。

set -euo pipefail

REPO=/home/tianran/Repos/GenieSim
GENIESIM=/home/tianran/Miniforge/envs/geniesim/bin/geniesim
PY=/home/tianran/Miniforge/envs/geniesim/bin/python
DC="$REPO/source/data_collection"

SRC_TASK="${SRC_TASK:-pick_building_block_of_specific_size_big}"   # 上游模板
TASK="${TASK:-pick_biggest_block}"                    # 我们的副本(不动上游)

# 录制必须在本地盘（mcap ≈ 480 MB/s，NAS 只有 28~111 MB/s，直录会让 recorder 收尾被
# SIGKILL）。每轮结束把提取完的 episode 归档到 NAS，NAS 侧是 data_collection/ 的镜像。
# 归档目录只读挂进容器，让编号接着排。
NAS_ROOT="${NAS_ROOT:-$HOME/NAS/GenieSim}"
REC_LOCAL="$DC/recording_data/$TASK"
REC="${REC:-$NAS_ROOT/recording_data/$TASK}"
SAVED_LOCAL="$DC/saved_task/$TASK"
SAVED_NAS="$NAS_ROOT/saved_task/$TASK"
export GENIESIM_RECORDING_ROOT="$REC_LOCAL"
export GENIESIM_RECORDING_ARCHIVE="$REC"
TARGET="${TARGET:-10}"
MAX_ROUNDS="${MAX_ROUNDS:-25}"
# 一轮尝试几次 = 容器复位周期：仿真进程有状态累积，跑多了成功率归零。实测拐点 3~10。
BATCH="${BATCH:-5}"
MIN_FREE_GB="${MIN_FREE_GB:-80}"                      # 单集原始 mcap 可达 10 GB

SRC_JSON="$DC/tasks/geniesim_2025/pick_building_block_of_specific_size/g2/${SRC_TASK}.json"
MY_DIR="$DC/tasks/ERSI/${TASK}/g2"
MY_JSON="$MY_DIR/${TASK}.json"

log() { printf '\033[36m[collect]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[collect] ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 前置检查
[ -f "$SRC_JSON" ] || die "找不到上游任务模板：$SRC_JSON"
mkdir -p "$REC" 2>/dev/null && [ -w "$REC" ] || die "归档目录不可写：$REC（NAS 挂了吗：findmnt /nas）"
# 目录不存在时 docker 会以 root 建挂载点，容器用户就写不进去了
mkdir -p "$REC_LOCAL"; chmod a+rwX "$REC_LOCAL" 2>/dev/null || true
[ -w "$REC_LOCAL" ] || die "本地录制目录不可写：$REC_LOCAL，重建：rmdir $REC_LOCAL && mkdir -m 777 $REC_LOCAL"
mkdir -p "$SAVED_NAS"
# 任务发现按文件名 stem 匹配，同名即歧义，每轮秒退
[ "$(find "$DC/tasks" -name "${TASK}.json" | wc -l)" -le 1 ] || die "任务名 '${TASK}' 不唯一：$(find "$DC/tasks" -name "${TASK}.json" | tr '\n' ' ')"

# ---------------------------------------------------------------- 任务副本
if [ ! -f "$MY_JSON" ]; then
    log "创建任务副本 $MY_JSON"
    mkdir -p "$MY_DIR"
    $PY - "$SRC_JSON" "$MY_JSON" "$TASK" <<'EOF'
import json, sys
src, dst, name = sys.argv[1:4]
d = json.load(open(src))
d["task"] = name                       # 决定 recording_data/[<task>_<n>]/ 的目录名
json.dump(d, open(dst, "w"), ensure_ascii=False, indent=4)
EOF
fi

# 本任务可用的 episode（有 aligned_joints.h5 = 后处理完成）：本地 + 归档，按编号去重、
# NAS 优先（先列、sort -s 保序）、数字序。目录名是上游格式 [<task>_N]，尾部数字兼容
# 撞名时 server 追加的后缀；正则收紧到编号，避免前缀相同的任务被误数。
list_done() {
    local d b
    for d in "$REC"/\[${TASK}_* "$REC_LOCAL"/\[${TASK}_*; do
        [ -d "$d" ] || continue
        b=$(basename "$d")
        [[ "$b" =~ ^\[${TASK}_([0-9]+)\]([0-9]*)$ ]] || continue
        [ -f "$d/aligned_joints.h5" ] || continue
        printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]:-0}" "$d"
    done | sort -s -k1,1n -k2,2n | awk -F'\t' '!seen[$1 FS $2]++' | cut -f3-
}

# 归档：每集一个子进程并行搬（NFS 小文件是 close→COMMIT 延迟瓶颈，靠并发摊平），
# 先拷再删源（rsync 幂等，中断重跑即续传）。mcap 不搬、留本地。布局按 episode 逐个搬：
# 归档在后台跑，下一轮正往同一个 saved_task/<task>/ 写新布局，不能整目录同步。
archive_one() {   # $1 = 本地 episode 目录
    local d=$1 b lay
    b=$(basename "$d")
    [[ "$b" =~ ^\[${TASK}_([0-9]+)\]([0-9]*)$ ]] || return 0
    lay="$SAVED_LOCAL/${TASK}_${BASH_REMATCH[1]}.json"
    rsync -aW --inplace --exclude='*.mcap' "$d/" "$REC/$b/" || { log "✗ 归档失败：$b"; return 1; }
    find "$d" -mindepth 1 -not -name '*.mcap' -delete 2>/dev/null
    rmdir "$d" 2>/dev/null && log "  $b 归档完成" || log "  $b 归档完成（本地还留着 mcap 或删不掉）"
    [ -f "$lay" ] && { rsync -a "$lay" "$SAVED_NAS/" && rm -f "$lay"; } || log "  ⚠️  $b 没有对应布局"
}
archive_done() {
    local d pids=() rc=0
    for d in "$REC_LOCAL"/\[${TASK}_*; do
        [ -d "$d" ] && [ -f "$d/aligned_joints.h5" ] || continue
        archive_one "$d" & pids+=($!)
    done
    for p in "${pids[@]:-}"; do [ -n "$p" ] && { wait "$p" || rc=1; }; done
    [ "$rc" -eq 0 ] || die "本轮归档有失败（见上面），中止"
}

# 归档后台跑、和下一轮重叠；同一时刻只一个，起新的前先等上一个。
archive_pid=""
wait_archive() {
    [ -n "$archive_pid" ] || return 0
    wait "$archive_pid" || die "上一轮归档失败，本地数据还在 $REC_LOCAL"
    archive_pid=""
}

count_done() { list_done | wc -l; }

free_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }

# num_of_episode = 本轮尝试上限，num_of_success = 够了就停
set_round_budget() {
    $PY - "$MY_JSON" "$1" "$2" <<'EOF'
import json, sys
p, attempts, wanted = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = json.load(open(p))
rs = d.setdefault("recording_setting", {})
rs["num_of_episode"] = attempts
rs["num_of_success"] = wanted
json.dump(d, open(p, "w"), ensure_ascii=False, indent=4)
EOF
}

# ---------------------------------------------------------------- 采集循环
done_n=$(count_done)
log "已有可用 episode: $done_n / $TARGET"

for round in $(seq 1 "$MAX_ROUNDS"); do
    [ "$done_n" -ge "$TARGET" ] && break
    [ -e "$REC_LOCAL/STOP" ] && { rm -f "$REC_LOCAL/STOP"; log "检测到 STOP，收尾退出"; break; }
    free=$(free_gb "$REC_LOCAL")
    [ "$free" -lt "$MIN_FREE_GB" ] && die "本地盘只剩 ${free}G，中止"

    need=$((TARGET - done_n))
    set_round_budget "$BATCH" "$need"
    log "第 $round 轮：还差 $need 条，本轮最多尝试 $BATCH 次（本地剩 ${free}G）"

    # 不要 Ctrl+C：后处理是异步子进程，中途杀掉整轮白做
    t0=$SECONDS
    "$GENIESIM" autocollect run "$TASK" --headless --standalone || log "⚠️  autocollect 退出码 $?"
    elapsed=$((SECONDS - t0))

    wait_archive
    archive_done & archive_pid=$!
    new_done=$(count_done); gained=$((new_done - done_n)); done_n=$new_done
    log "第 $round 轮结束：本轮 $gained/$BATCH，累计 $done_n / $TARGET"
    # 光起容器就要 ~100s：不到 60s 就零产出退出 = 配置故障（任务名歧义、镜像缺失、GPU 被占）
    [ "$gained" -eq 0 ] && [ "$elapsed" -lt 60 ] && die "本轮 ${elapsed}s 就退出且无产出，采集没起来，看上面 autocollect 的报错"
done

wait_archive
[ "$done_n" -ge "$TARGET" ] || log "⚠️  达到轮次上限，只采到 $done_n / $TARGET 条"

# 本地只是中转，清掉（下次运行会重建）；还剩 episode 目录时保留给人看（归档失败/诊断 mcap）
if ls -d "$REC_LOCAL"/\[${TASK}_* >/dev/null 2>&1; then
    log "⚠️  本地还有未清理的 episode，保留 $REC_LOCAL"
else
    rm -rf "$REC_LOCAL" "$SAVED_LOCAL"
    rmdir "$DC/recording_data" "$DC/saved_task" "$DC/recording_archive" 2>/dev/null || true
fi

log "完成：$(count_done) 条 → $REC（布局 $SAVED_NAS）"
log "转换：source /home/tianran/Repos/ERSI-Bench/scripts/ersibench_env.sh && geniesim dataset convert agibot-to-lerobot --agibot-dir $REC --output-dir \$HF_HOME/lerobot/ERSI/$TASK"
