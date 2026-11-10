// iRL: compile DXBC pixel shaders exactly as DXMT's runtime does (d3d11_shader.cpp,
// CreateVariantShader<ShaderVariantPixel> + GeneralShaderCompileTask), so the results can go
// straight into DXMT's on-device shader cache:
//   chain  SM50_SHADER_PSO_PIXEL_SHADER_DATA -> SM50_SHADER_COMMON_DATA{metal_version}
//   name   ps_<shader sha1 hex[0:8]>_<variant digest hex>
//   value  SM50GetCompiledBitcode bytes (what DXMT passes to update_cached_variant)
// Input (stdin), one shader per line:
//   <dxbc path>\t<function name>\t<sample_mask>\t<dual_source>\t<disable_depth>\t<unorm_mask>\t<out path>
// Prints "ok <out>" or "fail <dxbc>: <error>" per line.
#include "airconv_public.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  const int metal = argc > 1 ? atoi(argv[1]) : 320;
  std::string line;
  int ok = 0, fail = 0;
  while (std::getline(std::cin, line)) {
    std::istringstream ss(line);
    std::string path, name, out;
    unsigned long sample_mask = 0, unorm = 0;
    int dual = 0, depth = 0;
    std::getline(ss, path, '\t');
    std::getline(ss, name, '\t');
    ss >> sample_mask >> dual >> depth >> unorm;
    ss.ignore(1);
    std::getline(ss, out);
    std::ifstream f(path, std::ios::binary);
    std::vector<char> bc((std::istreambuf_iterator<char>(f)), {});
    sm50_shader_t shader = nullptr;
    sm50_error_t err = nullptr;
    if (bc.empty() || SM50Initialize(bc.data(), bc.size(), &shader, nullptr, &err)) {
      std::cout << "fail " << path << ": init " << (err ? SM50GetErrorMessageString(err) : "empty") << "\n";
      if (err) SM50FreeError(err);
      fail++;
      continue;
    }
    SM50_SHADER_COMMON_DATA common{};
    common.type = SM50_SHADER_COMMON;
    common.metal_version = (SM50_SHADER_METAL_VERSION)metal;
    common.next = nullptr;
    SM50_SHADER_PSO_PIXEL_SHADER_DATA data{};
    data.type = SM50_SHADER_PSO_PIXEL_SHADER;
    data.next = &common;
    data.sample_mask = (uint32_t)sample_mask;
    data.dual_source_blending = dual != 0;
    data.disable_depth_output = depth != 0;
    data.unorm_output_reg_mask = (uint32_t)unorm;
    sm50_bitcode_t result = nullptr;
    if (SM50Compile(shader, (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&data, name.c_str(), &result, &err)) {
      std::cout << "fail " << path << ": compile " << SM50GetErrorMessageString(err) << "\n";
      SM50FreeError(err);
      SM50Destroy(shader);
      fail++;
      continue;
    }
    SM50_COMPILED_BITCODE bits{};
    SM50GetCompiledBitcode(result, &bits);
    std::ofstream o(out, std::ios::binary);
    o.write(reinterpret_cast<const char *>(bits.Data), bits.Size);
    o.close();
    SM50DestroyBitcode(result);
    SM50Destroy(shader);
    std::cout << "ok " << out << "\n";
    ok++;
  }
  std::cerr << "precompiled " << ok << ", failed " << fail << "\n";
  return fail ? 2 : 0;
}
