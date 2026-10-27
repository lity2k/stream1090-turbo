# 构建

五条路径，按在目标板上的表现从好到差排列：

| 路径 | 运行位置 | 吞吐 | 何时使用 |
|---|---|---|---|
| `install.sh`（预编译） | 不编译，直接解包安装 | 7.28 s（最快） | 默认，板子上没有编译器 |
| 原生 `install.sh --build` | 板子上 | 7.28 s | 想用本源码树现场编译 |
| `install.sh --upstream` | 板子上 | 取决于上游版本 | 想用官方最新源码 |
| `cmake` | 板子上 | 较慢，全部 preset | 想用上游的构建系统 |
| `tools/crossbuild.sh` | x86_64 主机 | 单一 preset 7.82 s / 全 preset 8.62 s | 板子装不下编译器 |

## 安装器

`install.sh` 是统一入口。默认模式安装 `prebuilt/`：

```bash
sudo bash install.sh                     # 校验 + 安装，不调用编译器
sudo bash install.sh --prefix /opt/turbo
sudo bash install.sh --dry-run           # 只打印计划，不改动任何东西
```

写入 `$PREFIX/bin` 之前的校验：

| 校验项 | 失败行为 |
|---|---|
| 对照 `prebuilt/MANIFEST` 的 `md5sum` | 中止，exit 3 |
| ELF `e_machine` == 40（ARM） | 中止，exit 3 |
| `uname -m` 为 armv7l/armv8l | 中止（除非 `--force`），exit 3 |
| `ldd` 无 `not found` | 中止，并列出缺失的库 |
| 以空 stdin 试跑一次 | 退出码为 124/126/127 时中止 |

若已装有别的 `stream1090`，会保留为 `$PREFIX/bin/stream1090.prev`，而不是静默覆盖。

zip 包与 Windows 拷贝会丢失可执行位；安装器会检测到这一点，用一份 755 临时副本完成
试跑，最终统一以 `755` 安装。

`--build` 通过 `tools/install.sh` 编译随包 `src/`；`--upstream` 走在线路径：

```bash
sudo bash install.sh --upstream
# == fetch latest official source
# repo   : https://github.com/mgrone/stream1090.git
# commit : <sha>
# == replay this project's change set
# patching file include/ShiftRegisters.hpp
# ...
```

它把官方 `main` 以 depth 1 克隆到 `.cache/install-upstream`，记录 commit，先跑
`patch -p1 --dry-run`，通过后才应用并编译。dry-run 失败则停下，提示改用 `--build`
（随包源码树）或用 `tools/sync_upstream.sh` 重建并重新生成补丁——绝不在半应用的
源码树上编译。该产物**不是**基准数据所用的那个二进制，装完需重新核对 AVR md5
（见 `docs/validation.zh-CN.md`）。

环境变量：`UPSTREAM_URL` 覆盖仓库地址，`PRESETS` 等价于 `--presets`。

### 版本标识与发布顺序

`tools/version.sh` 是决定二进制内嵌什么标识的唯一位置：

```text
stream1090-turbo <语义版本>.<构建号>+<提交>[.dirty].<源码指纹>
stream1090-turbo 1.0.1.7+5a2b1c9.9f3a1c02be74
```

| 字段 | 来源 | 说明 |
|---|---|---|
| `1.0.1` | `VERSION` | 契约变化时人工 bump |
| `7` | `git rev-list --count --first-parent HEAD` | 单调递增，无需维护计数器文件 |
| `5a2b1c9` | `git rev-parse --short HEAD` | `src/ VERSION patches/` 有改动时带 `.dirty` |
| `9f3a1c02be74` | 参与编译源码的 sha256 | 同一棵树必然同一串 |

全程没有状态文件：构建号来自 git，指纹来自源码，所以同一棵树永远得到同一个串，
因而也得到同一个 md5。`install.sh --reproducible` 改为只嵌语义版本，供必须在另一台
机器上逐字节重建的场合使用。

顺序很重要。发布固定按这四步走：

1. 先提交源码改动，让 `构建号` 与 `提交` 定版；
2. 用 `STREAM1090_VERSION="$(tools/version.sh)"` 编译预编译版——交叉编译也能用，
   因为串是在主机侧算好再传进去的；
3. 把同一个串写进 `prebuilt/MANIFEST` 的 `built_version`，再跑
   `tools/version.sh --write` 刷新 `BUILDINFO`；
4. `git tag v<语义版本>` 并推送。

`install.sh` 会把清单里的 `built_version` 与二进制里实际存在的串做比对，不一致即
exit 3 中止，因此清单不会与它所描述的产物脱节。

## 原生构建

需要 g++（11 或更高）与 `librtlsdr-dev`。

```bash
PRESETS=BenchPresets.hpp tools/install.sh            # -> /usr/local/bin/stream1090
tools/install.sh . /opt/turbo                        # 自定义安装前缀
```

只编一组 preset 是刻意的默认：装满上游 27 份实例化的编译单元在 512 MB 板子上会被
OOM kill。`install.sh` 使用取基准数据时的完全相同的选项集合；在 `prebuilt/MANIFEST`
记录的 commit 上构建，结果与随包预编译版逐位相同
（md5 `4a21451369e321f84f0d17a945f8496c`）。

与发布数字对比时，不要增删 `-DSTREAM1090_*` 选项；其中一些即使在受保护代码不执行时
也会改变代码生成。

## CMake

```bash
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j2
```

注意 `src/CMakeLists.txt` 写死了 `DefaultPresets.hpp`，因此这会构建**全部**上游组合。
在 512 MB 板子上很可能被 OOM kill；即使编成，也比单 preset 二进制慢约 19%。
想要上游的构建布局就用 CMake，想要快二进制就用 `install.sh`。

## 交叉构建

除交叉编译器自带 sysroot 之外，所需的全部内容是板子上的 `librtlsdr`、
`libusb-1.0`、`libudev` 及其头文件。把它们放进一个目录，用 `SYSARM` 指过去：

```bash
mkdir -p /tmp/sysarm/usr/{include,lib/arm-linux-gnueabihf}
# 从板子上拷：
#   /usr/include/rtl-sdr.h /usr/include/rtl-sdr_export.h /usr/include/libusb-1.0/
#   /usr/lib/arm-linux-gnueabihf/librtlsdr.so* libusb-1.0.so* libudev.so*
ln -sf librtlsdr.so.2.0.1   /tmp/sysarm/usr/lib/arm-linux-gnueabihf/librtlsdr.so
ln -sf libusb-1.0.so.0.5.0  /tmp/sysarm/usr/lib/arm-linux-gnueabihf/libusb-1.0.so
ln -sf libudev.so.1.7.10    /tmp/sysarm/usr/lib/arm-linux-gnueabihf/libudev.so

SYSROOT=$HOME/xarm SYSARM=/tmp/sysarm \
  tools/crossbuild.sh src BenchPresets.hpp ./stream1090-armv7
```

工具链目录（`SYSROOT`）的要求：

- 交叉版 `g++-14`（不是 `g++`，也不是 gcc-13——见 `docs/benchmarks.zh-CN.md` §6）；
- `--sysroot` 必须指向**包含** `usr/` 的那个目录，否则链接器找不到 libc；
- `LD_LIBRARY_PATH` 必须包含宿主侧的 `libbfd`，否则 `as` 启动即失败。

`crossbuild.sh` 已设置这三项，并对结果做 strip 后打印其 md5。

## Preset 与内存

`-s` 与 `-u` 是模板参数。每个受支持组合在编译期实例化，二进制只能接受编进去的组合。

| preset 文件 | 实例数 | 所需内存 | 结果 |
|---|---|---|---|
| `BenchPresets.hpp` | 1（2.56 → 12） | 约 350 MB | 可在 512 MB 板子上编成 |
| `DefaultPresets.hpp` | 27 | > 1 GB | 512 MB 板子上被 OOM kill |

增加一组就是在 preset 头文件里加一行：

```cpp
ADD_PRESET(RtlSdr, 2.4, 8)
```

`static_assert` 强制的约束：`-u` 必须是 2 MHz 的整数倍，且不小于 `-s`。注意
`LowPassTaps` 只带 2.4 与 2.56 Msps 的系数——在 3.2 Msps 上 `-q` 退化为直通，
需要改用 `-f <taps>`。

## 运行

```bash
rtl_sdr -f 1090000000 -s 2560000 -g 19.7 - | stream1090 -s 2.56 -u 12 -q > messages.avr
```

先停掉任何占用接收设备的服务（`readsb`、`dump1090` 等）。

## 与上游保持同步

本仓库不是 git fork：完整源码树放在 `src/` 下，上游历史不是祖先，合并会在每个文件上
冲突。`tools/sync_upstream.sh` 实现了替代方案——快照上游，再把改动的 8 个文件重放上去。

```bash
bash tools/sync_upstream.sh fetch    # 克隆上游 main 到 .cache/
bash tools/sync_upstream.sh check    # 上游改了什么、与我们哪里碰撞
bash tools/sync_upstream.sh rebase   # 重建 src/ 并重放我们的文件
```

当上游改动了本项目也重写过的文件时，`check` 会打印 `CONFLICT`。此时 `rebase` 保留
上游版本，把我们的版本留在 `.cache/src-backup` 供手工合并。同步后务必重新构建并
核对 AVR md5——上游如果改了解码行为，这里会最先暴露。
