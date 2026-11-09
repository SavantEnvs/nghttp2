// Fuzzes the HTTP2-Settings path of nghttpx's HTTP/1.1 -> h2c upgrade
// (Http2Upstream::upgrade_upstream in src/shrpx_http2_upstream.cc): the request header value is
// attacker-controlled and goes through util::to_base64, then base64::decode.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string_view>

#include "allocator.h"
#include "base64.h"

using namespace nghttp2;

namespace {
// util::to_base64 (src/util.cc), copied: src/util.cc needs the third-party/urlparse submodule,
// which the image build context lacks. It maps base64url to base64 and pads to a multiple of 4.
std::string_view to_base64(BlockAllocator &balloc, std::string_view token68str) {
  auto len = token68str.size() + 3;
  auto iov = make_byte_ref(balloc, len + 1);

  auto p =
    std::ranges::transform(token68str, std::ranges::begin(iov), [](char c) {
      switch (c) {
      case '-':
        return '+';
      case '_':
        return '/';
      default:
        return c;
      }
    }).out;

  auto rem = token68str.size() & 0x3;
  if (rem) {
    p = std::ranges::fill_n(p, static_cast<std::ptrdiff_t>(4 - rem), '=');
  }

  *p = '\0';

  return std::string_view{reinterpret_cast<const char *>(iov.data()),
                          static_cast<size_t>(p - std::ranges::begin(iov))};
}
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  BlockAllocator balloc(1024, 1024);

  auto settings =
    to_base64(balloc, std::string_view{reinterpret_cast<const char *>(data), size});
  auto payload = base64::decode(balloc, settings);
  (void)payload;

  return 0;
}
