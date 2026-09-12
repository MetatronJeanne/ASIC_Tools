# ASIC_Tools Changelog

## Unreleased

### License

- Distribute ASIC_Tools under the MIT License.
- Add copyright and SPDX notices to tools, test runners and RTL examples.

### Tools

- Add a Perl register generator for RTL macros, interfaces, C headers and address maps.
- Add TopStitcher for top-level RTL generation and connectivity checks.
- Add self-contained examples and standalone regression runners.
- Organize tool entry points under `tools/reggen/` and `tools/topstitcher/`.

### Register Generator

- Add JSON configuration, help, explicit injection and read-only preview.
- Replace project-specific defaults with configurable mappings, bus names and markers.
- Use private temporary directories and stage output before replacing destination files.
- Reject missing, duplicate and misordered markers and ambiguous RTL targets.
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

- Add English and Chinese usage guides and contribution instructions for
  ASIC_Tools, covering configuration, supported syntax and testing.
- Define Linux/Windows generator CI and a Linux HDL example job with pinned
  action commits and a dated HDL tool bundle.
- Add seeded register-field checks across C macros, RTL offsets and the address
  map, plus inout width, unchecked-interface, duplicate-module and filelist-order
  regressions.

### Migration

RTL injection is disabled by default and requires `--inject`. Integration
settings include module mappings, paths, APB names and marker prefixes.
See [the usage guide](README.md) for configuration details.
