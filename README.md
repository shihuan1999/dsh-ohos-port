# DeepSeek Harness (dsh) — OpenHarmony riscv64 移植与部署

把 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh` v0.1.0-rc.7，Node.js/Cordis 插件化 Agent）移植到 Spacemit K3 的 OpenHarmony 6.1 riscv64 设备，以 root agent 身份运行。

**2026-08-18 已完整验证**：

- ✅ Web UI 在设备上运行，PC 浏览器经 `hdc fport` 访问（HTTP 200）
- ✅ headless 模式闭环：LLM 请求 → bash 工具调用（经沙箱）→ 文件落盘 → 最终回复
- ✅ Landlock 沙箱（koffi + landlock-run）在 riscv64 上真实生效：workspace-write 模式下写工作区外被拒
- ✅ 会话持久化（JSONL + zstd）正常，证据见 `evidence/session-*.jsonl.zstd`

## 仓库结构

```
dsh-port/
├── README.md                  本文档
├── SHA256SUMS.artifacts       全部产物（含未入库大文件）的 SHA256 校验和
├── scripts/                   设备端脚本（部署到 /data/dsh/bin/）
│   ├── dsh-wrapper.sh         → /data/dsh/bin/dsh        dsh 启动 wrapper
│   ├── dsh-start.sh           → /data/dsh/bin/dsh-start.sh  一键启动（mock LLM + web）
│   └── mock-llm.mjs           → /data/dsh/bin/mock-llm.mjs  设备端 mock LLM 服务
├── patches/
│   └── dsh-attachment-local.index.js   sharp→Proxy 桩（覆盖 dsh-attachment-local/lib/index.js）
├── evidence/                  设备端拉回的闭环测试会话记录（zstd 压缩 JSONL）
└── （未入库大产物，见下方产物清单）
```

## 产物清单（不入 git，校验和见 SHA256SUMS.artifacts）

| 文件 | 大小 | 内容 |
|---|---|---|
| `dsh-riscv64.tar.gz` | 74.6 MB | `node_modules/`（532 包裁剪后）+ `bin/node`（静态版，仅占位，部署时被替换）+ `package.json` |
| `node-intl` | 96.9 MB | **最终使用的 Node** v22.16.0：动态 PIE + 带 intl，interpreter `/lib/ld-musl-riscv64.so.1`，已 strip |
| `node-dynamic-riscv64` | 59.8 MB | 动态 PIE 但**不带** intl 的中间产物（留档，勿用——见坑 #7） |
| `libs-landlock.tar.gz` | 7.9 MB | `libstdc++.so.6 / libgcc_s.so.1 / libatomic.so.1`（→ `/data/dsh/lib`）+ `node-addon-landlock-run-linux-riscv64` 平台包 |
| `native-extra.tar.gz` | 366 KB | `pty.node`、`koffi.node`、sharp 桩版 `dsh-attachment-local/lib/index.js`、`dsh-llm-mock-server` |

---

## 一、设备端快速使用

以下命令在 **PC（Git Bash）** 执行，`$HDC -t $DEV shell` 之后的部分在设备上执行。

### 1.1 前置条件

- OpenHarmony 6.1 riscv64 设备（Spacemit K3 pico），root 可用
- 内核开启 `CONFIG_SECURITY_LANDLOCK=y`（K3 pico 默认满足）
- 设备可写 `/data`；`hdc` 可连接（hdc.exe 在 `C:\Users\heshihuan\Desktop\hdc.exe`）
- 若设备 hdc TCP 模式未开（tconn 失败），SSH 上设备执行（详见坑 #2）：
  ```sh
  /system/bin/hdcd -l 5 -t        # 读 persist.hdc.port=55555，重启后需重做
  ```

### 1.2 传输产物到设备

```bash
HDC=/c/Users/heshihuan/Desktop/hdc.exe
DEV=10.0.91.108:55555        # 当前设备；本次原始验证设备为 10.0.91.186:55555

"$HDC" tconn $DEV
"$HDC" -t $DEV shell "mkdir -p /data/dsh/bin /data/dsh/lib /data/dsh/home /data/dsh/tmp /data/dsh/pkg"

# hdc file send 不吃绝对路径（会拼出坏路径）：必须 cd 到源目录 + 相对文件名 + MSYS_NO_PATHCONV=1
cd /c/Users/heshihuan/Desktop/workspace/dsh-port
for f in dsh-riscv64.tar.gz libs-landlock.tar.gz native-extra.tar.gz node-intl; do
  MSYS_NO_PATHCONV=1 "$HDC" -t $DEV file send "$f" "/data/dsh/pkg/$f"
done
for f in scripts/dsh-wrapper.sh scripts/dsh-start.sh scripts/mock-llm.mjs; do
  base=$(basename "$f")
  MSYS_NO_PATHCONV=1 "$HDC" -t $DEV file send "$f" "/data/dsh/pkg/$base"
done
```

> hdc 输出里的 `[1][..] Not support std mode` 是噪音，可忽略。

### 1.3 设备端解压部署（一次性）

```sh
"$HDC" -t $DEV shell '
set -e
cd /data/dsh/pkg

# 1) 主包：node_modules + bin/node(静态占位) + package.json
tar -xzf dsh-riscv64.tar.gz -C /data/dsh

# 2) 换成带 intl 的动态 node（唯一可用变体）
mv /data/dsh/bin/node /data/dsh/bin/node-static
cp node-intl /data/dsh/bin/node && chmod +x /data/dsh/bin/node

# 3) C++ 运行库 → /data/dsh/lib（wrapper 里 LD_LIBRARY_PATH 引用）
tar -xzf libs-landlock.tar.gz
mv -f lib*.so* /data/dsh/lib/

# 4) landlock-run 平台包（npm 树无 riscv64 平台包，手工放置）
cp -r node_modules/@deepseek-ai/node-addon-landlock-run-linux-riscv64 \
      /data/dsh/node_modules/@deepseek-ai/

# 5) 原生模块 + sharp 桩 + mock server
tar -xzf native-extra.tar.gz -C /data/dsh
# koffi 坑：加载器按 double-float ABI 找 linux_riscv64d（带 d 后缀）目录
mkdir -p /data/dsh/node_modules/koffi/build/koffi/linux_riscv64d
cp /data/dsh/node_modules/koffi/build/koffi/linux_riscv64/koffi.node \
   /data/dsh/node_modules/koffi/build/koffi/linux_riscv64d/

# 6) 启动脚本就位
cp dsh-wrapper.sh /data/dsh/bin/dsh
cp dsh-start.sh mock-llm.mjs /data/dsh/bin/
chmod +x /data/dsh/bin/dsh /data/dsh/bin/dsh-start.sh
echo DEPLOY_OK
'
```

### 1.4 启动

```bash
"$HDC" -t $DEV shell "sh /data/dsh/bin/dsh-start.sh"
```

`dsh-start.sh` 做的事：导出 `HOME/DSH_HOME=/data/dsh/home`、`TMPDIR=/data/dsh/tmp`、`LD_LIBRARY_PATH=/data/dsh/lib` → 杀掉旧 node → 起 mock LLM（127.0.0.1:8000）→ 起 dsh web（127.0.0.1:3180）。

**成功判据**：输出里 `netstat -tln` 显示 8000 和 3180 均为 LISTEN。

### 1.5 PC 浏览器访问 Web UI

```bash
MSYS_NO_PATHCONV=1 "$HDC" -t $DEV fport tcp:3180 tcp:3180
# 浏览器打开 http://127.0.0.1:3180
```

⚠️ dsh 出于防 RCE 设计**拒绝绑定 0.0.0.0**，只能 127.0.0.1，所以 PC 必须走 `fport` 转发；**不要用 `rport`**——rport 是在设备端绑端口，会和 dsh 抢 3180。

### 1.6 headless 闭环自测（mock LLM，无需外网）

```bash
"$HDC" -t $DEV shell 'MOCK_SEQ=tool_call_success,success \
  MOCK_TOOL_NAME=bash \
  MOCK_TOOL_ARGUMENTS='"'"'{"command":"echo dsh-riscv64-toolcall-ok > /data/dsh/home/toolcall-proof.txt","description":"riscv64 closed-loop test"}'"'"' \
  START_WEB=0 sh /data/dsh/bin/dsh-start.sh && \
  cd /data/dsh/home && timeout 100 /data/dsh/bin/dsh --profile headless \
  "Use the bash tool to run the prepared command." 2>&1 | tail -4; \
  echo ===PROOF===; cat /data/dsh/home/toolcall-proof.txt'
```

预期输出包含 `dsh-riscv64-toolcall-ok`，即完成「LLM 请求 → 工具调用（经沙箱）→ 落盘 → 最终回复」全链路。

两个要点：
- 落盘路径**必须在 `/data/dsh/home`（工作区）内**——workspace-write 沙箱会拒绝工作区外的写入（这本身就是沙箱生效的证明）。
- `MOCK_SEQ` 可用行为：`success`、`reasoning_success`、`tool_call_success`、`max_tokens`、`slow…`，逗号分隔成序列。

### 1.7 接入真实 LLM

dsh 默认经 wrapper 里的环境变量取端点（`scripts/dsh-wrapper.sh`）：

```sh
export DEEPSEEK_BASE_URL=${DEEPSEEK_BASE_URL:-http://127.0.0.1:8000}
export DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY:-mock-key}
```

两种方式接真实模型：
1. **PC 中转**：PC 上跑一个 OpenAI 兼容 relay 监听 8000，先杀掉设备端 mock（`pkill -f mock-llm`），再 `hdc rport tcp:8000 tcp:8000`（设备 8000 → PC 8000）。此场景 rport 不会与 dsh 冲突（mock 已停）。
2. **直连**：设备有外网时直接改 `/data/dsh/bin/dsh` 里的 `DEEPSEEK_BASE_URL` 为真实端点并配置 key。

### 1.8 常见问题速查

| 症状 | 原因 / 解法 |
|---|---|
| `hdc file send` 报错或文件丢失 | hdc 不吃绝对路径：`cd` 到源目录用相对文件名 + `MSYS_NO_PATHCONV=1` |
| tconn 连不上 | 设备 hdcd TCP 模式不跨重启：SSH 上设备 `/system/bin/hdcd -l 5 -t`，再 PC `tconn` |
| fport 后 PC 打不开 web | web 进程掉了：hdc 通道断开（如 `hdc kill`）会杀掉 nohup 起的进程，重跑 `dsh-start.sh` 再 fport |
| koffi 加载失败 | 产物目录必须是 `build/koffi/linux_riscv64d`（带 d），见部署步骤 5 |
| 报 `Invalid property name in character class` | 用了不带 intl 的 node——必须用 `node-intl` 这个二进制 |
| 工具调用报 `file access denied under workspace-write mode` | 沙箱正常行为：写入限制在 `$DSH_HOME`（cwd）内 |
| pty.node 加载失败 | 用了静态 node——静态版 dlopen 不可用，必须动态 PIE 版 |

---

## 二、从源码完整重建（适配过程全记录）

> 历史构建在 snode5（10.0.50.15）完成。**按现行工作区规则（AGENTS.md），重建一律在 snode7（10.0.50.17，用户 heshihuan，SSH 免密）进行**，工具链路径 `~/WorkSpace/spacemit-toolchain-linux-musl-x86_64-oh-20260630`。

### 2.1 适配性结论

dsh = 纯 Node 逻辑（Cordis 框架、全部 dsh-* 插件、Web 前端、JSONL+zstd 会话持久化、MCP/Skills/Subagent）+ 4 个原生件：

| 依赖 | 用途 | 处理 |
|---|---|---|
| node-pty 1.2.0-beta.15 | 持久终端 | ✅ node-gyp 交叉编译 |
| koffi 3.1 | FFI（seccomp/沙箱） | ✅ 官方源码支持 riscv64，cmake 交叉编译 |
| landlock-run | Landlock 沙箱启动器 | ✅ 约 298 行 C，musl 静态编译 |
| sharp（libvips） | 图片附件 | ❌ 无 riscv64 libvips → Proxy 桩优雅降级（`patches/`） |

另：`node-addon-require-builtin` 无 riscv64 包，但其 loader 有降级路径——用 `node --expose-internals` 替代（wrapper 已内置，HMR 插件硬要求）。

### 2.2 Node.js v22.16.0 构建（动态 PIE + intl）

这是整个移植的基石，三条硬约束：

1. **必须动态 PIE**：官方 fully-static 构建 dlopen 不可用，`.node` 模块的 `DT_NEEDED libc.so` 解析不到。动态版 interpreter `/lib/ld-musl-riscv64.so.1` 与设备完全匹配；C++ 运行库（libstdc++/libgcc_s/libatomic）从工具链拷出随包携带，运行时 `LD_LIBRARY_PATH=/data/dsh/lib`。
2. **必须带 intl**（即**不要** `--without-intl`，默认 small-icu 即可）：无 intl 的 V8 parser 会拒绝 `\p{ID_Start}` 等正则**字面量**——dsh 有 11 个模块（agent-loop、api-gateway、connection、cordis-host-runner、llm-pi-ai、subagent、session-checkpoint-policy 等）踩雷；而 `new RegExp("...")` 构造器不受影响，导致问题极难定位。
3. **必须用 oh_nodejs 补丁过的源码树**：nodejs.org 原版 tar 交叉编译时 host 工具链链接会误用交叉 g++ 而挂掉；oh_nodejs 树含 Makefile `LINK.host` 修复。

```bash
# CC/CXX 指向 spacemit musl 工具链
python3 configure --dest-cpu=riscv64 --dest-os=linux --cross-compiling \
  --prefix=/opt/node --openssl-no-asm        # 注意：不要 --without-intl
make -j$(nproc)
# strip（用工具链里的 riscv64-unknown-linux-musl-strip），产物即 node-intl
```

engines 要求 `^22.19`，实测 22.16 可跑。构建机 host 侧跑 npm 需要 x64 Node 22.x（注意 PATH，避免掉进系统老 node）。

### 2.3 dsh 依赖安装、裁剪、打包

```bash
mkdir -p ~/WorkSpace2/dsh-port/install && cd ~/WorkSpace2/dsh-port/install
npm install @deepseek-ai/dsh@0.1.0-rc.7 --registry https://registry.npmmirror.com   # 532 包

# 裁剪（323M → 300M）
find node_modules -type d \( -name 'darwin-*' -o -name 'win32-*' -o -name 'freebsd-*' \) -exec rm -rf {} +
find node_modules -name '*.pdb' -delete
rm -f node_modules/node-pty/prebuilds/linux-x64/pty.node \
      node_modules/node-pty/prebuilds/linux-arm64/pty.node
rm -rf node_modules/.cache node_modules/.package-lock.json

# 打包（-C 必须接绝对路径）；bin/ 里放一个静态 node 占位（部署时会被 node-intl 替换）
tar -czf dsh-riscv64.tar.gz \
  -C ~/WorkSpace2/dsh-port/install node_modules \
  -C ~/WorkSpace2/dsh-port/pack bin package.json
```

### 2.4 原生模块编译

**node-pty**（node-gyp）：

```bash
cd node_modules/node-pty
npx node-gyp rebuild --arch=riscv64 --nodedir=<oh_nodejs 补丁树>
# 产物 build/Release/pty.node；Linux 分支不需要 spawn-helper（那是 macOS 专属分支）
```

**koffi**（cmake，经其自带 cnoke 驱动）：

```bash
cd node_modules/koffi
node cnoke.cjs -P . -D src/koffi --release \
  -d CMAKE_SYSTEM_PROCESSOR=riscv64 -d CMAKE_SYSTEM_NAME=Linux \
  -d CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
# 配 musl CC/CXX；koffi 读 node ELF 的 e_flags 判定浮点 ABI，
# double-float 下查找目录是 build/koffi/linux_riscv64d（带 d 后缀！）
```

**landlock-run**（静态 C 二进制）：

```bash
# 用 musl 工具链静态编译其 main.c（约 298 行），产物 bin/landlock-run
# 造平台包目录（npm 树里没有 riscv64 平台包）：
mkdir -p node_modules/@deepseek-ai/node-addon-landlock-run-linux-riscv64/bin
#   + 手写 package.json（声明 os/cpu/bin 字段），bin/ 放 landlock-run
# ⚠️ npm install 会删掉手造目录——每次装完依赖必须重建
```

**sharp 桩**：直接用本仓库 `patches/dsh-attachment-local.index.js` 覆盖
`node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js`——把顶层 `import sharp` 换成抛错的 Proxy，图片附件功能优雅降级，其余功能不受影响。

### 2.5 运行库与收尾

- 从 musl 工具链拷 `libstdc++.so.6 / libgcc_s.so.1 / libatomic.so.1` → 设备 `/data/dsh/lib`（即 `libs-landlock.tar.gz` 里的 `./lib*.so*` 部分）
- `native-extra.tar.gz` = pty.node + koffi.node + sharp 桩 + `@deepseek-ai/dsh-llm-mock-server`（dsh 源码 `packages/test-support/llm-mock-server` 的产物，设备端自测的关键件）
- 设备端最终布局：

```
/data/dsh/
├── bin/     node(=intl动态版) node-static dsh(wrapper) dsh-start.sh mock-llm.mjs
├── lib/     libstdc++.so.6 libgcc_s.so.1 libatomic.so.1
├── node_modules/   @deepseek-ai/dsh ... + node-pty(pty.node) + koffi(linux_riscv64d)
├── home/    DSH_HOME：会话(sessions/--data-dsh-home--/session-*/session.jsonl.zstd)、web.log、mock.log
└── tmp/     TMPDIR（设备 /tmp 只读）
```

---

## 三、坑速查（按踩中顺序）

| # | 坑 | 解法 |
|---|---|---|
| 1 | 官方静态 Node dlopen 不可用（.node 的 DT_NEEDED libc.so 解析不到） | 动态 PIE 构建，interpreter 与设备一致 |
| 2 | `--without-intl` 的 V8 parser 拒绝 `\p{ID_Start}` 正则**字面量**（11 个 dsh 模块），RegExp 构造器却正常 | 带 intl（small-icu）构建 |
| 3 | 原版 Node 源码树交叉编译挂（host 工具链误用交叉 g++） | 用 oh_nodejs 补丁树（含 Makefile `LINK.host` 修复） |
| 4 | koffi 产物目录名 | double-float ABI → `linux_riscv64d`（带 d），不是 `linux_riscv64` |
| 5 | `npm install` 删掉手造的 landlock-run 平台包目录 | 装完依赖重建目录 |
| 6 | node-pty 报缺 spawn-helper | 那是 macOS 分支，Linux 不需要，忽略 |
| 7 | sharp 无 riscv64 libvips | Proxy 桩降级（本仓库 `patches/`） |
| 8 | dsh 启动即挂（HMR 插件） | wrapper 必须 `node --expose-internals` |
| 9 | `hdc file send` 绝对路径拼坏 | cd + 相对文件名 + `MSYS_NO_PATHCONV=1` |
| 10 | 设备 hdc TCP 模式重启即丢 | SSH 执行 `/system/bin/hdcd -l 5 -t` 后 PC `tconn` |
| 11 | PC 访问设备 web | 用 `fport`（dsh 拒绑 0.0.0.0）；`rport` 会抢设备端 3180 端口 |
| 12 | `hdc kill` 后设备 web 掉线 | nohup 进程随 hdc 通道断开被杀，重跑 `dsh-start.sh` |
| 13 | 设备 `/tmp` 只读 | `TMPDIR=/data/dsh/tmp`；沙箱测试产物必须写 `$DSH_HOME` 内 |

## 四、坐标与版本

| 项 | 值 |
|---|---|
| 上游 | github.com/deepseek-ai/deepseek-harness（MIT） |
| dsh 版本 | `@deepseek-ai/dsh@0.1.0-rc.7`（npm，npmmirror 镜像） |
| Node | v22.16.0（动态 PIE + small-icu intl，musl riscv64，double-float ABI） |
| 工具链 | spacemit-toolchain-linux-musl-x86_64-oh-20260630 |
| 历史构建机 | snode5（10.0.50.15）——**已禁用，重建用 snode7（10.0.50.17）** |
| 原始验证设备 | K3 pico `10.0.91.186`（OH 6.1，root，hdc TCP 55555）；当前实验室设备 `10.0.91.108` |
| 验证日期 | 2026-08-18（web UI 200 + headless 工具调用落盘闭环 + 沙箱拒绝验证） |

## 五、产物校验和

见 `SHA256SUMS.artifacts`（含未入库大产物与入库脚本/桩/证据的 SHA256）。产物丢失时按第二章流程在 snode7 重建。
