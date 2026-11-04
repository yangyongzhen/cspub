#!/usr/bin/env bash
# Windows 交叉构建（自动临时改 link-option + windows stdx path-option）
#
# cjpm.toml 根 link-option 为空（Linux 侧不填）；Windows 构建需临时填
# 系统库（crypt32: x509 证书；ws2_32: 网络），并补 windows target 的
# stdx 路径，结束自动恢复。
#
# 用法：./scripts/winbuild.sh
# 参考 cjh/scripts/winbuild.sh（同一套方案）；产物依赖：
#   libboundscheck.dll / libcangjie-runtime.dll / libcrypto-3-x64.dll /
#   libssl-3-x64.dll（openssl 由运行时 dlopen，须同目录）
set -e
cd "$(dirname "$0")/.."

# stdx 静态库路径（.a）：stdx 静态链接进 exe；勿用 dynamic/stdx——那会让
# exe 动态依赖 12 个 libstdx.*.dll（cjh v1.3.5 实测回归）。
WINDOWS_STDX="${CSPUB_WINDOWS_STDX:-/root/.cangjie/stdx/cangjie-stdx-windows-x64-1.2.0.1/windows_x86_64_cjnative/static/stdx}"
if [ ! -d "$WINDOWS_STDX" ]; then
    echo "[winbuild.sh] 缺少 windows stdx: $WINDOWS_STDX"
    echo "  解压 cangjie-stdx-windows-x64-1.2.0.1.zip 到 ~/.cangjie/stdx/cangjie-stdx-windows-x64-1.2.0.1/"
    exit 1
fi

cp cjpm.toml /tmp/cjpm.winbuild.toml
# link-option 填 Windows 系统库（cjh 同款：crypt32: x509 证书；ws2_32: 网络）
sed -i 's|^  link-option = ""|  link-option = "-lcrypt32 -lws2_32"|' cjpm.toml
grep -q '\-lcrypt32' cjpm.toml || { echo "[winbuild.sh] link-option 替换失败"; cp /tmp/cjpm.winbuild.toml cjpm.toml; exit 1; }
# 追加 windows target 的 stdx 路径（ld.lld 链接 stdx import 库需要）
if ! grep -q "x86_64-pc-windows-gnu.bin-dependencies" cjpm.toml; then
    cat >> cjpm.toml <<EOF

[target.x86_64-pc-windows-gnu.bin-dependencies]
    path-option = ["$WINDOWS_STDX"]
EOF
fi
restore() { cp /tmp/cjpm.winbuild.toml cjpm.toml; }
trap restore EXIT

export PATH=/opt/cangjie/cangjie/bin:/opt/cangjie/cangjie/tools/bin:$PATH
# cjpm/cjc 本体也动态链接仓颉运行时，工具链自身就须 LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/opt/cangjie/cangjie/runtime/lib/linux_x86_64_cjnative:/opt/cangjie/cangjie/third_party/llvm/lib:${LD_LIBRARY_PATH:-}
echo "[winbuild.sh] 交叉构建 Windows（stdx: $WINDOWS_STDX）..."
cjpm build --target x86_64-pc-windows-gnu "$@" 2>&1 | grep -v WARN | tail -3
# strip PE：cjpm 产物带调试 section；PE 用 mingw strip 裁剪（cjh 实测 38MB→13MB）
EXE=target/x86_64-pc-windows-gnu/release/bin/main.exe
if [ ! -f "$EXE" ]; then echo "[winbuild.sh] 构建产物缺失: $EXE"; exit 1; fi
if command -v x86_64-w64-mingw32-strip > /dev/null; then
    x86_64-w64-mingw32-strip "$EXE"
    echo "[winbuild.sh] 已 strip: $(stat -c%s "$EXE") bytes"
else
    echo "[winbuild.sh] 警告: 未找到 x86_64-w64-mingw32-strip，产物未裁剪"
fi
echo "[winbuild.sh] 产物: $EXE"
