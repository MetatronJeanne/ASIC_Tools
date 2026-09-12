# Contributing to ASIC_Tools

ASIC_Tools collects, develops and maintains tools and scripts that help ASIC
engineers debug designs, reduce repetitive work, and improve code quality and
readability.

## Scope

Contributions can improve existing tools or add utilities for ASIC development.
The current tools are `tools/reggen/gen_reg_inc.pl` and
`tools/topstitcher/stitch_top.py`.
Read [the English guide](README.md) or [the Chinese guide](README.zh-CN.md)
before changing a command-line contract or supported syntax.

Source code, fixtures and logs submitted with a contribution must be suitable
for public distribution. Use self-contained minimal examples without proprietary
RTL, register maps, cell libraries or confidential project information.

New tools should include a documented purpose, command-line usage, dependencies,
examples and regression tests. Keep examples independent of commercial IP.

Place each tool in its own `tools/<tool-name>/` directory, using a lowercase
functional name rather than a language name. Keep its entry point and private
helpers together. Put self-contained examples in a dedicated subdirectory of
`examples/`, and integrate regression checks through `tests/`. Keep generated
outputs under `build/` rather than in the tool's source directory.

## Changes

1. Describe the observed behavior and the expected result with a minimal example.
2. Add a failing regression test before fixing a bug where practical.
3. Keep changes limited to one behavior. Preserve deterministic generation,
   explicit injection, and existing outputs on validation failure.
4. Update both guides and `CHANGELOG.md` when the CLI, configuration, generated
   interface or supported language subset changes.
5. Run the checks below and record the actual tool versions and results.

TopStitcher changes should define the supported syntax and report unsupported
constructs explicitly. Connectivity checks cover whole nets rather than
SystemVerilog elaboration or electrical signoff.

## Local Checks

From the repository root:

```sh
python -B tests/test_tools.py
python -B tests/run_examples.py
```

The first command needs Python and Perl. The second also requires slang,
Verilator and its C++ build toolchain; it generates and simulates temporary
copies of the examples.
Use `PERL`, `SLANG`, `VERILATOR` and optional `VERILATOR_RUN` for custom tool
locations. The example runner also accepts corresponding command-line options.

Changes to generated register logic require HDL behavioral tests in addition to
parser and generator tests. Include any skipped checks in the test results.

## Continuous Integration

The [workflow](.github/workflows/ci.yml) defines generator regressions on Ubuntu
24.04 and Windows 2022 with Python 3.9 and 3.13, and Perl 5.40. Python 3.9 is a
compatibility test, not the recommended interpreter for new installations.
The Linux HDL job runs slang and Verilator from OSS CAD Suite `2026-09-11`.
Windows HDL simulation requires a local toolchain configured through the example
runner's tool-location options.

Action dependencies use full commit hashes, and the HDL bundle uses a dated
release. Python/Perl minor versions and hosted runner images still receive patch
updates. Record tool versions in test logs when updating dependencies.
Dependency configuration follows
the upstream [Perl action](https://github.com/shogo82148/actions-setup-perl) and
[OSS CAD Suite action](https://github.com/YosysHQ/setup-oss-cad-suite) documentation.

The workflow uses read-only repository permissions, does not retain checkout
credentials and has no deployment, publishing or artifact-upload step.
All generator jobs and the HDL job should pass before merging.

## License

ASIC_Tools is distributed under the [MIT License](LICENSE). Contributions must
be compatible with these terms and retain applicable copyright notices.
