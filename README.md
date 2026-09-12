# ASIC_Tools

[Chinese guide](README.zh-CN.md) | [Contributing and CI](CONTRIBUTING.md)

ASIC_Tools collects, develops and maintains tools and scripts for ASIC
development. It helps ASIC engineers debug designs, reduce repetitive work,
and improve code quality and readability.

## Tools

| Tool | Purpose |
| --- | --- |
| [Register Generator](tools/reggen/gen_reg_inc.pl) | Generate register RTL macros, interfaces, C headers and address documentation from a register table. |
| [TopStitcher](tools/topstitcher/stitch_top.py) | Generate top-level RTL from a connection specification and check connectivity and widths within a restricted SystemVerilog subset. |

## Repository Layout

```text
tools/
  reggen/
    gen_reg_inc.pl
  topstitcher/
    stitch_top.py
examples/
  reggen/
  topstitch/
tests/
```

Each tool has a directory under `tools/`, named for its purpose rather than its
implementation language. Tool-specific helpers belong alongside the entry point.
Self-contained examples live under `examples/`; regression runners live under
`tests/`. Generated outputs belong in `build/` and are not tracked.

## Requirements

- Perl 5.14 or newer with its core modules, including JSON::PP and Math::BigInt.
- Python 3.9 or newer for TopStitcher and the regression runners.
- slang and Verilator, plus the Verilator C++ build toolchain, for HDL examples.

The examples are self-contained and use open-source HDL tools.
Commands below run from the repository root. Use `python3` instead of `python`
when that is the Python 3 executable on your system.

## Register Generator

Generate macros, register interfaces, a C header and a Markdown address map:

```sh
perl tools/reggen/gen_reg_inc.pl --config examples/reggen/config.json
```

Outputs go into `build/reggen/`. The example configuration covers
two control instances, read-only status, W1C/W1S fields and a 48-bit register.
Addresses in the table and RTL are relative offsets. The configured base address
is used by the C header and documentation, not subtracted by the generated RTL.

RTL injection is disabled by default. Preview an injection:

```sh
perl tools/reggen/gen_reg_inc.pl --config examples/reggen/config.json --inject --dry-run
```

To apply it, omit `--dry-run`. This rewrites the marked regions of
`examples/reggen/rtl/demo_regs.sv`. The regression runner below runs the complete
example in a temporary copy without modifying the repository template.

Configuration paths are relative to the JSON file; CLI paths are relative to
the current directory. CLI options take precedence. The `modules` object maps
each module to an RTL basename and a base address. Unspecified bases are zero.
Injection requires an explicit RTL root and exactly one matching file per module.

The default marker pairs are `//reggen_port_on/off`,
`//reggen_default_on/off`, `//reggen_write_on/off` and `//reggen_read_on/off`.
Each marker must occupy its own line; all four non-nested pairs are required.
Missing, duplicate or misordered markers fail before replacing any output.

`--workdir` is a parent directory: each invocation creates its own child and
cleans up only that child. `--keep-temp` retains it. Generated files are staged
until generation and injection validation finish, then replaced individually.
The complete set of replacements is not a cross-file atomic transaction.

### Project Integration

Configure the following settings for each design:

- `modules`: module names, RTL basenames and base addresses.
- `apb_interface`: bus signal prefix.
- `marker_prefix`: the prefix before `port`, `default`, `write` and `read`.
- Input/output paths, `rtlroot`, and `--inject` when modification is intended.

For example, a project using `//custom_regport_on` sets
`"marker_prefix": "custom_reg"`. `--skip-inject` disables injection, and
`--no-skip-inject` enables it. Run `--help` for the full option list.

W1C/W1S implement software updates only. Hardware event updates, their priority
relative to software writes, byte strobes and multiword atomicity require
separate integration logic.

## TopStitcher

```sh
python tools/topstitcher/stitch_top.py --spec examples/topstitch/connect.txt --output-core build/demo_top.sv --report build/top_audit.txt --strict
```

The example sets a module parameter to 16 and exports its ports. It exercises
shared ANSI declarations and concrete top-level ranges. `--strict` also fails
on audit warnings. Errors return a nonzero status and preserve existing RTL.
Audit reports are refreshed when the connectivity audit runs.

Only the specified filelists are parsed when provided. Filelist entries are
plain RTL paths, relative to the filelist; compiler switches and nested filelists
are rejected. Without a filelist, `--search-dir` is scanned deterministically.
Duplicate module names are errors. Parsing failures return an error; they may
occur before an audit report is written.

Supported: scalar and one-dimensional ANSI ports, shared port declarations,
signed/unsigned logic, bounded integer parameter arithmetic and whole-net checks.
Input slices and concatenations have limited width checks. Output/inout
expressions are rejected rather than misclassified as receivers. Interface
direction checking and unresolved expression widths are reported as unchecked;
strict mode does not pass them silently.

This is not a full SystemVerilog elaborator. It does not replace compiler lint,
simulation, timing, CDC, electrical inout analysis or physical-design signoff.
Keep unsupported packages, macros and types out of its input headers, or use a
complete compiler frontend for those designs.

## Regression Checks

```sh
python -B tests/test_tools.py
python -B tests/run_examples.py
```

The first command exercises generation, failure handling and parsing. The second
copies the examples into a temporary directory, generates both
designs, checks them with slang and runs their self-checking Verilator simulations.
It leaves the repository's example templates unchanged.

Tool locations can be selected with `PERL`, `SLANG`, `VERILATOR` and optional
`VERILATOR_RUN` environment variables, or with the equivalent lower-case
hyphenated options of `tests/run_examples.py`. Windows users can point these
options at their installed launcher scripts.

The [CI workflow](.github/workflows/ci.yml) defines Linux/Windows generator jobs
and a Linux HDL job. See the contribution guide for the version matrix and
dependency pins.

## License

ASIC_Tools is licensed under the [MIT License](LICENSE).

Copyright (c) 2026 MetatronJeanne.
