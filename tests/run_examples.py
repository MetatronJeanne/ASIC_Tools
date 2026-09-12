# Copyright (c) 2026 MetatronJeanne
# SPDX-License-Identifier: MIT
"""Generate and simulate the examples in a temporary copy."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--perl', default=os.environ.get('PERL', 'perl'))
    parser.add_argument('--slang', default=os.environ.get('SLANG', 'slang'))
    parser.add_argument('--verilator', default=os.environ.get('VERILATOR', 'verilator'))
    parser.add_argument('--verilator-run', default=os.environ.get('VERILATOR_RUN'))
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix='asic-examples-') as directory:
        work = Path(directory).resolve()
        if work.parent != Path(tempfile.gettempdir()).resolve():
            raise RuntimeError('Unexpected temporary workspace')
        shutil.copytree(ROOT / 'examples', work / 'examples')
        environment = dict(os.environ, TMPDIR=work.as_posix(), TMP=work.as_posix(), TEMP=work.as_posix())

        def run(command, timeout=180):
            result = subprocess.run(command, cwd=work, capture_output=True, text=True,
                                    encoding='utf-8', errors='replace', timeout=timeout, env=environment)
            if result.returncode:
                raise RuntimeError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
            return result.stdout + result.stderr

        run([args.perl, str(ROOT / 'tools/reggen/gen_reg_inc.pl'),
             '--config', 'examples/reggen/config.json', '--inject'])
        run([sys.executable, '-B', str(ROOT / 'tools/topstitcher/stitch_top.py'),
             '--spec', 'examples/topstitch/connect.txt', '--output-core', 'build/demo_top.sv',
             '--report', 'build/top_audit.txt', '--strict'])
        examples = [
            ('reg', 'demo_regs_tb', 'REGGEN_EXAMPLE_PASS', ['-Ibuild/reggen',
             'examples/reggen/rtl/demo_apb_if.sv', 'build/reggen/register_if.sv',
             'examples/reggen/rtl/demo_regs.sv', 'examples/reggen/demo_regs_tb.sv']),
            ('top', 'demo_top_tb', 'TOPSTITCH_EXAMPLE_PASS', [
             'examples/topstitch/rtl/data_pair.sv', 'build/demo_top.sv',
             'examples/topstitch/demo_top_tb.sv'])
        ]
        for name, top, expected, files in examples:
            run([args.slang, '--timescale', '1ns/1ps', '--top', top, *files])
            run([args.verilator, '--binary', '--timing', '-Wno-fatal', '--top-module', top,
                 '--Mdir', f'obj_{name}', '-o', f'sim_{name}', *files], timeout=300)
            executable = work / f'obj_{name}/sim_{name}'
            if not executable.exists():
                executable = executable.with_suffix('.exe')
            command = ([args.verilator_run] if args.verilator_run else []) + [str(executable)]
            output = run(command)
            if expected not in output:
                raise RuntimeError(f'Missing success marker: {output}')
            print(f'{top}: slang elaboration and Verilator simulation passed', flush=True)


if __name__ == '__main__':
    main()
