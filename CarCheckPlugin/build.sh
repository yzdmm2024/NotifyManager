#!/bin/bash
# 本地 Mac 构建脚本
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
THEOS="$HOME/theos"

if [ ! -d "$THEOS" ]; then
    echo "请先安装 Theos: bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/nicedayzhu/iosjailbreak_dev/main/install_theos.sh)\""
    exit 1
fi

export THEOS
cd "$PROJECT_DIR"
make clean
make package

echo ""
echo "构建完成！"
echo "DEB 包位置: $(find packages -name '*.deb' 2>/dev/null | head -1)"
echo "DYLIB 位置: $(find .theos/obj/debug -name '*.dylib' 2>/dev/null | head -1)"