# ASIC_Tools

[Chinese guide](README.zh-CN.md) | [Contributing and CI](CONTRIBUTING.md)

ASIC_Tools collects, develops and maintains tools and scripts for ASIC
development. It helps ASIC engineers debug designs, reduce repetitive work,
and improve code quality and readability.

## Pre-open-source / Production History

ASIC_Tools grew out of scripts developed and maintained by MetatronJeanne for
practical ASIC engineering work. Before open-sourcing, the author licensed these
scripts for use in a commercial ASIC project that has completed tape-out.

The public repository contains general-purpose tools and self-contained examples;
it does not include the company's design RTL or project-specific inputs. This
production history refers to the pre-open-source scripts. The public version
includes subsequent changes, including the Register Generator's transition from
in-place RTL injection to generated include files. Validation of the public
version is covered by the [regression checks](#regression-checks) and CI.

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

Generate module includes, macros, register interfaces, a C header and a Markdown address map:

```sh
perl tools/reggen/gen_reg_inc.pl --config examples/reggen/config.json
```

Outputs go into `build/reggen/`. The example configuration covers
two control instances, read-only status, W1C/W1S fields and a 48-bit register.
Addresses in the table and RTL are relative offsets. The configured base address
is used by the C header and documentation, not subtracted by the generated RTL.

RTL is never rewritten. Preview the output paths without publishing files:

```sh
perl tools/reggen/gen_reg_inc.pl --config examples/reggen/config.json --dry-run
```

To generate the files, omit `--dry-run`. Each module with non-reserved fields
gets `<MODULE>_reg_port.svh` and `<MODULE>_reg_logic.svh`, using the uppercase
table module name, not the wrapper filename. Includes default to the directory
of `--output`; `--include-dir` / JSON `include_dir` overrides that directory.
Reserved-only modules emit no includes; a table with no non-reserved fields is
rejected. Outputs have deterministic content and no timestamps or include guards,
so the same includes can be used in more than one wrapper in a compilation unit.

Configuration paths are relative to the JSON file; CLI paths are relative to
the current directory. CLI options take precedence. The `modules` object maps
each module to a base address. Unspecified bases are zero; no RTL mapping or
source search root is required. Files for modules removed from the table are not
automatically deleted; clean obsolete generated files from your build directory.

`--workdir` is a parent directory: each invocation creates its own child and
cleans up only that child. `--keep-temp` retains it. Generated files are staged
until all generation and validation finish, then replaced individually.
The complete set of replacements is not a cross-file atomic transaction.

### Project Integration

Configure the following settings for each design:

- `modules`: uppercase table module names and base addresses.
- `apb_interface`: bus signal prefix.
- `clock` / `--clock`: rising-edge clock, default `clk`.
- `reset_n` / `--reset-n`: asynchronous active-low reset, default `reset_n`.
- Input/output paths, including optional `include_dir`.

```systemverilog
`include "reg_inc.v"
module demo_regs (
    input logic clk,
    input logic reset_n,
    demo_apb_if.s apb
`include "DEMO_reg_port.svh"
);
    assign apb.pready = 1'b1;
    assign apb.pslverr = 1'b0;
`include "DEMO_reg_logic.svh"
endmodule
```

Add the macro/include directories to the compiler include path (for example,
`-Ibuild/reggen`) and compile the APB and generated register interface definitions
before the wrapper. Do not compile `.svh` fragments as standalone sources.
The port include supplies a leading comma on every declaration: place it after
at least one handwritten port with no trailing comma. The logic include supplies
complete `always_ff` blocks, not statements for insertion into an existing block.
The wrapper owns `pready`/`pslverr` and must not also drive generated registers or
`prdata`. A read-only module omits the write block.

Writes occur on `psel && penable && pwrite`. Reads are registered on
`psel && !pwrite` (including the setup phase), retaining the example's timing;
`prdata` holds when idle and clears on reset or unmapped reads. Unused read bits
are zero. The bus is 32 bits, uses module-relative addresses, and this logic
does not gate transfers on `pready` or implement wait-state control.

Migration: remove all four old marker pairs and their generated contents,
replace the entire old reset/write/read blocks with the logic include, and move
the port include to the end of the handwritten port list. Preserve any custom
logic deliberately, without introducing multiple drivers. `--inject` and
`--no-skip-inject` now fail with migration guidance. `--skip-inject` is a deprecated
no-op; `rtlroot`, `rtl_file` (including module mappings), and `marker_prefix` are
accepted only for compatibility and warn that they are ignored. Run `--help` for
the full option list. Existing macro, interface, C header and map formats remain.

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
