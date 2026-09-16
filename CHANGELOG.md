# ASIC_Tools Changelog

## v2.13 - First Public Release (2026-09-16)

First tagged public release of ASIC_Tools, including Register Generator 2.13
and TopStitcher.

### License

- Distribute ASIC_Tools under the MIT License.
- Add copyright and SPDX notices to tools, test runners and RTL examples.

### Tools

- Add a Perl register generator for RTL macros, interfaces, C headers and address maps.
- Add TopStitcher for top-level RTL generation and connectivity checks.
- Add self-contained examples and standalone regression runners.
- Organize tool entry points under `tools/reggen/` and `tools/topstitcher/`.

### Register Generator

- Add JSON configuration, help and read-only preview.
- Replace marker-based RTL injection with stable per-module port and logic `.svh` files.
- Add `include_dir`, `clock` and `reset_n` configuration and CLI overrides.
- Preserve macro, interface, C header and map generation, including registered APB reads.
- Use private temporary directories and stage output before replacing destination files.
- Never search for or rewrite handwritten RTL; migrate the example to two includes.
- Fix 48-bit reset slicing and repeated-instance wide-register macro collisions.
- Validate module identifiers and reset bounds; accept a UTF-8 BOM.
- Remove timestamps and source-machine paths from generated interfaces/headers.

### TopStitcher

- Preserve inherited port widths and signedness; reject unsupported port declarations.
- Resolve parameter dependencies and preserve arithmetic grouping.
- Generate self-contained top and internal net ranges after parameter overrides.
- Fail on unknown connections, missing modules and duplicate module definitions.
- Add strict warning handling and preserve prior RTL on failed audits.
- Honor filelists without also scanning unrelated sources.
- Document the supported SystemVerilog subset and connectivity checks.

### Documentation and Checks

- Document the pre-open-source scripts' use in a commercial ASIC project that
  completed tape-out, separately from validation of the public version.
- Add English and Chinese usage guides and contribution instructions for
  ASIC_Tools, covering configuration, supported syntax and testing.
- Define Linux/Windows generator CI and a Linux HDL example job with pinned
  action commits and a dated HDL tool bundle.
- Add seeded register-field checks across C macros, RTL offsets and the address
  map, plus inout width, unchecked-interface, duplicate-module and filelist-order
  regressions.

### Migration

RTL injection has been removed. Replace the four marker regions and their old
process blocks with `<MODULE>_reg_port.svh` and `<MODULE>_reg_logic.svh` includes.
`--inject` / `--no-skip-inject` report a migration error. `--skip-inject`,
`rtlroot`, `rtl_file` and `marker_prefix` are deprecated compatibility options.
Integration settings include base addresses, paths, APB, clock and reset names.
See [the usage guide](README.md) for configuration details.
