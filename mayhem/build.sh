#!/usr/bin/env bash
#
# mayhem/build.sh — build the libnghttp2 fuzz harnesses and the munit suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Fuzz instrumentation must reach the library itself (SanCov via fuzzer-no-link), not only the harness.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
COMMON_CMAKE=(-DENABLE_LIB_ONLY=ON -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF -DENABLE_DOC=OFF
              -DBUILD_TESTING=OFF -DENABLE_FAILMALLOC=OFF -DENABLE_WERROR=OFF -DENABLE_THREADS=OFF
              -DCMAKE_BUILD_TYPE=RelWithDebInfo)

# Idempotent re-runs: cmake discards its cache when the compiler path changes (ccache masquerade at
# image build vs plain `clang` on re-run) and the dependent BUILD_* options then misbehave, so start clean.
rm -rf build/fuzz build/tests build/munit
mkdir -p build && tar -xzf mayhem/vendor/munit.tar.gz -C build

# 1) Sanitized libnghttp2.a (ASan+UBSan halting, DWARF 3) in build/fuzz (build/ is gitignored upstream).
cmake -S . -B build/fuzz "${COMMON_CMAKE[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS" \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O1" -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O1"
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target nghttp2_static

LIB=build/fuzz/lib/libnghttp2.a
INC=(-I"$SRC/lib/includes" -I"$SRC/build/fuzz/lib/includes")
# Internal headers (lib/, tests/, generated config.h) for the frames harness.
INT=("${INC[@]}" -DHAVE_CONFIG_H -I"$SRC/lib" -I"$SRC/build/fuzz" -I"$SRC/tests" -I"$SRC/build/munit")

# 2) Harness helper objects: LSan off-switch, the C-linkage standalone driver, the test helper.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/fuzz/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${INT[@]}" -c tests/nghttp2_test_helper.c -o build/fuzz/nghttp2_test_helper.o

build_harness() {  # <binary name> <source> [extra objects/flags...]
  local name="$1" src="$2"; shift 2
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INT[@]}" $LIB_FUZZING_ENGINE \
    "$src" "$@" build/fuzz/lsan_off.o "$LIB" -o "/mayhem/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INT[@]}" \
    "$src" "$@" build/fuzz/standalone_main.o build/fuzz/lsan_off.o "$LIB" -o "/mayhem/$name-standalone"
}
build_harness nghttp2_fuzzer        fuzz/fuzz_target.cc
build_harness nghttp2_fuzzer_fdp    fuzz/fuzz_target_fdp.cc
build_harness nghttp2_fuzzer_frames fuzz/fuzz_frames.cc build/fuzz/nghttp2_test_helper.o

# 3) The project's munit suite with NORMAL flags (no sanitizers, no fuzz instrumentation) in build/tests.
#    upstream's tests/munit is a git submodule the image build context lacks, so munit (ngtcp2/munit
#    @ cb04288a, the submodule's pin) is vendored as mayhem/vendor/munit.tar.gz and unpacked into the
#    gitignored build/ tree; tests/CMakeLists.txt is bypassed (it requires the submodule's sources).
cmake -S . -B build/tests "${COMMON_CMAKE[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests -j"$MAYHEM_JOBS" --target nghttp2_static

TEST_SRCS=(main.c nghttp2_pq_test.c nghttp2_map_test.c nghttp2_queue_test.c nghttp2_test_helper.c
           nghttp2_frame_test.c nghttp2_stream_test.c nghttp2_session_test.c nghttp2_hd_test.c
           nghttp2_alpn_test.c nghttp2_helper_test.c nghttp2_buf_test.c nghttp2_http_test.c
           nghttp2_extpri_test.c nghttp2_ratelim_test.c)
$CC -O2 $COVERAGE_FLAGS -DHAVE_CONFIG_H -I"$SRC/lib/includes" -I"$SRC/build/tests/lib/includes" \
  -I"$SRC/lib" -I"$SRC/build/tests" -I"$SRC/tests" -I"$SRC/build/munit" \
  "${TEST_SRCS[@]/#/tests/}" build/munit/munit.c build/tests/lib/libnghttp2.a \
  -o build/tests/nghttp2_tests
