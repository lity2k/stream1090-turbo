# stream1090-turbo

[English](README.md) | 简体中文

针对 **4× Cortex-A7**（Allwinner sun8i 一类，1.296 GHz，NEON + VFPv4，**无** ARMv8
crypto/CRC 指令）的 [stream1090](https://github.com/mgrone/stream1090) 硬件特化优化。

目标负载：`stream1090 -s 2.56 -u 12 -q`（2.56 Msps RTL-SDR 输入，上采样到 12 MHz
多流，启用内置 IQ 低通）。

**结果：吞吐 2.20×，解码输出与上游逐字节相同。**

| | 上游等价构建 | 本仓库 | 加速比 |
|---|---|---|---|
| A 板 | 15.95 s | 7.24 s | 2.204× |
| B 板 | 15.96 s | 7.25 s | 2.201× |

测量条件：10 秒、51.2 MB 的 RTL-SDR 实录经 stdin 回放，CPU governor 固定
performance，每块板各跑 3 次。报文数（256）与 AVR 负载（9154 字节，md5
`e7bc7960e32d93d094c413300cd1227e`）与上游完全一致 —— 这是纯速度改动，不改变行为。

原本处理 10 秒实时 IQ 需要 15.9 秒（持续积压），现在 7.25 秒完成，能稳定跟上采集。

## 改了什么

共 8 个文件，都在解调热路径上；`main.cpp` 与 `src/` 一行未动。

1. **NEON 化移位寄存器**（`include/ShiftRegisters.hpp`）
   12 条 bit 流分为 3 组 × 4 lane。128 bit 报文窗口放在四个 `uint32_t` 向量里
   （`w0` = bit 31..0 … `w3` = 127..96），一条 lane 承载一条流，整组并行完成移位、
   双 CRC 折叠与下行格式判定。

2. **双线程流水线**（`include/SampleStream.hpp`、`include/BlockRing.hpp`）
   生产者（读取 → FIR → 幅度 → 上采样）与消费者（Manchester → 移位更新）并发。
   `BlockRing::m_fullBlocks` 改为 `std::atomic` 以支持跨线程共享。

3. **Manchester 比较融进移位更新**
   GCC 不会向量化原来的 `m_demodPos[j] > m_demodPos[j + NumStreams/2]` 循环，
   而是生成 12 组标量 `ldr/cmp/ite/str`。现在比较在向量寄存器内完成，`m_newBits`
   临时数组被彻底删除。

4. **用 `vsli` 取代 `shl` + `orr`**
   `vsliq_n_u32(carry, w, 1)` 一条指令完成 `(w << 1) | carry`，窗口移位与 CRC
   折叠都改用它。

5. **缩小输入块**（`include/Sampler.hpp`）
   `DesiredInputBufferSize` 8192 → 1024（每块 154 KB → 21 KB）。可用
   `-DSTREAM1090_INPUT_BUFFER_TARGET=` 覆盖；低于 1024 无进一步收益。

6. **修正环形缓冲余量**
   `NumFreeSampleBuffers` 为 `NumSampleBuffers - 2` 而非 `- 1`：解调器会回看上一块
   （`lookBack` 最大 1524 样本），只留一块余量会被写者覆盖。

与上游的完整 diff：`patches/0001-cortex-a7-neon-pipeline.patch`。

## 优化后的热点分布

A 板上 `perf record -F 2000`，占 15.26 G 周期的比例：

| 符号 | 占比 | 侧 |
|---|---|---|
| 解调线程 lambda（移位 + Manchester，已内联） | 26.3 % | 消费者 |
| `DemodCore::dispatchHandled` | 21.7 % | 消费者 |
| `SampleStream::read`（读取 + FIR + 幅度） | 19.4 % | 生产者 |
| `SamplerFunc<16,75,72>::sample` | 14.4 % | 生产者 |
| `handleExtSquitterLongMessage` | 9.6 % | 消费者 |
| `handleDF11ShortMessage` | 2.6 % | 消费者 |

消费者侧约 7.1 s 工作量，生产者侧约 4.0 s，两者并发，墙钟由消费者决定 —— 所以继续优化
生产者不再降低总时间。

已实测并否决的方向见 `docs/benchmarks.zh-CN.md` 第 5 节（派发拆线程、按流并行移位、
64 位 CRC 折叠、NEON 上采样器）。各改动的原理见 `docs/optimization.zh-CN.md`。

## 安装

默认路径直接装包内预编译版本，完全不调用编译器：

```bash
sudo bash install.sh                    # 安装到 /usr/local/bin/stream1090
sudo bash install.sh --prefix /opt/turbo
```

安装前会校验预编译版本：对照 `prebuilt/MANIFEST` 核对 md5、读取 ELF 头（必须为
ARM）、用 `ldd` 检查动态库依赖、并以空 stdin 试跑一次。任一项失败即中止并给出提示，
不会留下半装状态的 `stream1090`。`--dry-run` 只打印计划，不做任何改动。

| 命令 | 二进制来源 | 依赖 |
|---|---|---|
| `install.sh` | 包内 `prebuilt/stream1090-armv7l-cortexa7` | 无（只需本包） |
| `install.sh --build` | 编译随包 `src/` | g++、`librtlsdr-dev` |
| `install.sh --upstream` | 在线拉取官方最新源码 → 重放 `patches/` → 编译 → 安装 | git、g++、`librtlsdr-dev` |

`--upstream` 取的是 `mgrone/stream1090` 当前的 `main`，会记录所用 commit；若补丁已
无法应用（说明上游改动了本项目重写的 8 个文件之一）则直接中止，提示先跑
`tools/sync_upstream.sh check` 并重新生成补丁，而不是带着冲突编译。

### 版本标识

凡是本树编译出的二进制，都带一串能定位到源码状态的版本标识：

```text
stream1090-turbo 1.0.1.7+5a2b1c9.9f3a1c02be74
                 ^语义版本 ^构建号 ^提交 ^源码指纹
```

`stream1090 -h | head -1` 会打印它，stderr 的启动横幅也会。官方原版在这里显示的是
上游的日期码，因此两者不会混淆；两个 turbo 构建之间也永远可区分。

| 字段 | 来源 | 何时变化 |
|---|---|---|
| `1.0.1` | `VERSION` | 由人判断契约变化时手动改 |
| `7` | `git rev-list --count --first-parent HEAD` | 每次提交自动递增 |
| `5a2b1c9` | `git rev-parse --short HEAD` | 每次提交 |
| `9f3a1c02be74` | 参与编译文件的 sha256 | 任一源文件改动 |

当 `src/`、`VERSION` 或 `patches/` 有未提交改动时，串尾会多出 `.dirty`。同一源码状态
永远生成同一个串，验收用的 md5 对账才有意义。`install.sh --reproducible` 会去掉 git
部分，只嵌入语义版本。

`tools/version.sh` 是唯一生成器，它同时写出 `BUILDINFO` 随包分发：zip 下载与浅克隆
没有 `.git`，靠这个文件仍能报出可用标识，而不是空白。

## 源码构建

需要 C++20 编译器。无外部依赖，`src/thirdparty` 内含 RTL-SDR 源码。

在目标板上原生构建（基准数据即来自这条路径，`install.sh --build` 调用的也是它）：

```bash
tools/install.sh                  # 安装到 /usr/local/bin/stream1090
```

或使用 CMake（注意它固定用上游 `DefaultPresets.hpp`，512 MB 板内存不足，
详见 `docs/build.zh-CN.md`）：

```bash
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j2
```

x86_64 主机交叉编译：`tools/crossbuild.sh`。

### 预设与内存

`-s` / `-u` 是编译期模板参数。`BenchPresets.hpp` 只实例化一组（2.56 → 12），因为把
上游 27 个实例放进一个 TU 需要的内存超过 512 MB 板。换到内存充足的主机可改用
`DefaultPresets.hpp`，一次拿到所有组合 —— 代价是实测 8–19% 的吞吐下降
（代码体积 190 KB → 722 KB，I-cache 压力）。

## 运行

```bash
rtl_sdr -f 1090000000 -s 2560000 -g 19.7 - \
  | ./stream1090 -s 2.56 -u 12 -q > messages.avr
```

先停掉占用 dongle 的服务（`readsb`、`dump1090` 等）。

`-q` 启用内置 IQ 低通。注意 `LowPassTaps` 只有 2.4 与 2.56 Msps 的系数，3.2 Msps
下会退化为直通。

## 验证

```bash
tools/bench.sh <binary> <capture.bin> 3 /tmp/bench
```

输出墙钟/用户/系统时间、报文数与 AVR 字节数。正确性判据：同一份采集分别喂给上游
与本版，`cmp` 比对 AVR 输出必须逐字节相同。`docs/validation.zh-CN.md` 记录了验收数据
（两块板 × 各 3 次）与预期 md5。

## 目录

```
src/              完整源码树（上游 + 本项目改动）
prebuilt/         可直接运行的二进制 + MANIFEST（md5、架构、上游 commit）
install.sh        安装器：默认预编译，--build 本地编译，--upstream 在线拉取后编译
patches/          相对上游的 8 文件 diff，供审阅或向上游提交
tools/            bench.sh、install.sh、crossbuild.sh、sync_upstream.sh
docs/             优化原理、基准数据、构建与验证（英文 + .zh-CN 中文）
VERSION           本发布包版本号
UPSTREAM_COMMIT   本源码树基于的上游 commit
```

## 跟进上游

本仓库不是 git fork，上游历史不是祖先，直接 merge 会让每个文件都冲突。
`tools/sync_upstream.sh` 提供替代方案：快照上游，然后重放我们的 8 个文件。

```bash
bash tools/sync_upstream.sh fetch    # 克隆上游 main 到 .cache/
bash tools/sync_upstream.sh check    # 列出上游变更与冲突面
bash tools/sync_upstream.sh rebase   # 重建 src/ 并重放本地改动
```

若 `check` 报 `CONFLICT`，说明上游动过我们同样改写的文件；脚本保留上游版本，把我的
版本留在 `.cache/src-backup` 供人工合并。同步后必须重新编译并重跑输出比对。

## 适用范围与已知限制

- 专门针对 Cortex-A7 调优（`-mcpu=cortex-a7`）。NEON 路径需要 128 位 SIMD，
  这不是通用 ARM 加速方案。
- 发布用的 preset 只实例化 2.56 → 12。
- 吞吐受消费者线程限制，加核无效。
- 8 流配置（`-u 8`）走同一套代码，端到端与上游输出一致，但**未**做逐位等价测试；
  逐位测试只覆盖 `ShiftRegisters<12>`（见 `docs/validation.zh-CN.md`）。

## 许可

GPL-3.0，继承自上游 stream1090，见 `LICENSE`。
上游版权归其作者所有；本树仅追加上述优化。
