# Copyright (c) 2026 MetatronJeanne
# SPDX-License-Identifier: MIT
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/topstitcher"))
import stitch_top as stitch

PERL = os.environ.get("PERL", shutil.which("perl") or "perl")
HEADER = "| Module | Offset | BitRange | RegName | Reset | Access | Interface | Owner | Description |\n"


class WorkspaceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asic-tools-test-")
        self.work = Path(self.temp.name).resolve()
        self.assertEqual(self.work.parent, Path(tempfile.gettempdir()).resolve())

    def tearDown(self):
        self.temp.cleanup()

    def run_command(self, args):
        return subprocess.run(args, cwd=self.work, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=30)


class RegisterTests(WorkspaceTest):
    def setUp(self):
        super().setUp()
        self.rtl = self.work / "rtl"
        self.rtl.mkdir()
        self.source = self.rtl / "demo_regs.sv"
        self.original = "module demo_regs;\n" + "".join(
            f"//reggen_{section}_on\n// old {section}\n//reggen_{section}_off\n"
            for section in ("port", "default", "write", "read")) + "endmodule\n"
        self.source.write_text(self.original, encoding="utf-8")
        self.table = self.work / "registers.txt"
        self.table.write_text(HEADER + "| DEMO | 0x0 | [7:0] | cfg | 0x12 | RW | - | - | demo |\n", encoding="utf-8")
        self.config = self.work / "config.json"
        self.config.write_text(json.dumps({
            "input": "registers.txt", "output": "out/reg_inc.v",
            "interface_output": "out/register_if.sv", "sim_header": "out/regs.h",
            "map_output": "out/map.md", "rtlroot": "rtl", "workdir": "scratch",
            "apb_interface": "bus", "marker_prefix": "reggen_",
            "modules": {"DEMO": {"rtl_file": "demo_regs.sv", "base_addr": "0x2000"}}
        }), encoding="utf-8")

    def generate(self, *args):
        return self.run_command([PERL, str(ROOT / "tools/reggen/gen_reg_inc.pl"),
                                 "--config", str(self.config), *args])

    def test_config_and_generation_only_default(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.source.read_text(), self.original)
        self.assertIn("bus.pwdata", (self.work / "out/reg_inc.v").read_text())
        self.assertIn("#define DEMO_BASE_ADDR 0x2000", (self.work / "out/regs.h").read_text())
        self.assertTrue((self.work / "out/register_if.sv").exists())

    def test_help_and_no_arguments_are_safe(self):
        script = str(ROOT / "tools/reggen/gen_reg_inc.pl")
        self.assertEqual(self.run_command([PERL, script, "--help"]).returncode, 0)
        self.assertNotEqual(self.run_command([PERL, script]).returncode, 0)
        self.assertFalse((self.work / "build").exists())

    def test_invalid_input_preserves_outputs_and_work_parent(self):
        (self.work / "out").mkdir()
        (self.work / "out/reg_inc.v").write_text("previous valid output")
        (self.work / "scratch").mkdir()
        sentinel = self.work / "scratch/user.txt"
        sentinel.write_text("keep")
        self.table.write_text(HEADER + "| DEMO | 0 | [7:0] | cfg | 0 | TYPO | - | - | bad |\n")
        self.assertNotEqual(self.generate().returncode, 0)
        self.assertEqual((self.work / "out/reg_inc.v").read_text(), "previous valid output")
        self.assertEqual(sentinel.read_text(), "keep")

    def test_injection_is_idempotent_and_preview_is_read_only(self):
        preview = self.generate("--inject", "--dry-run")
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn("PREVIEW", preview.stdout)
        self.assertEqual(self.source.read_text(), self.original)
        self.assertFalse((self.work / "out/reg_inc.v").exists())
        first = self.generate("--inject")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        once = self.source.read_bytes()
        self.assertIn(b"bus.pwdata", once)
        self.assertEqual(self.generate("--inject").returncode, 0)
        self.assertEqual(self.source.read_bytes(), once)

    def test_missing_or_duplicate_markers_preserve_rtl_and_outputs(self):
        for body in (self.original.replace("//reggen_read_off", "//missing"),
                     self.original + "//reggen_read_on\n"):
            with self.subTest(body=body):
                self.source.write_text(body)
                self.assertNotEqual(self.generate("--inject").returncode, 0)
                self.assertEqual(self.source.read_text(), body)
                self.assertFalse((self.work / "out/reg_inc.v").exists())

    def test_ambiguous_rtl_target_is_rejected(self):
        (self.rtl / "other").mkdir()
        (self.rtl / "other/demo_regs.sv").write_text(self.original)
        result = self.generate("--inject")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ambiguous", result.stderr)
        self.assertEqual(self.source.read_text(), self.original)

    def test_legacy_marker_and_bus_names_are_explicit_options(self):
        self.source.write_text(self.original.replace("reggen_", "legacy_reg"))
        result = self.generate("--inject", "--marker-prefix", "legacy_reg", "--apb-interface", "old_bus")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("old_bus.pwdata", self.source.read_text())

    def test_invalid_reset_and_module_path_are_rejected(self):
        for row in ("| DEMO | 0 | [3:0] | cfg | 0x10 | RW | - | - | bad |\n",
                    "| ../escape | 0 | [3:0] | cfg | 0 | RW | - | - | bad |\n"):
            self.table.write_text(HEADER + row)
            self.assertNotEqual(self.generate().returncode, 0)

    def test_overlapping_fields_are_rejected(self):
        self.table.write_text(HEADER + "| DEMO | 0 | [7:0] | a | 0 | RW | - | - | |\n"
                              "| DEMO | 0 | [7:4] | b | 0 | RW | - | - | |\n")
        self.assertNotEqual(self.generate().returncode, 0)

    def test_output_cannot_overwrite_input(self):
        original = self.table.read_bytes()
        self.assertNotEqual(self.generate("--output", str(self.table)).returncode, 0)
        self.assertEqual(self.table.read_bytes(), original)

    def test_unknown_config_key_is_rejected(self):
        config = json.loads(self.config.read_text())
        config["apb_interfase"] = "typo"
        self.config.write_text(json.dumps(config))
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown config key", result.stderr)
        self.assertFalse((self.work / "out").exists())

    def test_nested_markers_are_rejected(self):
        body = self.original.replace("//reggen_port_off", "//reggen_default_on").replace(
            "//reggen_default_on\n// old default", "//reggen_port_off\n// old default")
        self.source.write_text(body)
        self.assertNotEqual(self.generate("--inject").returncode, 0)
        self.assertEqual(self.source.read_text(), body)

    def test_wide_resets_and_repeated_instance_macros(self):
        self.table.write_text(HEADER +
            "| DEMO | 0x0 | [47:0] | value | 0x123456789abc | RW | demo_if:a | - | first |\n"
            "| DEMO | 0x8 | [47:0] | value | 0xabcde1234567 | RW | demo_if:b | - | second |\n")
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        header = (self.work / "out/regs.h").read_text()
        self.assertIn("DEMO_A_VALUE_47_32_DEFAULT 0x1234", header)
        self.assertIn("DEMO_B_VALUE_47_32_DEFAULT 0xabcd", header)
        outputs = {path.name: path.read_bytes() for path in (self.work / "out").iterdir()}
        self.assertEqual(self.generate().returncode, 0)
        self.assertEqual(outputs, {path.name: path.read_bytes() for path in (self.work / "out").iterdir()})

    def test_seeded_fields_match_c_header_rtl_offsets_and_documentation(self):
        rng = random.Random(20260912)
        fields = []
        for index in range(32):
            width = rng.randint(1, 8)
            fields.append((f"field_{index}", (index // 4) * 4, (index % 4) * 8,
                           width, rng.randrange(1 << width)))
        self.table.write_text(HEADER + "".join(
            f"| DEMO | {offset} | [{lsb + width - 1}:{lsb}] | {name} | {reset} | RW | - | - | example |\n"
            for name, offset, lsb, width, reset in fields))
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        header = dict(re.findall(r"^#define (\w+)\s+(0x[0-9a-fA-F]+|\d+)\s*$",
                                 (self.work / "out/regs.h").read_text(), re.MULTILINE))
        rtl_offsets = {int(value, 16) for value in re.findall(
            r"`define DEMO_REG_\w+_OFFSET 'h([0-9a-f]+)", (self.work / "out/reg_inc.v").read_text())}
        rows = [list(map(str.strip, line.strip('|').split('|')))
                for line in (self.work / "out/map.md").read_text().splitlines() if line.startswith('|')]
        documented = {row[3]: row for row in rows if len(row) == 8 and row[3].startswith('field_')}
        self.assertEqual(rtl_offsets, {field[1] for field in fields})
        self.assertEqual(len(documented), len(fields))
        for name, offset, lsb, width, reset in fields:
            prefix = "DEMO_" + name.upper()
            for suffix, expected in (("OFFSET", offset), ("SHIFT", lsb),
                                     ("MASK", (1 << width) - 1), ("DEFAULT", reset)):
                self.assertEqual(int(header[prefix + "_" + suffix], 0), expected)
            row = documented[name]
            self.assertEqual(int(row[0], 16), 0x2000 + offset)
            self.assertEqual(int(row[1], 16), offset)
            self.assertEqual(row[2], f"[{lsb}]" if width == 1 else f"[{lsb + width - 1}:{lsb}]")
            self.assertEqual(int(row[5], 16), reset)


class StitchTests(WorkspaceTest):
    def parse_ports(self, text):
        module = stitch.ModuleInfo("leaf")
        stitch.RtlParser._parse_ansi_ports(text, module)
        return module

    def test_inherited_width_and_signed_ports(self):
        module = self.parse_ports("input logic [7:0] a, b, output logic signed [7:0] y")
        self.assertEqual({n: p.get_bitwidth() for n, p in module.ports.items()}, {"a": 8, "b": 8, "y": 8})
        self.assertIn("signed", module.ports["y"].get_decl_str())

    def test_new_direction_resets_inherited_width(self):
        module = self.parse_ports("input logic [7:0] a, output b")
        self.assertEqual(module.ports["b"].get_bitwidth(), 1)

    def test_unsupported_port_is_not_silently_lost(self):
        with self.assertRaises(ValueError):
            self.parse_ports("input logic [7:0] data [2]")

    def test_parameter_expressions_preserve_precedence(self):
        self.assertEqual(stitch.safe_eval_expr("W*2-1", {"W": "A+1", "A": "3"}), 7)
        self.assertIsNone(stitch.safe_eval_expr("W", {"W": "W+1"}))

    def test_unbalanced_headers_are_rejected(self):
        for text in ("a, {b,c", "a, b]"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                stitch.split_balanced(text)
        with self.assertRaises(ValueError):
            stitch.extract_balanced_bracket("(input a")

    def test_parameterized_auto_top_is_self_contained(self):
        module = self.parse_ports("input logic [W-1:0] data")
        module.add_param("W", "8")
        spec = stitch.ConnectSpec()
        spec.instances["u"] = stitch.InstanceConfig("u", "leaf")
        spec.instances["u"].param_overrides["W"] = "16"
        spec.auto_top_insts.add("u")
        engine = stitch.TopStitchEngine(spec, {"leaf": module})
        rtl = engine.run_stitch()
        self.assertIn("[15:0]", rtl)
        self.assertNotIn("[W-1:0]", rtl)
        self.assertEqual(engine.audit_errors, [])

    def run_stitch(self, spec_text, rtl_text="module leaf(input logic a, output logic y); assign y=a; endmodule\n", *args):
        (self.work / "rtl").mkdir(exist_ok=True)
        (self.work / "rtl/leaf.sv").write_text(rtl_text)
        (self.work / "connect.txt").write_text(spec_text)
        return self.run_command([sys.executable, "-B", str(ROOT / "tools/topstitcher/stitch_top.py"),
            "--spec", "connect.txt", "--search-dir", "rtl", "--output-core", "out.sv",
            "--report", "audit.txt", *args])

    def test_missing_module_fails_without_overwriting_output(self):
        (self.work / "out.sv").write_text("previous valid output")
        result = self.run_stitch("[INSTANCES]\nu = missing\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.work / "out.sv").read_text(), "previous valid output")

    def test_unknown_connection_port_is_rejected(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf\n[CONNECTIONS]\nu.typo = 1'b0\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("typo", (self.work / "audit.txt").read_text())

    def test_strict_width_mismatch_fails(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf\n[TOP_PORTS]\ninput [3:0] data\n"
                                "[CONNECTIONS]\nu.a = data\nu.y = OPEN\n",
                                "module leaf(input [7:0] a, output y); endmodule\n", "--strict")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "out.sv").exists())

    def test_explicit_wire_width_is_audited(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf\n[WIRES]\nwire [3:0] data\n"
                                "[CONNECTIONS]\nu.a = 8'h00\nu.y = data\n",
                                "module leaf(input [7:0] a, output [7:0] y); endmodule\n", "--strict")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Bit-Width Mismatch", (self.work / "audit.txt").read_text())

    def test_multi_driver_and_undriven_nets_fail_strict(self):
        for connections in ("u.a = 1'b0\nu.y = data\nv.a = 1'b0\nv.y = data\n",
                            "u.a = missing_driver\nu.y = OPEN\nv.a = 1'b0\nv.y = OPEN\n"):
            with self.subTest(connections=connections):
                result = self.run_stitch("[INSTANCES]\nu = leaf\nv = leaf\n[CONNECTIONS]\n" +
                                        connections, "module leaf(input a, output y); endmodule\n", "--strict")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.work / "out.sv").exists())

    def test_output_slices_are_rejected_not_treated_as_receivers(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf\n[TOP_PORTS]\noutput [1:0] data\n"
                                "[CONNECTIONS]\nu.a = 1'b0\nu.y = data[0]\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Output/inout expression", (self.work / "audit.txt").read_text())

    def test_input_slices_and_concatenation(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf\n[TOP_PORTS]\ninput [7:0] data\n"
                                "output [7:0] result\n[CONNECTIONS]\nu.a = {data[3:0], data[7:4]}\n"
                                "u.y = result\n", "module leaf(input [7:0] a, output [7:0] y); endmodule\n", "--strict")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unknown_parameter_is_rejected(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf #(TYPO=16)\n[AUTO_CONNECT]\nAUTO_TOP u\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown parameter", (self.work / "audit.txt").read_text())

    def test_parameter_override_dependencies_do_not_leak_into_top(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf #(W=A+1)\n[AUTO_CONNECT]\nAUTO_TOP u\n",
                                "module leaf #(parameter A=7, W=8)(input [W-1:0] a); endmodule\n", "--strict")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(".W(8)", (self.work / "out.sv").read_text())

    def test_unresolved_parameter_override_is_rejected_even_without_ports(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf #(W=UNKNOWN)\n",
                                "module leaf #(parameter W=8)(); endmodule\n", "--strict")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "out.sv").exists())

    def test_normal_generation_and_filelist_exclude_unrelated_rtl(self):
        (self.work / "rtl").mkdir()
        (self.work / "rtl/unrelated.sv").write_text("module bad(input logic data [2]); endmodule")
        (self.work / "files.f").write_text("rtl/leaf.sv\n")
        result = self.run_stitch("[GLOBAL]\nCORE_MODULE = demo_top\n[INSTANCES]\nu = leaf\n[AUTO_CONNECT]\nAUTO_TOP u\n",
                                "module leaf(input [7:0] a, b, output [7:0] y); assign y=a^b; endmodule\n", "--filelist", "files.f", "--strict")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("module demo_top", (self.work / "out.sv").read_text())

    def test_inout_whole_net_width_is_checked(self):
        for width, expected in ((8, 0), (4, 1)):
            result = self.run_stitch("[INSTANCES]\nu = leaf\n[TOP_PORTS]\n"
                                    f"inout [{width - 1}:0] pad\n[CONNECTIONS]\nu.pad = pad\n",
                                    "module leaf(inout wire [7:0] pad); endmodule\n", "--strict")
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_interface_direction_is_not_silently_approved(self):
        result = self.run_stitch("[INSTANCES]\nu = leaf\n[TOP_PORTS]\nbus_if.slave bus\n"
                                "[CONNECTIONS]\nu.bus = bus\n",
                                "module leaf(bus_if.slave bus); endmodule\n", "--strict")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not audited", (self.work / "audit.txt").read_text())
        self.assertFalse((self.work / "out.sv").exists())

    def test_duplicate_module_files_are_rejected(self):
        (self.work / "rtl").mkdir()
        (self.work / "rtl/duplicate.sv").write_text("module leaf(); endmodule\n")
        result = self.run_stitch("[INSTANCES]\nu = leaf\n[AUTO_CONNECT]\nAUTO_TOP u\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate module", result.stderr)

    def test_filelist_order_does_not_change_output(self):
        (self.work / "rtl").mkdir()
        (self.work / "rtl/unused.sv").write_text("module unused(input logic a); endmodule\n")
        outputs = []
        for order in (("leaf", "unused"), ("unused", "leaf")):
            (self.work / "files.f").write_text("".join(f"rtl/{name}.sv\n" for name in order))
            result = self.run_stitch("[INSTANCES]\nu = leaf\n[AUTO_CONNECT]\nAUTO_TOP u\n",
                                    "module leaf(input a, output y); assign y=a; endmodule\n",
                                    "--filelist", "files.f", "--strict")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            outputs.append((self.work / "out.sv").read_bytes())
        self.assertEqual(outputs[0], outputs[1])


if __name__ == "__main__":
    unittest.main()
