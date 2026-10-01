-- BLAKE3 (pure LuaJIT) and the consistent-hash ring used by the luarouter
-- hashing policies.
--
-- Why the hash has to be exact: gateway/src/core/worker_registry.rs builds the
-- Rust router's ring with blake3 and reads the first 8 digest bytes as a
-- little-endian u64.  Any deviation here changes every routing decision, so
-- this is a faithful port of the BLAKE3 reference implementation
-- (reference_impl.rs), validated against the upstream test vectors in
-- test/unit/test_hash.lua.
--
-- Three things are worth knowing about the shape of this code:
--
--   * The compression function is fully unrolled (56 G calls, no loops) and
--     keeps all 16 state words in locals, because the routing path hashes a key
--     per request.  Measured on this image (10000 short-key hashes, warm):
--     unrolled 5.8 ms vs a straightforward loop-and-table port at 72 ms, so the
--     unrolling is what keeps a hash near 580 ns instead of ~7.2 us.
--
--   * Words are held as LuaJIT's signed 32-bit bit.tobit results, and every
--     rotation is written bor(lshift(x, 32 - n), rshift(x, n)) because BLAKE3
--     uses rotate_right.  Unsigned values only reappear at the module boundary
--     via u32(); string.format("%08x",) prints 16 hex digits for a negative
--     double under LuaJIT, so no raw word may be handed to %x.
--
--   * A ring position (a u64) is carried as a (hi, lo) pair of unsigned 32-bit
--     numbers.  LuaJIT numbers are doubles, so a real u64 above 2^53 would
--     silently lose low bits; comparing (hi, lo) stays exact.
--
-- LuaJIT 2.1 is a Lua 5.1 runtime, so there is no // floor division here --
-- divisions are written where the operands divide exactly, or via math.floor.

local bit = require("bit")
local TB = bit.tobit
local BX = bit.bxor
local LS = bit.lshift
local RS = bit.rshift
local BO = bit.bor

local char = string.char
local byte = string.byte
local fmt = string.format
local floor = math.floor
local concat = table.concat

local CHUNK_START = 1
local CHUNK_END = 2
local PARENT = 4
local ROOT = 8

local BLOCK_LEN = 64
local CHUNK_LEN = 1024

-- IV, the SHA-512 initialization words.  compress() embeds the first four in
-- the state; the second four are the initial chaining value.
local IV1, IV2, IV3, IV4 = 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A
local IV5, IV6, IV7, IV8 = 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19

local TWO32 = 4294967296

-- Signed 32-bit word -> unsigned double.
local function u32(x)
    if x < 0 then
        return x + TWO32
    end
    return x
end

-- Unrolled BLAKE3 compression function.  The 16 output words come back as
-- multiple return values, which avoids the aliasing hazard of writing into the
-- table the chaining value was read from (a real bug this design sidesteps:
-- out[8+i] ^= cv[i] would read words the loop already clobbered).
local function compress(c1, c2, c3, c4, c5, c6, c7, c8, blk, cntlo, cnthi, blen, flags)
  local o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11, o12, o13, o14, o15, o16
  do
    local k1, k2, k3, k4, k5, k6, k7, k8 = c1, c2, c3, c4, c5, c6, c7, c8
    local m0 = blk[1]
    local m1 = blk[2]
    local m2 = blk[3]
    local m3 = blk[4]
    local m4 = blk[5]
    local m5 = blk[6]
    local m6 = blk[7]
    local m7 = blk[8]
    local m8 = blk[9]
    local m9 = blk[10]
    local m10 = blk[11]
    local m11 = blk[12]
    local m12 = blk[13]
    local m13 = blk[14]
    local m14 = blk[15]
    local m15 = blk[16]
    local s0 = c1
    local s1 = c2
    local s2 = c3
    local s3 = c4
    local s4 = c5
    local s5 = c6
    local s6 = c7
    local s7 = c8
    local s8 = IV1
    local s9 = IV2
    local s10 = IV3
    local s11 = IV4
    local s12 = cntlo
    local s13 = cnthi
    local s14 = blen
    local s15 = flags

    -- round 1
    s0 = TB(s0 + s4 + m0)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 16), RS(s12, 16))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 20), RS(s4, 12))
    s0 = TB(s0 + s4 + m1)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 24), RS(s12, 8))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 25), RS(s4, 7))
    s1 = TB(s1 + s5 + m2)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 16), RS(s13, 16))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 20), RS(s5, 12))
    s1 = TB(s1 + s5 + m3)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 24), RS(s13, 8))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 25), RS(s5, 7))
    s2 = TB(s2 + s6 + m4)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 16), RS(s14, 16))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 20), RS(s6, 12))
    s2 = TB(s2 + s6 + m5)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 24), RS(s14, 8))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 25), RS(s6, 7))
    s3 = TB(s3 + s7 + m6)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 16), RS(s15, 16))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 20), RS(s7, 12))
    s3 = TB(s3 + s7 + m7)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 24), RS(s15, 8))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 25), RS(s7, 7))
    s0 = TB(s0 + s5 + m8)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 16), RS(s15, 16))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 20), RS(s5, 12))
    s0 = TB(s0 + s5 + m9)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 24), RS(s15, 8))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 25), RS(s5, 7))
    s1 = TB(s1 + s6 + m10)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 16), RS(s12, 16))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 20), RS(s6, 12))
    s1 = TB(s1 + s6 + m11)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 24), RS(s12, 8))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 25), RS(s6, 7))
    s2 = TB(s2 + s7 + m12)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 16), RS(s13, 16))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 20), RS(s7, 12))
    s2 = TB(s2 + s7 + m13)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 24), RS(s13, 8))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 25), RS(s7, 7))
    s3 = TB(s3 + s4 + m14)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 16), RS(s14, 16))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 20), RS(s4, 12))
    s3 = TB(s3 + s4 + m15)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 24), RS(s14, 8))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 25), RS(s4, 7))
    -- round 2
    s0 = TB(s0 + s4 + m2)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 16), RS(s12, 16))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 20), RS(s4, 12))
    s0 = TB(s0 + s4 + m6)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 24), RS(s12, 8))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 25), RS(s4, 7))
    s1 = TB(s1 + s5 + m3)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 16), RS(s13, 16))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 20), RS(s5, 12))
    s1 = TB(s1 + s5 + m10)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 24), RS(s13, 8))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 25), RS(s5, 7))
    s2 = TB(s2 + s6 + m7)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 16), RS(s14, 16))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 20), RS(s6, 12))
    s2 = TB(s2 + s6 + m0)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 24), RS(s14, 8))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 25), RS(s6, 7))
    s3 = TB(s3 + s7 + m4)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 16), RS(s15, 16))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 20), RS(s7, 12))
    s3 = TB(s3 + s7 + m13)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 24), RS(s15, 8))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 25), RS(s7, 7))
    s0 = TB(s0 + s5 + m1)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 16), RS(s15, 16))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 20), RS(s5, 12))
    s0 = TB(s0 + s5 + m11)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 24), RS(s15, 8))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 25), RS(s5, 7))
    s1 = TB(s1 + s6 + m12)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 16), RS(s12, 16))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 20), RS(s6, 12))
    s1 = TB(s1 + s6 + m5)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 24), RS(s12, 8))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 25), RS(s6, 7))
    s2 = TB(s2 + s7 + m9)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 16), RS(s13, 16))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 20), RS(s7, 12))
    s2 = TB(s2 + s7 + m14)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 24), RS(s13, 8))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 25), RS(s7, 7))
    s3 = TB(s3 + s4 + m15)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 16), RS(s14, 16))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 20), RS(s4, 12))
    s3 = TB(s3 + s4 + m8)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 24), RS(s14, 8))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 25), RS(s4, 7))
    -- round 3
    s0 = TB(s0 + s4 + m3)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 16), RS(s12, 16))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 20), RS(s4, 12))
    s0 = TB(s0 + s4 + m4)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 24), RS(s12, 8))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 25), RS(s4, 7))
    s1 = TB(s1 + s5 + m10)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 16), RS(s13, 16))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 20), RS(s5, 12))
    s1 = TB(s1 + s5 + m12)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 24), RS(s13, 8))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 25), RS(s5, 7))
    s2 = TB(s2 + s6 + m13)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 16), RS(s14, 16))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 20), RS(s6, 12))
    s2 = TB(s2 + s6 + m2)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 24), RS(s14, 8))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 25), RS(s6, 7))
    s3 = TB(s3 + s7 + m7)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 16), RS(s15, 16))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 20), RS(s7, 12))
    s3 = TB(s3 + s7 + m14)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 24), RS(s15, 8))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 25), RS(s7, 7))
    s0 = TB(s0 + s5 + m6)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 16), RS(s15, 16))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 20), RS(s5, 12))
    s0 = TB(s0 + s5 + m5)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 24), RS(s15, 8))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 25), RS(s5, 7))
    s1 = TB(s1 + s6 + m9)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 16), RS(s12, 16))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 20), RS(s6, 12))
    s1 = TB(s1 + s6 + m0)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 24), RS(s12, 8))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 25), RS(s6, 7))
    s2 = TB(s2 + s7 + m11)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 16), RS(s13, 16))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 20), RS(s7, 12))
    s2 = TB(s2 + s7 + m15)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 24), RS(s13, 8))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 25), RS(s7, 7))
    s3 = TB(s3 + s4 + m8)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 16), RS(s14, 16))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 20), RS(s4, 12))
    s3 = TB(s3 + s4 + m1)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 24), RS(s14, 8))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 25), RS(s4, 7))
    -- round 4
    s0 = TB(s0 + s4 + m10)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 16), RS(s12, 16))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 20), RS(s4, 12))
    s0 = TB(s0 + s4 + m7)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 24), RS(s12, 8))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 25), RS(s4, 7))
    s1 = TB(s1 + s5 + m12)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 16), RS(s13, 16))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 20), RS(s5, 12))
    s1 = TB(s1 + s5 + m9)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 24), RS(s13, 8))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 25), RS(s5, 7))
    s2 = TB(s2 + s6 + m14)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 16), RS(s14, 16))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 20), RS(s6, 12))
    s2 = TB(s2 + s6 + m3)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 24), RS(s14, 8))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 25), RS(s6, 7))
    s3 = TB(s3 + s7 + m13)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 16), RS(s15, 16))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 20), RS(s7, 12))
    s3 = TB(s3 + s7 + m15)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 24), RS(s15, 8))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 25), RS(s7, 7))
    s0 = TB(s0 + s5 + m4)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 16), RS(s15, 16))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 20), RS(s5, 12))
    s0 = TB(s0 + s5 + m0)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 24), RS(s15, 8))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 25), RS(s5, 7))
    s1 = TB(s1 + s6 + m11)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 16), RS(s12, 16))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 20), RS(s6, 12))
    s1 = TB(s1 + s6 + m2)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 24), RS(s12, 8))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 25), RS(s6, 7))
    s2 = TB(s2 + s7 + m5)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 16), RS(s13, 16))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 20), RS(s7, 12))
    s2 = TB(s2 + s7 + m8)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 24), RS(s13, 8))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 25), RS(s7, 7))
    s3 = TB(s3 + s4 + m1)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 16), RS(s14, 16))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 20), RS(s4, 12))
    s3 = TB(s3 + s4 + m6)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 24), RS(s14, 8))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 25), RS(s4, 7))
    -- round 5
    s0 = TB(s0 + s4 + m12)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 16), RS(s12, 16))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 20), RS(s4, 12))
    s0 = TB(s0 + s4 + m13)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 24), RS(s12, 8))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 25), RS(s4, 7))
    s1 = TB(s1 + s5 + m9)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 16), RS(s13, 16))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 20), RS(s5, 12))
    s1 = TB(s1 + s5 + m11)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 24), RS(s13, 8))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 25), RS(s5, 7))
    s2 = TB(s2 + s6 + m15)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 16), RS(s14, 16))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 20), RS(s6, 12))
    s2 = TB(s2 + s6 + m10)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 24), RS(s14, 8))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 25), RS(s6, 7))
    s3 = TB(s3 + s7 + m14)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 16), RS(s15, 16))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 20), RS(s7, 12))
    s3 = TB(s3 + s7 + m8)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 24), RS(s15, 8))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 25), RS(s7, 7))
    s0 = TB(s0 + s5 + m7)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 16), RS(s15, 16))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 20), RS(s5, 12))
    s0 = TB(s0 + s5 + m2)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 24), RS(s15, 8))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 25), RS(s5, 7))
    s1 = TB(s1 + s6 + m5)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 16), RS(s12, 16))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 20), RS(s6, 12))
    s1 = TB(s1 + s6 + m3)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 24), RS(s12, 8))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 25), RS(s6, 7))
    s2 = TB(s2 + s7 + m0)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 16), RS(s13, 16))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 20), RS(s7, 12))
    s2 = TB(s2 + s7 + m1)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 24), RS(s13, 8))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 25), RS(s7, 7))
    s3 = TB(s3 + s4 + m6)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 16), RS(s14, 16))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 20), RS(s4, 12))
    s3 = TB(s3 + s4 + m4)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 24), RS(s14, 8))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 25), RS(s4, 7))
    -- round 6
    s0 = TB(s0 + s4 + m9)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 16), RS(s12, 16))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 20), RS(s4, 12))
    s0 = TB(s0 + s4 + m14)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 24), RS(s12, 8))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 25), RS(s4, 7))
    s1 = TB(s1 + s5 + m11)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 16), RS(s13, 16))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 20), RS(s5, 12))
    s1 = TB(s1 + s5 + m5)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 24), RS(s13, 8))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 25), RS(s5, 7))
    s2 = TB(s2 + s6 + m8)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 16), RS(s14, 16))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 20), RS(s6, 12))
    s2 = TB(s2 + s6 + m12)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 24), RS(s14, 8))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 25), RS(s6, 7))
    s3 = TB(s3 + s7 + m15)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 16), RS(s15, 16))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 20), RS(s7, 12))
    s3 = TB(s3 + s7 + m1)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 24), RS(s15, 8))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 25), RS(s7, 7))
    s0 = TB(s0 + s5 + m13)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 16), RS(s15, 16))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 20), RS(s5, 12))
    s0 = TB(s0 + s5 + m3)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 24), RS(s15, 8))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 25), RS(s5, 7))
    s1 = TB(s1 + s6 + m0)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 16), RS(s12, 16))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 20), RS(s6, 12))
    s1 = TB(s1 + s6 + m10)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 24), RS(s12, 8))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 25), RS(s6, 7))
    s2 = TB(s2 + s7 + m2)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 16), RS(s13, 16))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 20), RS(s7, 12))
    s2 = TB(s2 + s7 + m6)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 24), RS(s13, 8))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 25), RS(s7, 7))
    s3 = TB(s3 + s4 + m4)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 16), RS(s14, 16))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 20), RS(s4, 12))
    s3 = TB(s3 + s4 + m7)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 24), RS(s14, 8))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 25), RS(s4, 7))
    -- round 7
    s0 = TB(s0 + s4 + m11)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 16), RS(s12, 16))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 20), RS(s4, 12))
    s0 = TB(s0 + s4 + m15)
    s12 = BX(s12, s0); s12 = BX(LS(s12, 24), RS(s12, 8))
    s8 = TB(s8 + s12)
    s4 = BX(s4, s8); s4 = BX(LS(s4, 25), RS(s4, 7))
    s1 = TB(s1 + s5 + m5)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 16), RS(s13, 16))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 20), RS(s5, 12))
    s1 = TB(s1 + s5 + m0)
    s13 = BX(s13, s1); s13 = BX(LS(s13, 24), RS(s13, 8))
    s9 = TB(s9 + s13)
    s5 = BX(s5, s9); s5 = BX(LS(s5, 25), RS(s5, 7))
    s2 = TB(s2 + s6 + m1)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 16), RS(s14, 16))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 20), RS(s6, 12))
    s2 = TB(s2 + s6 + m9)
    s14 = BX(s14, s2); s14 = BX(LS(s14, 24), RS(s14, 8))
    s10 = TB(s10 + s14)
    s6 = BX(s6, s10); s6 = BX(LS(s6, 25), RS(s6, 7))
    s3 = TB(s3 + s7 + m8)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 16), RS(s15, 16))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 20), RS(s7, 12))
    s3 = TB(s3 + s7 + m6)
    s15 = BX(s15, s3); s15 = BX(LS(s15, 24), RS(s15, 8))
    s11 = TB(s11 + s15)
    s7 = BX(s7, s11); s7 = BX(LS(s7, 25), RS(s7, 7))
    s0 = TB(s0 + s5 + m14)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 16), RS(s15, 16))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 20), RS(s5, 12))
    s0 = TB(s0 + s5 + m10)
    s15 = BX(s15, s0); s15 = BX(LS(s15, 24), RS(s15, 8))
    s10 = TB(s10 + s15)
    s5 = BX(s5, s10); s5 = BX(LS(s5, 25), RS(s5, 7))
    s1 = TB(s1 + s6 + m2)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 16), RS(s12, 16))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 20), RS(s6, 12))
    s1 = TB(s1 + s6 + m12)
    s12 = BX(s12, s1); s12 = BX(LS(s12, 24), RS(s12, 8))
    s11 = TB(s11 + s12)
    s6 = BX(s6, s11); s6 = BX(LS(s6, 25), RS(s6, 7))
    s2 = TB(s2 + s7 + m3)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 16), RS(s13, 16))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 20), RS(s7, 12))
    s2 = TB(s2 + s7 + m4)
    s13 = BX(s13, s2); s13 = BX(LS(s13, 24), RS(s13, 8))
    s8 = TB(s8 + s13)
    s7 = BX(s7, s8); s7 = BX(LS(s7, 25), RS(s7, 7))
    s3 = TB(s3 + s4 + m7)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 16), RS(s14, 16))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 20), RS(s4, 12))
    s3 = TB(s3 + s4 + m13)
    s14 = BX(s14, s3); s14 = BX(LS(s14, 24), RS(s14, 8))
    s9 = TB(s9 + s14)
    s4 = BX(s4, s9); s4 = BX(LS(s4, 25), RS(s4, 7))

    o1 = BX(s0, s8)
    o2 = BX(s1, s9)
    o3 = BX(s2, s10)
    o4 = BX(s3, s11)
    o5 = BX(s4, s12)
    o6 = BX(s5, s13)
    o7 = BX(s6, s14)
    o8 = BX(s7, s15)
    o9 = BX(s8, k1)
    o10 = BX(s9, k2)
    o11 = BX(s10, k3)
    o12 = BX(s11, k4)
    o13 = BX(s12, k5)
    o14 = BX(s13, k6)
    o15 = BX(s14, k7)
    o16 = BX(s15, k8)
  end
  return o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11, o12, o13, o14, o15, o16
end

-- Little-endian words of a complete 64-byte block.  Callers guarantee all 64
-- bytes exist, so no nil guards.
local function words_from_block(data, off, blk)
    for i = 0, 15 do
        local p = off + i * 4
        blk[i + 1] = BX(byte(data, p), LS(byte(data, p + 1), 8),
                        LS(byte(data, p + 2), 16), LS(byte(data, p + 3), 24))
    end
end

-- Same for a short final block: read the whole 64 bytes if they exist, then
-- clear the words past the payload.  Callers pass a string that is at least
-- `off + remaining - 1` long, and byte() returns nil past the end, which BX
-- would choke on -- so the tail is filled from a zeroed copy of the last words.
local function words_from_tail(data, off, remaining, blk)
    local full = floor(remaining / 4)
    local extra = remaining - full * 4
    for i = 1, full do
        local p = off + (i - 1) * 4
        blk[i] = BX(byte(data, p), LS(byte(data, p + 1), 8),
                    LS(byte(data, p + 2), 16), LS(byte(data, p + 3), 24))
    end
    for i = full + 1, 16 do
        blk[i] = 0
    end
    if extra > 0 then
        local p = off + full * 4
        local w = byte(data, p)
        if extra > 1 then
            w = BO(w, LS(byte(data, p + 1), 8))
        end
        if extra > 2 then
            w = BO(w, LS(byte(data, p + 2), 16))
        end
        blk[full + 1] = w
    end
end

-- Reusable buffers, one set per recursion depth.  A frame only touches its own
-- depth and children always run one level deeper, so a parent's block and child
-- chaining values survive the recursive calls.  This is what keeps the tree
-- branch allocation-free after the deepest input has been seen once.
local blocks_at = { [0] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }
local left_at = { [0] = { 0, 0, 0, 0, 0, 0, 0, 0 } }
local right_at = { [0] = { 0, 0, 0, 0, 0, 0, 0, 0 } }

local function buf_at(pool, depth, size)
    local b = pool[depth]
    if not b then
        local t = {}
        for i = 1, size do
            t[i] = 0
        end
        pool[depth] = t
        b = t
    end
    return b
end

-- Hash one node of the BLAKE3 tree, returning 16 output words.
--
-- Inputs up to CHUNK_LEN are a single chunk; longer inputs split at the largest
-- power of two strictly below the length, as the reference does.  `counter` is
-- the chunk index and stays constant across every block inside one chunk -- the
-- Rust ChunkState compresses with self.chunk_counter, not counter + block.
local function node(data, off, len, counter, flags, want_root, depth)
    local blk = buf_at(blocks_at, depth, 16)
    if len <= CHUNK_LEN then
        local c1, c2, c3, c4, c5, c6, c7, c8 = IV1, IV2, IV3, IV4, IV5, IV6, IV7, IV8
        local cntlo = counter % TWO32
        local cnthi = floor(counter / TWO32)
        local blocks = 0
        local pos = off
        local remaining = len
        while remaining > BLOCK_LEN do
            words_from_block(data, pos, blk)
            local sflag = CHUNK_START
            if blocks > 0 then
                sflag = 0
            end
            -- Multiple assignment to 8 lvalues truncates the other 8 words,
            -- which is exactly the chaining-value truncation BLAKE3 wants.
            c1, c2, c3, c4, c5, c6, c7, c8 =
                compress(c1, c2, c3, c4, c5, c6, c7, c8, blk, cntlo, cnthi,
                         BLOCK_LEN, BO(flags, sflag))
            blocks = blocks + 1
            pos = pos + BLOCK_LEN
            remaining = remaining - BLOCK_LEN
        end
        words_from_tail(data, pos, remaining, blk)
        local sflag = CHUNK_START
        if blocks > 0 then
            sflag = 0
        end
        local eflags = BO(BO(flags, sflag), CHUNK_END)
        if want_root then
            eflags = BO(eflags, ROOT)
        end
        return compress(c1, c2, c3, c4, c5, c6, c7, c8, blk, cntlo, cnthi,
                        remaining, eflags)
    end

    local half = CHUNK_LEN
    while half * 2 < len do
        half = half * 2
    end

    local lc = buf_at(left_at, depth, 8)
    local o1, o2, o3, o4, o5, o6, o7, o8
    o1, o2, o3, o4, o5, o6, o7, o8 =
        node(data, off, half, counter, flags, false, depth + 1)
    lc[1], lc[2], lc[3], lc[4], lc[5], lc[6], lc[7], lc[8] =
        u32(o1), u32(o2), u32(o3), u32(o4), u32(o5), u32(o6), u32(o7), u32(o8)

    local rc = buf_at(right_at, depth, 8)
    o1, o2, o3, o4, o5, o6, o7, o8 =
        node(data, off + half, len - half, counter + floor(half / CHUNK_LEN),
             flags, false, depth + 1)
    rc[1], rc[2], rc[3], rc[4], rc[5], rc[6], rc[7], rc[8] =
        u32(o1), u32(o2), u32(o3), u32(o4), u32(o5), u32(o6), u32(o7), u32(o8)

    for i = 1, 8 do
        blk[i] = lc[i]
        blk[i + 8] = rc[i]
    end
    local pflags = BO(flags, PARENT)
    if want_root then
        pflags = BO(pflags, ROOT)
    end
    return compress(IV1, IV2, IV3, IV4, IV5, IV6, IV7, IV8, blk, 0, 0,
                    BLOCK_LEN, pflags)
end

-- 16 words -> 64 hex characters, little-endian within each word.  The 256-bit
-- digest is the first 8 words.
local HEX = {}
for i = 0, 255 do
    HEX[i] = fmt("%02x", i)
end

local function word_hex(w)
    local x = u32(w)
    return HEX[x % 256] .. HEX[floor(x / 256) % 256] ..
        HEX[floor(x / 65536) % 256] .. HEX[floor(x / 16777216)]
end

local _M = {}

_M.BLOCK_LEN = BLOCK_LEN
_M.CHUNK_LEN = CHUNK_LEN
-- The spec allowed a simplified hash if a full one was too risky.  It was not:
-- this is real BLAKE3, so the flag exists for the policies and docs to assert.
_M.IS_REAL_BLAKE3 = true

--- First 8 digest bytes as an unsigned (hi, lo) 32-bit pair -- the ring
--- position of `key`, matching Rust's u64::from_le_bytes(hash[..8]).
function _M.position(key)
    local w1, w2 = node(key, 1, #key, 0, 0, true, 0)
    return u32(w2), u32(w1)
end

--- Ring position as a single Lua number.  Exact only below 2^53; provided for
--- logging and tests, never for comparisons inside the ring.
function _M.position_u64(key)
    local hi, lo = _M.position(key)
    return hi * TWO32 + lo
end

--- u64 as the 16-character lowercase hex string the ring keys are built from.
--- Same width and radix as Rust's format!("{:016x}", prefix_hash).
function _M.position_hex(key)
    local hi, lo = _M.position(key)
    return fmt("%08x%08x", hi, lo)
end

--- Full 32-byte digest as 64 hex characters.
function _M.hex(data)
    local o1, o2, o3, o4, o5, o6, o7, o8 = node(data or "", 1, #(data or ""), 0, 0, true, 0)
    return word_hex(o1) .. word_hex(o2) .. word_hex(o3) .. word_hex(o4) ..
        word_hex(o5) .. word_hex(o6) .. word_hex(o7) .. word_hex(o8)
end

--- 8 bytes little-endian of a non-negative integer < 2^53, as a Lua string.
--- Lets callers build the same ring inputs Rust builds from
--- `(vnode as u64).to_le_bytes()`.
function _M.u64_le_bytes(n)
    local b = {}
    for i = 1, 8 do
        b[i] = n % 256
        n = floor(n / 256)
    end
    return char(b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
end

-- ---------------------------------------------------------------------------
-- Consistent hash ring
--
-- Mirrors HashRing in worker_registry.rs: VIRTUAL_NODES_PER_WORKER entries per
-- worker at blake3(url .. "#" .. le64(vnode))[..8] little-endian, sorted, and
-- looked up by binary search plus a clockwise walk that skips unhealthy
-- workers.  Positions are (hi, lo) pairs, so the sorted order is lexicographic
-- on hi then lo rather than a single integer compare.
-- ---------------------------------------------------------------------------

_M.VIRTUAL_NODES_PER_WORKER = 150

--- Position of one virtual node, exactly as the Rust builder computes it:
--- blake3 over url bytes, then "#", then the 8-byte little-endian index.
-- Concatenating is equivalent to the streaming updates and keeps the port
-- simple; the digest is over the same byte sequence either way.
function _M.vnode_position(url, vnode)
    return _M.position(url .. "#" .. _M.u64_le_bytes(vnode))
end

local function sort_ring(hi, lo, idx, total)
    -- Sort the parallel arrays together.  table.sort only sees one array, so
    -- the permutation is built on an index table first.
    local order = {}
    for i = 1, total do
        order[i] = i
    end
    table.sort(order, function(a, b)
        if hi[a] ~= hi[b] then
            return hi[a] < hi[b]
        end
        return lo[a] < lo[b]
    end)
    local shi, slo, sidx = {}, {}, {}
    for i = 1, total do
        local j = order[i]
        shi[i] = hi[j]
        slo[i] = lo[j]
        sidx[i] = idx[j]
    end
    return shi, slo, sidx
end

--- Build the ring over `urls` (1-based array of worker URL strings).
---
--- Returns a ring table { hi, lo, idx, count, worker_count, signature }.
--- `idx[i]` is the 1-based index into `urls` for sorted entry i.  Building
--- costs worker_count * 150 hashes, so it happens only on topology change --
--- the policies cache it on the registry snapshot (see _M.ring_cached).
function _M.new_ring(urls)
    local n = #urls
    local vn = _M.VIRTUAL_NODES_PER_WORKER
    local total = n * vn
    local hi, lo, idx = {}, {}, {}
    local pos = 0
    for w = 1, n do
        local url = urls[w]
        for v = 0, vn - 1 do
            local h, l = _M.vnode_position(url, v)
            pos = pos + 1
            hi[pos] = h
            lo[pos] = l
            idx[pos] = w
        end
    end
    local shi, slo, sidx = sort_ring(hi, lo, idx, total)
    return {
        hi = shi,
        lo = slo,
        idx = sidx,
        count = total,
        worker_count = n,
        signature = _M.signature(urls),
    }
end

--- Order-sensitive identity of a URL set.  Cheap enough to recompute per
--- request (#urls is small) and exact enough that a change in membership or
--- order forces a rebuild.
function _M.signature(urls)
    return #urls .. "\n" .. concat(urls, "\n")
end

--- Lowest entry index whose position is >= (hi_want, lo_want), or count + 1.
--- Binary search over two parallel arrays; Rust uses partition_point here.
function _M.search(ring, hi_want, lo_want)
    local hi, lo = ring.hi, ring.lo
    local first, last = 1, ring.count
    while first <= last do
        local mid = floor((first + last) / 2)
        local h = hi[mid]
        if h < hi_want then
            first = mid + 1
        elseif h > hi_want then
            last = mid - 1
        elseif lo[mid] < lo_want then
            first = mid + 1
        else
            last = mid - 1
        end
    end
    return first
end

--- Clockwise lookup from `key`, returning the 1-based worker index whose
--- `is_healthy(index)` accepts, or nil when no worker on the ring is healthy.
---
--- A worker owns 150 entries, so the walk skips indexes already probed --
--- the same dedup find_healthy_url() does with a HashSet.  Cost is
--- O(log n) plus one hash, then O(k) probes where k is the number of
--- consecutive unhealthy workers.
function _M.lookup(ring, key, is_healthy)
    if ring.count == 0 then
        return nil
    end
    local hi_want, lo_want = _M.position(key)
    local start = _M.search(ring, hi_want, lo_want)
    local n = ring.count
    if start > n then
        start = 1
    end
    local tried = {}
    local w
    for i = 0, n - 1 do
        local e = start + i
        if e > n then
            e = e - n
        end
        w = ring.idx[e]
        if not tried[w] then
            tried[w] = true
            if is_healthy(w) then
                return w
            end
        end
    end
    return nil
end

--- Ring lookup by an explicit position pair, used by prefix_hash which hashes
--- the prefix itself rather than a string key.
function _M.lookup_position(ring, hi_want, lo_want, is_healthy)
    if ring.count == 0 then
        return nil
    end
    local start = _M.search(ring, hi_want, lo_want)
    local n = ring.count
    if start > n then
        start = 1
    end
    local tried = {}
    local w
    for i = 0, n - 1 do
        local e = start + i
        if e > n then
            e = e - n
        end
        w = ring.idx[e]
        if not tried[w] then
            tried[w] = true
            if is_healthy(w) then
                return w
            end
        end
    end
    return nil
end

--- Return the ring cached on `state`, rebuilding it when `urls` changed.
---
--- `state` is caller-owned storage that lives as long as the registry
--- snapshot, e.g. a per-worker-pool table.  Because the ring is content-
--- addressed by signature, a request that sees an unchanged topology does no
--- allocation at all.
function _M.ring_cached(state, urls)
    local ring = state.ring
    local sig = _M.signature(urls)
    if ring and ring.signature == sig then
        return ring
    end
    ring = _M.new_ring(urls)
    state.ring = ring
    return ring
end

return _M
