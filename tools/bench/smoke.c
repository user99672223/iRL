/* iRL ARM64 bench smoke test: integer, SSE2 float/double and string work whose checksum must be
 * identical natively and under Wine+FEX (x86-64 PE). Prints one line: "checksum <hex>". */
#include <emmintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint64_t mix(uint64_t h, uint64_t v) { h ^= v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2); return h; }

int main(void) {
  uint64_t h = 1469598103934665603ull;
  for (uint32_t i = 0; i < 2000000; i++) {
    uint64_t x = i * 2654435761u;
    x ^= x >> 13; x *= 0xff51afd7ed558ccdull; x ^= x >> 33;
    h = mix(h, x);
  }
  __m128 a = _mm_set_ps(1.5f, -2.25f, 3.125f, 4.0f), b = _mm_set1_ps(0.75f);
  __m128d c = _mm_set_pd(1e-3, 3.0), d = _mm_set1_pd(1.0000001);
  for (int i = 0; i < 100000; i++) {
    a = _mm_add_ps(_mm_mul_ps(a, b), _mm_set1_ps(0.5f));
    c = _mm_div_pd(_mm_add_pd(c, d), _mm_set1_pd(1.0000003));
  }
  float fa[4]; double dc[2];
  _mm_storeu_ps(fa, a); _mm_storeu_pd(dc, c);
  uint32_t fb[4]; uint64_t db[2];
  memcpy(fb, fa, sizeof fb); memcpy(db, dc, sizeof db);
  for (int i = 0; i < 4; i++) h = mix(h, fb[i]);
  for (int i = 0; i < 2; i++) h = mix(h, db[i]);
  char buf[4096];
  for (int i = 0; i < (int)sizeof buf; i++) buf[i] = (char)(i * 7 + 3);
  for (int r = 0; r < 200; r++) { memmove(buf + 1, buf, sizeof buf - 1); h = mix(h, (uint8_t)buf[r % sizeof buf]); }
  printf("checksum %016llx\n", (unsigned long long)h);
  return 0;
}
