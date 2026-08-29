#!/system/bin/sh
# Install dsh on the device straight from the GitHub release.
# Run ON DEVICE (hdc/ssh shell as root). Requires internet (uses /bin/curl).
#
#   sh /path/to/install-on-device.sh [tag]     # default tag: v1.0.0
#
# After install, verify with:
#   sh /data/dsh/bin/dsh-start.sh              # mock LLM :8000 + web :3180
set -e
TAG="${1:-v1.0.0}"
BASE="https://github.com/shihuan1999/dsh-ohos-port/releases/download/$TAG"
PKG=/data/dsh/pkg

mkdir -p /data/dsh/bin /data/dsh/lib /data/dsh/home /data/dsh/tmp "$PKG"
cd "$PKG"

echo "[install] downloading assets ($TAG)"
for f in dsh-riscv64.tar.gz libs-landlock.tar.gz native-extra.tar.gz node-intl \
         dsh-wrapper.sh dsh-start.sh mock-llm.mjs; do
  if [ ! -f "$f" ]; then
    /bin/curl -fLO "$BASE/$f"
  fi
done

echo "[install] 1/6 main package (node_modules + bin + package.json)"
tar -xzf dsh-riscv64.tar.gz -C /data/dsh

echo "[install] 2/6 dynamic node with intl (only working variant)"
cp node-intl /data/dsh/bin/node
chmod +x /data/dsh/bin/node

echo "[install] 3/6 C++ runtime libs -> /data/dsh/lib"
tar -xzf libs-landlock.tar.gz
mv -f lib*.so* /data/dsh/lib/

echo "[install] 4/6 landlock-run platform package (no riscv64 npm pkg; manual)"
cp -r node_modules/@deepseek-ai/node-addon-landlock-run-linux-riscv64 \
      /data/dsh/node_modules/@deepseek-ai/

echo "[install] 5/6 native modules + sharp stub + mock server"
tar -xzf native-extra.tar.gz -C /data/dsh
# koffi: loader resolves the double-float ABI dir linux_riscv64d (trailing d)
mkdir -p /data/dsh/node_modules/koffi/build/koffi/linux_riscv64d
cp /data/dsh/node_modules/koffi/build/koffi/linux_riscv64/koffi.node \
   /data/dsh/node_modules/koffi/build/koffi/linux_riscv64d/

echo "[install] 6/6 launcher scripts"
cp dsh-wrapper.sh /data/dsh/bin/dsh
cp dsh-start.sh mock-llm.mjs /data/dsh/bin/
chmod +x /data/dsh/bin/dsh /data/dsh/bin/dsh-start.sh

echo "[install] done. Start with:  sh /data/dsh/bin/dsh-start.sh"
