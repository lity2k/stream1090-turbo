/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2025 Martin Gronemann
 *
 * This file is part of stream1090 and is licensed under the GNU General
 * Public License v3. See the top-level LICENSE file for details.
 */

#pragma once

#include "Bits128.hpp"
#include "CRC.hpp"
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// Downlink formats the demodulator actually looks at: 0, 4, 5, 11, 16, 17, 18,
// 19, 20, 21. Every other value is dropped right away, so the shift register
// can tell the caller which streams are worth a closer look and which are not.
inline constexpr uint32_t handledDownlinkFormats =
      (1u <<  0) | (1u <<  4) | (1u <<  5) | (1u << 11)
    | (1u << 16) | (1u << 17) | (1u << 18) | (1u << 19)
    | (1u << 20) | (1u << 21);

template<int NumStreams>
class alignas(16) ShiftRegistersBase {
    public:

    // one bit per stream has to fit into the returned mask
    static_assert(NumStreams <= 64, "stream mask is 64 bit wide");

    // The vector update walks the streams four at a time, so the arrays are
    // padded up to a whole group. Padding lanes shift in zeros and their hits
    // are masked off before the mask leaves shiftInNewBits().
    static constexpr int NumGroups = (NumStreams + 3) / 4;
    static constexpr int Padded    = NumGroups * 4;
    static constexpr uint64_t StreamMask =
        (NumStreams >= 64) ? ~uint64_t(0) : ((uint64_t(1) << NumStreams) - 1);
    static constexpr int Half = NumStreams / 2;

    constexpr ShiftRegistersBase() noexcept {
        for (auto i = 0; i < Padded; i++) {
        #if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
            m_w0[i] = 0;
            m_w1[i] = 0;
            m_w2[i] = 0;
            m_w3[i] = 0;
        #else
            m_high[i] = 0;
            m_low[i]  = 0;
        #endif
            m_crc_56[i]  = 0;
            m_crc_112[i] = 0;
        };
    }

    constexpr CRC::crc_t getCRC_56(auto i) const noexcept {
        return m_crc_56[i];
    }

    constexpr CRC::crc_t getCRC_112(auto i) const noexcept {
        return m_crc_112[i];
    }

    /// The downlink format is the top five bits of the register, so keeping a
    /// separate array for it meant storing NumStreams words every sample to
    /// serve a read that only happens on a handled format. Derived here
    /// instead, from the value the update has already written.
    constexpr uint32_t getDF(auto i) const noexcept {
    #if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
        return m_w3[i] >> 27;
    #else
        return (uint32_t)(m_high[i] >> 59);
    #endif
    }

    protected:

#if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
    // The 128 bit register of every stream, split into its four 32 bit words:
    // one array per word, one lane per stream. A shift left by one is then a
    // per lane shift plus the carry from the next lower word, and both stay
    // inside the lanes, so four streams move through the update together.
    // Word 0 holds bits 31..0, word 3 bits 127..96.
    // (An interleaved layout with VLD4/VST4 was measured 12% slower on the
    // Cortex-A7: structured accesses are multi-cycle and stall the pipeline,
    // plain VLD1 overlaps with the NEON arithmetic. Do not retry.)
    uint32_t m_w0[Padded];
    uint32_t m_w1[Padded];
    uint32_t m_w2[Padded];
    uint32_t m_w3[Padded];
#else
    uint64_t m_low[Padded];
    uint64_t m_high[Padded];
#endif

	// And a checksum for the short messages (56 bit). Never wider than 25 bits,
	// so it is held in 32 and the update moves half the bytes it used to.
	CRC::crc_t m_crc_56[Padded];

    // Each stream has a checksum for long messages (112 bit)
	CRC::crc_t m_crc_112[Padded];
};


template<int NumStreams>
class alignas(16) ShiftRegisters : public ShiftRegistersBase<NumStreams> {
    public:
        constexpr ShiftRegisters() : ShiftRegistersBase<NumStreams>() { }

        /// Shifts one new bit into every stream and updates both CRCs.
        /// Returns a mask with bit i set when stream i now shows a downlink
        /// format the demodulator handles.
        ///
        /// The two conditionals of the textbook version (did we shift a one out
        /// of the register, did the CRC overflow past 24 bits) are replaced by
        /// masks. Both are close to coin flips, so as branches they were mostly
        /// mispredictions, and without them the loop has no control flow left
        /// for the compiler to trip over.
        uint64_t shiftInNewBits(const uint32_t* cmp) noexcept {
        #if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
            return shiftInNewBitsNeon([&](int g) { return vld1q_u32(cmp + 4 * g); });
        #else
            uint64_t handledMask = 0;

            for (auto i = 0; i < NumStreams; i++) {
                const uint64_t high = this->m_high[i];
                const uint64_t low  = this->m_low[i];

                // all ones when a one bit leaves the register at the top
                const uint32_t shiftedOut = uint32_t(0) - uint32_t(high >> 63);

                uint32_t crc56  = this->m_crc_56[i]  ^ (Delta55  & shiftedOut);
                uint32_t crc112 = this->m_crc_112[i] ^ (Delta111 & shiftedOut);

                crc56  = (crc56  << 1) | uint32_t((high >> 7)  & 0x1);
                crc112 = (crc112 << 1) | uint32_t((low  >> 15) & 0x1);

                const uint64_t newHigh = (high << 1) | (low >> 63);
                const uint64_t newLow  = (low  << 1) | cmp[i];
                const uint64_t df      = newHigh >> 59;

                // Fold the polynomial back in whenever bit 24 is set. The CRC
                // never exceeds 25 bits here, so the shift is a 0/1 flag.
                crc56  ^= Polynomial & (uint32_t(0) - (crc56  >> 24));
                crc112 ^= Polynomial & (uint32_t(0) - (crc112 >> 24));

                this->m_crc_56[i]  = crc56;
                this->m_crc_112[i] = crc112;
                this->m_high[i]    = newHigh;
                this->m_low[i]     = newLow;

                handledMask |= uint64_t((handledDownlinkFormats >> df) & 0x1) << i;
            }

            return handledMask;
        #endif
        }

        /// Same update, but the bits come straight off the magnitude ring:
        /// stream j's bit is mag[j] > mag[j + NumStreams/2]. Doing the compare
        /// inside the update keeps the per bit result in a vector register
        /// instead of round tripping it through a NumStreams wide array.
        uint64_t shiftInNewBitsFromSamples(const int32_t* mag) noexcept {
        #if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
            using Base = ShiftRegistersBase<NumStreams>;
            const uint32x4_t one = vdupq_n_u32(1u);
            return shiftInNewBitsNeon([&](int g) {
                const int o = 4 * g;
                uint32x4_t cmp = vcgtq_s32(vld1q_s32(mag + o), vld1q_s32(mag + o + Base::Half));
                if constexpr (Base::Padded != NumStreams)
                    cmp = vandq_u32(cmp, laneValidMask(g));
                return vandq_u32(cmp, one);
            });
        #else
            using Base = ShiftRegistersBase<NumStreams>;
            uint32_t cmp[Base::Padded];
            for (auto i = 0; i < NumStreams; i++)
                cmp[i] = mag[i] > mag[i + Base::Half];
            for (auto i = NumStreams; i < Base::Padded; i++)
                cmp[i] = 0;
            return shiftInNewBits(cmp);
        #endif
        }

        constexpr Bits128 extractAlignedFrameLong(auto i) const noexcept {
        #if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
            const uint64_t w0 = this->m_w0[i];
            const uint64_t w1 = this->m_w1[i];
            const uint64_t w2 = this->m_w2[i];
            const uint64_t w3 = this->m_w3[i];
            // the frame is the register shifted down by 16, cut back into the
            // two halves Bits128 wants
            return Bits128((w3 << 16) | (w2 >> 16),
                           (w1 << 16) | (w0 >> 16) | ((w2 & 0xffffu) << 48));
        #else
            return Bits128(this->m_high[i] >> 16, (this->m_low[i] >> 16) | (this->m_high[i] << 48));
        #endif
        }

        constexpr uint64_t extractAlignedFrameShort(auto i) const noexcept {
        #if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
            return (uint64_t(this->m_w3[i]) << 24) | (this->m_w2[i] >> 8);
        #else
            return (this->m_high[i] >> 8);
        #endif
        }

    private:
    #if defined(__ARM_NEON) && !defined(STREAM1090_NO_NEON_SHIFTREG)
        // all ones in the lanes that hold a real stream, zero in the padding
        static uint32x4_t laneValidMask(int g) noexcept {
            uint32_t v[4];
            for (int l = 0; l < 4; l++)
                v[l] = (4 * g + l < NumStreams) ? ~uint32_t(0) : 0u;
            return vld1q_u32(v);
        }

        /// Four streams of the update. getCmp(g) returns the new bit of each
        /// lane as 0/1.
        template<typename CmpFn>
        uint64_t shiftInNewBitsNeon(CmpFn getCmp) noexcept {
            using Base = ShiftRegistersBase<NumStreams>;

            const uint32x4_t one  = vdupq_n_u32(1u);
            const uint32x4_t poly = vdupq_n_u32(uint32_t(Polynomial));
            const uint32x4_t d55  = vdupq_n_u32(uint32_t(Delta55));
            const uint32x4_t d111 = vdupq_n_u32(uint32_t(Delta111));
            const uint32x4_t fmts = vdupq_n_u32(handledDownlinkFormats);

            // one bit per lane, the lane's own place in the returned mask
            uint32x4_t weight = { 1u, 2u, 4u, 8u };
            uint32x4_t acc = vdupq_n_u32(0u);

            for (int g = 0; g < Base::NumGroups; g++) {
                const int o = 4 * g;
                const uint32x4_t cmp = getCmp(g);

                const uint32x4_t w0 = vld1q_u32(this->m_w0 + o);
                const uint32x4_t w1 = vld1q_u32(this->m_w1 + o);
                const uint32x4_t w2 = vld1q_u32(this->m_w2 + o);
                const uint32x4_t w3 = vld1q_u32(this->m_w3 + o);
                uint32x4_t c56  = vld1q_u32(this->m_crc_56  + o);
                uint32x4_t c112 = vld1q_u32(this->m_crc_112 + o);

                // carry out of each word, and all ones when a one leaves the
                // register at the top (arithmetic shift signs the lane)
                const uint32x4_t k0 = vshrq_n_u32(w0, 31);
                const uint32x4_t k1 = vshrq_n_u32(w1, 31);
                const uint32x4_t k2 = vshrq_n_u32(w2, 31);
                const uint32x4_t shiftOut = vreinterpretq_u32_s32(
                    vshrq_n_s32(vreinterpretq_s32_u32(w3), 31));

                // vsli shifts the word left and inserts the incoming bit into
                // the hole that opens at bit zero, so one instruction moves a
                // whole word where a shift and an or used to be two
                const uint32x4_t n0 = vsliq_n_u32(cmp, w0, 1);
                const uint32x4_t n1 = vsliq_n_u32(k0,  w1, 1);
                const uint32x4_t n2 = vsliq_n_u32(k1,  w2, 1);
                const uint32x4_t n3 = vsliq_n_u32(k2,  w3, 1);

                // a one leaving the register removes its delayed contribution
                c56  = veorq_u32(c56,  vandq_u32(d55,  shiftOut));
                c112 = veorq_u32(c112, vandq_u32(d111, shiftOut));

                // bit 71 feeds the 56 bit crc, bit 15 the 112 bit one
                c56  = vsliq_n_u32(vandq_u32(vshrq_n_u32(w2, 7),  one), c56,  1);
                c112 = vsliq_n_u32(vandq_u32(vshrq_n_u32(w0, 15), one), c112, 1);

                // fold the polynomial back in whenever bit 24 is set: the crc
                // never exceeds 25 bits, so the shift is a 0/1 flag and its
                // negation is the all ones mask
                c56  = veorq_u32(c56,  vandq_u32(poly, vreinterpretq_u32_s32(
                    vnegq_s32(vreinterpretq_s32_u32(vshrq_n_u32(c56,  24))))));
                c112 = veorq_u32(c112, vandq_u32(poly, vreinterpretq_u32_s32(
                    vnegq_s32(vreinterpretq_s32_u32(vshrq_n_u32(c112, 24))))));

                // the downlink format is the top five bits of the new register
                const uint32x4_t df = vshrq_n_u32(n3, 27);
                // the weight of a lane is its own bit in the mask, so the hit
                // has to gate it as an all ones mask and not as a 0/1 value
                const uint32x4_t isHandled =
                    vceqq_u32(vandq_u32(vshlq_u32(fmts, vnegq_s32(vreinterpretq_s32_u32(df))), one), one);
                acc = vorrq_u32(acc, vandq_u32(isHandled, weight));
                weight = vshlq_n_u32(weight, 4);

                vst1q_u32(this->m_w0 + o, n0);
                vst1q_u32(this->m_w1 + o, n1);
                vst1q_u32(this->m_w2 + o, n2);
                vst1q_u32(this->m_w3 + o, n3);
                vst1q_u32(this->m_crc_56  + o, c56);
                vst1q_u32(this->m_crc_112 + o, c112);
            }

            uint32x2_t packed = vorr_u32(vget_low_u32(acc), vget_high_u32(acc));
            packed = vorr_u32(packed, vext_u32(packed, packed, 1));
            return uint64_t(vget_lane_u32(packed, 0)) & Base::StreamMask;
        }
    #endif

        static constexpr CRC::crc_t Delta55  = CRC::delta<55>();
        static constexpr CRC::crc_t Delta111 = CRC::delta<111>();
        static constexpr CRC::crc_t Polynomial = CRC::polynomial;

};
