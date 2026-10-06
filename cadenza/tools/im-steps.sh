#!/bin/bash
# 输入源分步探测：查询 → 保存原源 → 切换 → 校验 → 无条件恢复 → 复核。
# 用法: ./im-steps.sh <目标输入源ID>
# 约束：恢复动作不依赖 && 串联，任何一步失败都会继续执行恢复；每步独立输出便于定位。
set -u
cd "$(dirname "$0")"

TARGET="${1:?usage: im-steps.sh <target-source-id>}"

echo "[step1] 查询当前输入源"
ORIG=$(./isw current 2>&1 | head -1 | sed 's/^id=//')
echo "ORIG=${ORIG:-<empty>}"

echo "[step2] 切换到 ${TARGET}"
./isw select "$TARGET" || echo "STEP2-FAILED"

echo "[step3] 校验切换结果"
CUR=$(./isw current 2>&1 | head -1 | sed 's/^id=//')
echo "NOW=${CUR:-<empty>}"

echo "[step4] 恢复原输入源（无条件执行）"
if [ -n "$ORIG" ]; then
    ./isw select "$ORIG" || echo "STEP4-RESTORE-FAILED"
else
    echo "restore-skip: ORIG 为空，无法自动恢复，请手动检查"
fi

echo "[step5] 复核恢复结果"
./isw current || echo "STEP5-FAILED"
echo "[done]"
