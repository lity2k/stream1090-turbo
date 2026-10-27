/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 Martin Gronemann
 *
 * This file is part of stream1090 and is licensed under the GNU General
 * Public License v3.0. See the top-level LICENSE file for details.
 */
#pragma once

#include <atomic>
#include <csignal>

// visible to every translation unit that instantiates a sampler
#ifndef STREAM1090_VERSION
#define STREAM1090_VERSION "261013"
#endif

// 1 = 原来的单线程直通; 2 = 输入级与解调级各占一个线程
#ifndef STREAM1090_PIPELINE_THREADS
#define STREAM1090_PIPELINE_THREADS 2
#endif

// 解调线程读预取提前量（bit 周期数）。mag ring 由生产者核写入，消费者核
// 每行都是 L1 miss；提前 PLD 让 L2 延迟与移位计算重叠。0 可关。
#ifndef STREAM1090_PREFETCH_DIST
#define STREAM1090_PREFETCH_DIST 8
#endif

struct GlobalOptions {
    #ifdef STATS_ENABLED
        static constexpr bool StatsEnabled = (STATS_ENABLED != 0);
    #else
        static constexpr bool StatsEnabled = false;
    #endif

    #ifdef STATS_END_ONLY
        static constexpr bool StatsAtTheEndOnly = StatsEnabled && (STATS_END_ONLY != 0);
    #else
        static constexpr bool StatsAtTheEndOnly = false;
    #endif

    #ifdef STREAM1090_RSSI
        static constexpr bool RSSIEnabled = (STREAM1090_RSSI != 0);
    #else
        static constexpr bool RSSIEnabled = false;
    #endif

    #ifdef STREAM1090_HAS_LIB_RTLSDR
        static constexpr bool NativeRtlSdrSupport = (STREAM1090_HAS_LIB_RTLSDR != 0);
    #else
        static constexpr bool NativeRtlSdrSupport = false;
    #endif

    #ifdef STREAM1090_HAS_LIB_RTLSDR_BLOG
        static constexpr bool NativeRtlSdrBlogSupport = (STREAM1090_HAS_LIB_RTLSDR_BLOG != 0);
    #else
        static constexpr bool NativeRtlSdrBlogSupport = false;
    #endif

    #ifdef STREAM1090_HAS_LIB_AIRSPY
        static constexpr bool NativeAirspySupport = (STREAM1090_HAS_LIB_AIRSPY != 0);
    #else
        static constexpr bool NativeAirspySupport = false;
    #endif
};

namespace ProcessSignals {

    static std::atomic<bool> g_shutdownRequested{false};
    static std::atomic<bool> g_reloadRequested{false};

    inline bool shutdownRequested() {
        return g_shutdownRequested.load(std::memory_order_relaxed);
    }

    inline bool reloadRequested() {
        return g_reloadRequested.load(std::memory_order_relaxed);
    }

    inline void clearReload() {
        g_reloadRequested.store(false, std::memory_order_relaxed);
    }

    static void handle_sigint(int) {
        g_shutdownRequested.store(true, std::memory_order_relaxed);
    }

    static void handle_sighup(int) {
        g_reloadRequested.store(true, std::memory_order_relaxed);
    }

    inline void install() {
        std::signal(SIGINT,  handle_sigint);
        std::signal(SIGTERM, handle_sigint);
        std::signal(SIGHUP,  handle_sighup);
    }
} // end of namespace ProcessSignals

