#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (c) 2026 MetatronJeanne
# SPDX-License-Identifier: MIT
"""
================================================================================
Auto-Stitch: Top-Level RTL Auto-Stitching Tool (restricted ANSI SV subset)
Zero external dependencies (Python 3 standard library only)

Supports scalar/one-dimensional ANSI ports, integer parameter overrides,
input slices/concatenations and conservative whole-net connectivity checks.
Unsupported ports fail; unchecked expressions/interfaces produce diagnostics.
This is not a complete SystemVerilog elaborator or a pad-ring signoff tool.
================================================================================
"""

import os
import sys
import re
import argparse
import ast
import operator
import tempfile
from collections import OrderedDict
from pathlib import Path


def extract_balanced_bracket(text: str, start_char: str = '(', end_char: str = ')') -> tuple:
    """
    Finds the first start_char and extracts the substring until the matching end_char.
    Returns (inside_content, end_index) or (None, -1) if not found.
    """
    start_idx = text.find(start_char)
    if start_idx == -1:
        return None, -1

    depth = 0
    for idx in range(start_idx, len(text)):
        if text[idx] == start_char:
            depth += 1
        elif text[idx] == end_char:
            depth -= 1
            if depth == 0:
                return text[start_idx + 1:idx], idx
    raise ValueError("Unbalanced parameter or port declaration")


def split_balanced(text: str, delim: str = ',', open_chars: str = '([{', close_chars: str = ')]}') -> list:
    """Splits a string by delim, ignoring delimiters inside any bracket/paren/brace."""
    match_map = {o: c for o, c in zip(open_chars, close_chars)}
    close_set = set(close_chars)
    stack = []
    tokens = []
    cur = []

    for char in text:
        if char in match_map:
            stack.append(match_map[char])
            cur.append(char)
        elif char in close_set:
            if stack and stack[-1] == char:
                stack.pop()
            else:
                raise ValueError("Mismatched brackets")
            cur.append(char)
        elif char == delim and not stack:
            tokens.append("".join(cur).strip())
            cur = []
        else:
            cur.append(char)
    if stack:
        raise ValueError("Unbalanced brackets")
    if cur:
        tokens.append("".join(cur).strip())
    return [t for t in tokens if t]


def safe_eval_expr(expr_str: str, param_dict: dict = None) -> int:
    """Evaluate a bounded integer subset; return None for unresolved SV syntax."""
    if expr_str is None:
        return None
    params = param_dict or {}
    binary = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
              ast.BitAnd: operator.and_, ast.BitOr: operator.or_, ast.BitXor: operator.xor}
    unary = {ast.UAdd: operator.pos, ast.USub: operator.neg, ast.Invert: operator.invert}

    def evaluate(expr, active):
        if len(active) > 32 or len(str(expr)) > 4096:
            raise ValueError("Expression too complex")
        text = str(expr).strip()
        text = re.sub(r"(\d+)'([bBoOdDhH])([0-9a-fA-F_]+)",
                      lambda m: str(int(m[3].replace('_', ''), {'b': 2, 'o': 8, 'd': 10, 'h': 16}[m[2].lower()])), text)
        tree = ast.parse(text, mode='eval')
        if sum(1 for _ in ast.walk(tree)) > 256:
            raise ValueError("Expression too complex")

        def visit(node):
            if isinstance(node, ast.Constant) and type(node.value) is int:
                value = node.value
            elif isinstance(node, ast.Name) and node.id in params and node.id not in active:
                value = evaluate(params[node.id], active | {node.id})
            elif isinstance(node, ast.UnaryOp) and type(node.op) in unary:
                value = unary[type(node.op)](visit(node.operand))
            elif isinstance(node, ast.BinOp):
                left, right = visit(node.left), visit(node.right)
                op = type(node.op)
                if op in binary:
                    value = binary[op](left, right)
                elif op in (ast.LShift, ast.RShift) and 0 <= right <= 4096:
                    value = left << right if op is ast.LShift else left >> right
                elif op in (ast.Div, ast.Mod) and right:
                    quotient = (abs(left) // abs(right)) * (-1 if (left < 0) != (right < 0) else 1)
                    value = quotient if op is ast.Div else left - quotient * right
                else:
                    raise ValueError("Unsupported operator")
            else:
                raise ValueError("Unresolved or unsupported expression")
            if value.bit_length() > 4096:
                raise ValueError("Expression too large")
            return value
        return visit(tree.body)

    try:
        text = str(expr_str).strip()
        if text.startswith('[') and text.endswith(']'):
            text = text[1:-1]
        if ':' in text:
            parts = text.split(':')
            if len(parts) != 2:
                return None
            return abs(evaluate(parts[0], set()) - evaluate(parts[1], set())) + 1
        return evaluate(text, set())
    except (ValueError, SyntaxError, TypeError, OverflowError, RecursionError):
        return None


def resolved_range(width_str, params):
    if not width_str:
        return ""
    parts = width_str.split(':')
    if len(parts) == 2:
        values = [safe_eval_expr(part, params) for part in parts]
        if all(value is not None for value in values):
            return f"{values[0]}:{values[1]}"
    return None


def is_complex_expression(expr: str) -> bool:
    """Returns True if expr is a compound expression (e.g. ~rst, {a,b}, data[15:0], a&b)."""
    expr = expr.strip()
    if not expr:
        return False
    # Check operators
    if any(op in expr for op in ['~', '&', '|', '^', '{', '}', '?', ':', '+', '-', '*', '/']):
        return True
    # Check bit slice, e.g., paddr[15:0] or data[7]
    if '[' in expr and ']' in expr:
        return True
    return False


def extract_signal_identifiers(expr: str) -> list:
    """Extracts raw signal/variable names from an expression (excluding constants and numbers)."""
    cleaned = re.sub(r"\d+'[bBoOdDhH][0-9a-fA-F_xXzZ]+", '', expr)
    cleaned = re.sub(r"\b\d+\b", '', cleaned)
    tokens = re.findall(r'\b[a-zA-Z_][a-zA-Z0-9_$]*\b', cleaned)
    keywords = {'logic', 'wire', 'reg', 'input', 'output', 'inout', 'assign', 'signed', 'unsigned', 'OPEN'}
    return [t for t in tokens if t not in keywords]


def calculate_expression_width(expr: str, known_signals_width: dict, param_dict: dict = None) -> int:
    """Calculates bit-width of a slice or concatenation or signal."""
    expr = expr.strip()
    if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_$]*\s*\[[^:\]]+\]', expr):
        return 1
    # Check slice: signal[MSB:LSB]
    m_slice = re.match(r'^([a-zA-Z_0-9]+)\s*\[\s*(.*?)\s*:\s*(.*?)\s*\]$', expr)
    if m_slice:
        msb = safe_eval_expr(m_slice.group(2), param_dict)
        lsb = safe_eval_expr(m_slice.group(3), param_dict)
        if msb is not None and lsb is not None:
            return abs(msb - lsb) + 1

    # Check concatenation: {a, b, c}
    if expr.startswith('{') and expr.endswith('}'):
        inner = expr[1:-1].strip()
        parts = split_balanced(inner, delim=',')
        total_w = 0
        for p in parts:
            pw = calculate_expression_width(p, known_signals_width, param_dict)
            if pw is None:
                return None
            total_w += pw
        return total_w

    # Inversion ~a has same width as a
    if expr.startswith('~'):
        return calculate_expression_width(expr[1:].strip(), known_signals_width, param_dict)

    # Base signal
    if expr in known_signals_width:
        return known_signals_width[expr]

    # Verilog constant width (e.g. 32'h0 -> 32)
    m_const = re.match(r"^(\d+)'[bBoOdDhH]", expr)
    if m_const:
        return int(m_const.group(1))

    return None


class VerilogPort:
    def __init__(self, name, direction, width_str="", raw_type="logic", is_interface=False):
        self.name = name.strip()
        self.direction = direction.strip().lower()  # 'input', 'output', 'inout', or 'interface'
        self.width_str = width_str.strip()
        self.raw_type = raw_type.strip()
        self.is_interface = is_interface

    def get_bitwidth(self, param_dict: dict = None) -> int:
        if self.is_interface:
            return None
        if not self.width_str:
            return 1
        return safe_eval_expr(self.width_str, param_dict)

    def get_decl_str(self):
        if self.is_interface:
            return f"    {self.raw_type:<32} {self.name}"
        w_str = f"[{self.width_str}]" if self.width_str else ""
        return f"    {self.direction:<6} wire {self.raw_type} {w_str:<32} {self.name}"

    def __repr__(self):
        return f"Port({self.direction} [{self.width_str}] {self.name})"


class ModuleInfo:
    def __init__(self, name):
        self.name = name
        self.ports = OrderedDict()
        self.default_params = OrderedDict()
        self.file_path = ""

    def add_port(self, port: VerilogPort):
        if port.name in self.ports:
            raise ValueError(f"Duplicate port '{port.name}' in module '{self.name}'")
        self.ports[port.name] = port

    def add_param(self, name: str, default_val: str):
        self.default_params[name.strip()] = default_val.strip()


class RtlParser:
    """Parser for scalar and one-dimensional ANSI ports; rejects other syntax."""

    @staticmethod
    def strip_comments(text: str) -> str:
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
        text = re.sub(r'//.*', '', text)
        return text

    @classmethod
    def parse_file(cls, filepath: str) -> dict:
        modules = {}
        with open(filepath, 'r', encoding='utf-8-sig') as f:
            content = f.read()

        clean_text = cls.strip_comments(content)

        idx = 0
        while True:
            m = re.search(r'\bmodule\s+([a-zA-Z_0-9]+)', clean_text[idx:])
            if not m:
                break
            mod_name = m.group(1)
            mod_start = idx + m.end()

            mod_info = ModuleInfo(mod_name)
            mod_info.file_path = filepath

            rem_text = clean_text[mod_start:]
            # Check for #(parameters)
            m_param_hash = re.match(r'\s*#', rem_text)
            if m_param_hash:
                param_content, end_p = extract_balanced_bracket(rem_text, '(', ')')
                if param_content:
                    cls._parse_parameters(param_content, mod_info)
                rem_text = rem_text[end_p + 1:] if end_p != -1 else rem_text

            # Check for (ports) - the '(' must directly follow the module name
            # (or its #(...) block), otherwise it's a portless/non-ANSI module
            # and we'd wrongly grab a '(' from the module body, e.g. @(posedge clk).
            if re.match(r'\s*\(', rem_text):
                port_content, end_ports = extract_balanced_bracket(rem_text, '(', ')')
                if port_content:
                    cls._parse_ansi_ports(port_content, mod_info)
                idx = mod_start + (len(clean_text[mod_start:]) - len(rem_text)) + end_ports + 1
            else:
                idx = mod_start + 1

            if mod_name in modules:
                raise ValueError(f"Duplicate module '{mod_name}' in {filepath}")
            modules[mod_name] = mod_info

        return modules

    @classmethod
    def _parse_parameters(cls, param_block: str, mod_info: ModuleInfo):
        tokens = split_balanced(param_block, delim=',')
        for tok in tokens:
            m = re.search(r'parameter\s+(?:type\s+)?(?:\w+\s+)?([a-zA-Z_0-9]+)\s*=\s*(.+)', tok)
            if m:
                mod_info.add_param(m.group(1), m.group(2))
            else:
                m2 = re.search(r'([a-zA-Z_0-9]+)\s*=\s*(.+)', tok)
                if m2:
                    mod_info.add_param(m2.group(1), m2.group(2))

    @classmethod
    def _parse_ansi_ports(cls, port_block: str, mod_info: ModuleInfo):
        last_port = None
        identifier = r'[A-Za-z_][A-Za-z0-9_$]*'
        for tok in split_balanced(port_block):
            tok = tok.strip()
            if re.fullmatch(identifier, tok):
                if last_port is None:
                    raise ValueError(f"Non-ANSI or untyped port '{tok}' in {mod_info.name}")
                port = VerilogPort(tok, last_port.direction, last_port.width_str,
                                   last_port.raw_type, last_port.is_interface)
            else:
                m = re.fullmatch(
                    rf'(input|output|inout)\s+(?:(?:wire|reg|logic|var)\s+)*'
                    rf'(?:(signed|unsigned)\s*)?(?:\[([^\]]+)\]\s*)?({identifier})', tok)
                if m:
                    port = VerilogPort(m[4], m[1], m[3] or "",
                                       "logic" + (" " + m[2] if m[2] else ""))
                else:
                    intf = re.fullmatch(rf'({identifier}(?:\.{identifier})?)\s+({identifier})', tok)
                    if not intf or intf[1] in ('input', 'output', 'inout', 'logic', 'wire', 'reg'):
                        raise ValueError(f"Unsupported port declaration '{tok}' in {mod_info.name}")
                    port = VerilogPort(intf[2], "interface", raw_type=intf[1], is_interface=True)
            mod_info.add_port(port)
            last_port = port


class InstanceConfig:
    def __init__(self, inst_name: str, module_name: str):
        self.inst_name = inst_name
        self.module_name = module_name
        self.param_overrides = OrderedDict()


class ConnectSpec:
    """Parses and holds the plain-text integration specification."""

    def __init__(self):
        self.top_module = "interconnect_core"
        self.wrapper_module = "top_wrapper"
        self.includes = []
        self.filelists = []
        self.instances = OrderedDict()
        self.auto_top_insts = set()
        self.top_ports = OrderedDict()
        self.connections = OrderedDict()
        self.explicit_wires = OrderedDict()

    @classmethod
    def load(cls, spec_file: str):
        spec = cls()
        sections = {'GLOBAL', 'INSTANCES', 'PARAMETERS', 'AUTO_CONNECT',
                    'TOP_PORTS', 'CORE_PORTS', 'CONNECTIONS', 'WIRES'}
        identifier = r'[A-Za-z_][A-Za-z0-9_$]*'
        section = None
        globals_seen = set()
        with open(spec_file, encoding='utf-8-sig') as handle:
            for line_num, raw in enumerate(handle, 1):
                line = raw.strip()
                if not line or line.startswith(('#', '//')):
                    continue
                try:
                    if line.startswith('[') and line.endswith(']'):
                        section = line[1:-1].strip().upper()
                        if section not in sections:
                            raise ValueError(f"Unknown section {section}")
                        continue
                    if section == 'GLOBAL':
                        key, value = [item.strip() for item in line.split('=', 1)]
                        key = key.upper()
                        if key in ('TOP_MODULE', 'CORE_MODULE', 'WRAPPER_MODULE'):
                            if not re.fullmatch(identifier, value):
                                raise ValueError("Invalid module name")
                            attr = 'wrapper_module' if key == 'WRAPPER_MODULE' else 'top_module'
                            if attr in globals_seen:
                                raise ValueError("Duplicate global module setting")
                            globals_seen.add(attr)
                            setattr(spec, attr, value)
                        elif key in ('INCLUDE', 'FILELIST') and value:
                            (spec.includes if key == 'INCLUDE' else spec.filelists).append(value)
                        else:
                            raise ValueError(f"Unknown global setting {key}")
                    elif section == 'INSTANCES':
                        body = line.removeprefix('INSTANCE ').strip()
                        params = None
                        if '#' in body:
                            head, tail = body.split('#', 1)
                            params, end = extract_balanced_bracket(tail)
                            if params is None or tail[end + 1:].strip():
                                raise ValueError("Malformed instance parameters")
                            body = head.strip()
                        m = re.fullmatch(rf'({identifier})\s*(?:=|\s)\s*({identifier})', body)
                        if not m or m[1] in spec.instances:
                            raise ValueError("Invalid or duplicate instance")
                        instance = InstanceConfig(m[1], m[2])
                        for item in split_balanced(params or ''):
                            key, value = [part.strip() for part in item.split('=', 1)]
                            key = key.lstrip('.')
                            if not re.fullmatch(identifier, key) or not value or key in instance.param_overrides:
                                raise ValueError("Invalid or duplicate parameter")
                            instance.param_overrides[key] = value
                        spec.instances[m[1]] = instance
                    elif section == 'PARAMETERS':
                        lhs, rhs = [part.strip() for part in line.split('=', 1)]
                        name, parameter = lhs.split('.', 1)
                        if name not in spec.instances or not re.fullmatch(identifier, parameter) or not rhs:
                            raise ValueError("Invalid parameter target")
                        overrides = spec.instances[name].param_overrides
                        if parameter in overrides:
                            raise ValueError("Duplicate parameter override")
                        overrides[parameter] = rhs
                    elif section == 'AUTO_CONNECT':
                        parts = line.split()
                        if len(parts) != 2 or parts[0] != 'AUTO_TOP':
                            raise ValueError("Expected AUTO_TOP instance")
                        spec.auto_top_insts.add(parts[1])
                    elif section in ('TOP_PORTS', 'CORE_PORTS'):
                        holder = ModuleInfo('top ports')
                        RtlParser._parse_ansi_ports(line.rstrip(';'), holder)
                        for name, port in holder.ports.items():
                            if name in spec.top_ports:
                                raise ValueError(f"Duplicate top port {name}")
                            spec.top_ports[name] = port
                    elif section == 'CONNECTIONS':
                        lhs, rhs = [part.strip() for part in line.split('=', 1)]
                        m = re.fullmatch(rf'({identifier})\.({identifier})', lhs)
                        if not m or not rhs or (m[1], m[2]) in spec.connections:
                            raise ValueError("Invalid or duplicate connection")
                        spec.connections[(m[1], m[2])] = rhs
                    elif section == 'WIRES':
                        m = re.fullmatch(rf'(?:(?:logic|wire)\s+)*(?:\[([^\]]+)\]\s*)?({identifier})', line.rstrip(';'))
                        if not m or m[2] in spec.explicit_wires or m[2] in spec.top_ports:
                            raise ValueError("Invalid or duplicate wire")
                        spec.explicit_wires[m[2]] = m[1] or ''
                    else:
                        raise ValueError("Entry has no section")
                except ValueError as exc:
                    raise ValueError(f"{spec_file}:{line_num}: {exc}") from exc
        return spec


class NetAuditEndpoint:
    def __init__(self, endpoint_str: str, direction: str, width: int = None, raw_width: str = ""):
        self.endpoint_str = endpoint_str  # e.g., "u_ip.data_out", "TOP_PORT(clk)", "inout(pad_dq)"
        self.direction = direction        # 'driver', 'receiver', 'inout'
        self.width = width
        self.raw_width = raw_width

    def __repr__(self):
        return f"{self.endpoint_str} [{self.direction}, width={self.width or self.raw_width}]"


class TopStitchEngine:
    def __init__(self, spec: ConnectSpec, known_modules: dict):
        self.spec = spec
        self.known_modules = known_modules
        self.audit_errors = []
        self.audit_warnings = []
        self.internal_wires = OrderedDict()
        self.net_map = OrderedDict()  # net_name -> list of NetAuditEndpoint
        self.known_signal_widths = OrderedDict()

    def get_effective_params(self, inst_cfg: InstanceConfig) -> dict:
        mod_info = self.known_modules.get(inst_cfg.module_name)
        params = OrderedDict()
        if mod_info:
            params.update(mod_info.default_params)
        params.update(inst_cfg.param_overrides)
        return params

    def run_stitch(self) -> str:
        self.audit_errors.clear()
        self.audit_warnings.clear()
        self.internal_wires.clear()
        self.net_map.clear()
        self.known_signal_widths.clear()
        # Pre-populate known widths from top ports & declared wires
        for p_name, p_obj in self.spec.top_ports.items():
            w = p_obj.get_bitwidth()
            if w:
                self.known_signal_widths[p_name] = w
            elif not p_obj.is_interface:
                self.audit_errors.append(f"Unresolved top port width: {p_name}")
        for w_name, w_str in self.spec.explicit_wires.items():
            w = safe_eval_expr(w_str) if w_str else 1
            if w:
                self.known_signal_widths[w_name] = w
            else:
                self.audit_errors.append(f"Unresolved wire width: {w_name}")

        for inst_name, port_name in self.spec.connections:
            cfg = self.spec.instances.get(inst_name)
            mod = self.known_modules.get(cfg.module_name) if cfg else None
            if cfg is None or (mod and port_name not in mod.ports):
                self.audit_errors.append(f"Unknown connection target: {inst_name}.{port_name}")
        for inst_name in sorted(self.spec.auto_top_insts - self.spec.instances.keys()):
            self.audit_errors.append(f"Unknown AUTO_TOP instance: {inst_name}")

        for inst_name, inst_cfg in self.spec.instances.items():
            if inst_cfg.module_name not in self.known_modules:
                self.audit_errors.append(
                    f"Module '{inst_cfg.module_name}' for instance '{inst_name}' not found in RTL files!"
                )
            else:
                mod = self.known_modules[inst_cfg.module_name]
                for parameter in inst_cfg.param_overrides.keys() - mod.default_params.keys():
                    self.audit_errors.append(f"Unknown parameter: {inst_name}.{parameter}")
                params = self.get_effective_params(inst_cfg)
                for parameter, expression in inst_cfg.param_overrides.items():
                    if safe_eval_expr(expression, params) is None:
                        self.audit_errors.append(f"Unresolved integer parameter: {inst_name}.{parameter}")
                for name, port in mod.ports.items():
                    expr = self.spec.connections.get((inst_name, name))
                    width = port.get_bitwidth(self.get_effective_params(inst_cfg))
                    if expr and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_$]*', expr) and width:
                        self.known_signal_widths.setdefault(expr, width)

        inst_port_map = OrderedDict()

        for inst_name, inst_cfg in self.spec.instances.items():
            inst_port_map[inst_name] = OrderedDict()
            mod_info = self.known_modules.get(inst_cfg.module_name)
            if not mod_info:
                continue

            eff_params = self.get_effective_params(inst_cfg)
            is_auto_top = inst_name in self.spec.auto_top_insts

            for port_name, port_obj in mod_info.ports.items():
                conn_key = (inst_name, port_name)
                actual_width = port_obj.get_bitwidth(eff_params)
                concrete_range = resolved_range(port_obj.width_str, eff_params)
                if not port_obj.is_interface and (actual_width is None or concrete_range is None):
                    self.audit_errors.append(f"Unresolved width on {inst_name}.{port_name}: {port_obj.width_str}")
                if port_obj.is_interface:
                    self.audit_warnings.append(f"Interface modport directions are not audited: {inst_name}.{port_name}")

                if conn_key in self.spec.connections:
                    expr = self.spec.connections[conn_key]
                    inst_port_map[inst_name][port_name] = expr

                    # Handle Expressions in CONNECTIONS (e.g. ~rst_n, {a,b}, paddr[15:0])
                    if is_complex_expression(expr):
                        if port_obj.direction != 'input':
                            self.audit_errors.append(f"Output/inout expression is not supported: {inst_name}.{port_name} = {expr}")
                            continue
                        # Extract underlying identifier tokens for Netlist Graph
                        tokens = extract_signal_identifiers(expr)
                        for tok in tokens:
                            # Register token as being read/consumed
                            if tok not in self.net_map:
                                self.net_map[tok] = []
                            self.net_map[tok].append(NetAuditEndpoint(
                                endpoint_str=f"{inst_name}.{port_name} (via expr: {expr})",
                                direction="receiver",
                                width=None,
                                raw_width=""
                            ))
                        # Do NOT declare compound expression as wire logic ~rst;!
                        # Calculate expression width for check if possible
                        expr_w = calculate_expression_width(expr, self.known_signal_widths, eff_params)
                        if expr_w is None:
                            self.audit_warnings.append(f"Unchecked expression width: {inst_name}.{port_name} = {expr}")
                        if expr_w is not None and actual_width is not None and expr_w != actual_width:
                            self.audit_warnings.append(
                                f"Bit-Width Mismatch in expression for '{inst_name}.{port_name}': Port is {actual_width}-bit, but expr '{expr}' is {expr_w}-bit!"
                            )

                    elif not self._is_constant(expr) and expr != "OPEN":
                        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_$]*', expr):
                            self.audit_errors.append(f"Unsupported net expression: {expr}")
                            continue
                        if port_obj.is_interface:
                            top = self.spec.top_ports.get(expr)
                            if not top or not top.is_interface or top.raw_type != port_obj.raw_type:
                                self.audit_errors.append(f"Interface {inst_name}.{port_name} requires a matching explicit top interface")
                            continue
                        # Plain net name
                        self._register_net_endpoint(
                            net_name=expr,
                            inst_name=inst_name,
                            port_name=port_name,
                            port_dir=port_obj.direction,
                            width=actual_width,
                            raw_width=port_obj.width_str
                        )
                        if expr not in self.known_signal_widths and actual_width:
                            self.known_signal_widths[expr] = actual_width

                        if expr not in self.spec.top_ports and expr not in self.internal_wires:
                            self.internal_wires[expr] = concrete_range or ""
                    elif expr == 'OPEN':
                        if port_obj.direction in ('input', 'interface'):
                            self.audit_warnings.append(f"Explicitly open input: {inst_name}.{port_name}")
                    elif port_obj.direction != 'input':
                        self.audit_errors.append(f"Constant cannot drive an output/inout connection: {inst_name}.{port_name}")
                    else:
                        constant_width = calculate_expression_width(expr, {}, eff_params)
                        if constant_width and actual_width and constant_width != actual_width:
                            self.audit_warnings.append(f"Bit-Width Mismatch in constant for {inst_name}.{port_name}")

                elif is_auto_top:
                    # Auto-connect to top port
                    inst_port_map[inst_name][port_name] = port_name
                    if port_name not in self.spec.top_ports:
                        self.spec.top_ports[port_name] = VerilogPort(
                            name=port_name,
                            direction=port_obj.direction,
                            width_str=concrete_range or "",
                            raw_type=port_obj.raw_type,
                            is_interface=port_obj.is_interface
                        )
                    self._register_net_endpoint(
                        net_name=port_name,
                        inst_name=inst_name,
                        port_name=port_name,
                        port_dir=port_obj.direction,
                        width=actual_width,
                        raw_width=port_obj.width_str
                    )
                else:
                    # Unconnected port!
                    if port_obj.direction == "input":
                        self.audit_warnings.append(
                            f"Floating input: '{inst_name}.{port_name}' (width: {actual_width or port_obj.width_str or '1'}) is unconnected. Auto-tied to 0."
                        )
                        inst_port_map[inst_name][port_name] = "'0"
                    else:
                        inst_port_map[inst_name][port_name] = ""

        # Register Top-level Ports in Net Map
        for p_name, p_obj in self.spec.top_ports.items():
            if p_obj.is_interface:
                continue
            p_width = p_obj.get_bitwidth()
            if p_obj.direction == "inout":
                ep_dir = "inout"
            elif p_obj.direction == "input":
                ep_dir = "driver"
            else:
                ep_dir = "receiver"

            if p_name not in self.net_map:
                self.net_map[p_name] = []
            self.net_map[p_name].append(NetAuditEndpoint(
                endpoint_str=f"TOP_PORT({p_name})",
                direction=ep_dir,
                width=p_width,
                raw_width=p_obj.width_str
            ))

        # Run Safety Audit
        for name, width in self.spec.explicit_wires.items():
            self.net_map.setdefault(name, []).append(NetAuditEndpoint(
                f"WIRE({name})", "declaration", self.known_signal_widths.get(name), width))
        self._perform_safety_audit()

        return self._generate_core_rtl(inst_port_map)

    def _register_net_endpoint(self, net_name: str, inst_name: str, port_name: str, port_dir: str, width: int, raw_width: str):
        if net_name == "OPEN" or not net_name or self._is_constant(net_name):
            return

        if net_name not in self.net_map:
            self.net_map[net_name] = []

        if port_dir == "inout":
            ep_dir = "inout"
        elif port_dir == "output":
            ep_dir = "driver"
        else:
            ep_dir = "receiver"

        self.net_map[net_name].append(NetAuditEndpoint(
            endpoint_str=f"{inst_name}.{port_name}",
            direction=ep_dir,
            width=width,
            raw_width=raw_width
        ))

    def _perform_safety_audit(self):
        """Audits netlist for multi-drivers, undriven nets, and bitwidth mismatches."""
        for net_name, endpoints in self.net_map.items():
            if self._is_constant(net_name):
                continue

            drivers = [ep for ep in endpoints if ep.direction == "driver"]
            receivers = [ep for ep in endpoints if ep.direction == "receiver"]
            inouts = [ep for ep in endpoints if ep.direction == "inout"]

            # 1. Multi-Driver Check (Ignore multiple inouts on bidirectional nets)
            if len(drivers) > 1:
                driver_names = ", ".join([d.endpoint_str for d in drivers])
                self.audit_errors.append(
                    f"Multi-Driver Conflict on net '{net_name}'! Driven by {len(drivers)} outputs: [{driver_names}]"
                )

            # 2. Undriven Input Check
            # If a net has inout ports, it is bidirectional and NOT undriven!
            if len(drivers) == 0 and len(inouts) == 0 and len(receivers) > 0:
                rcv_names = ", ".join([r.endpoint_str for r in receivers])
                self.audit_warnings.append(
                    f"Undriven Net / Floating Input on net '{net_name}'! Receivers: [{rcv_names}]"
                )

            # 3. Bit-Width Mismatch Check
            known_widths = [(ep.endpoint_str, ep.width) for ep in endpoints if ep.width is not None]
            if len(known_widths) > 1:
                base_name, base_w = known_widths[0]
                for other_name, other_w in known_widths[1:]:
                    if base_w != other_w:
                        self.audit_warnings.append(
                            f"Bit-Width Mismatch on net '{net_name}': '{base_name}' is {base_w}-bit, but '{other_name}' is {other_w}-bit!"
                        )
                        break

    def _is_constant(self, expr: str) -> bool:
        expr = expr.strip()
        return bool(re.fullmatch(r"\d+'[bBoOdDhH][0-9a-fA-F_xXzZ]+", expr)
                    or re.fullmatch(r"\d+", expr) or expr in ("'0", "'1", "'x", "'z"))

    def _generate_core_rtl(self, inst_port_map: dict) -> str:
        lines = []
        lines.append("// " + "="*76)
        lines.append(f"// Tier-1: Pure Interconnect Core (Auto-Generated)")
        lines.append(f"// Module Name: {self.spec.top_module}")
        lines.append("// " + "="*76)
        lines.append("`default_nettype none\n")

        for inc in self.spec.includes:
            lines.append(f'`include "{inc}"')
        if self.spec.includes:
            lines.append("")

        lines.append(f"module {self.spec.top_module} (")

        port_list = list(self.spec.top_ports.values())
        for i, port in enumerate(port_list):
            is_last = (i == len(port_list) - 1)
            comma = " " if is_last else ","
            lines.append(f"{port.get_decl_str()}{comma}")

        lines.append(");\n")

        # Internal wires
        if self.internal_wires or self.spec.explicit_wires:
            lines.append("    // " + "-"*68)
            lines.append("    // Internal Interconnect Wires")
            lines.append("    // " + "-"*68)
            all_wires = OrderedDict(self.spec.explicit_wires)
            for w, w_width in self.internal_wires.items():
                if w not in all_wires:
                    all_wires[w] = w_width

            for w_name, w_width in all_wires.items():
                # Avoid declaring complex expressions as wire
                if is_complex_expression(w_name):
                    continue
                width_str = f"[{w_width}]" if w_width else ""
                lines.append(f"    wire logic {width_str:<32} {w_name};")
            lines.append("")

        # Module instantiations
        for inst_name, inst_cfg in self.spec.instances.items():
            lines.append("    // " + "-"*68)
            lines.append(f"    // Instance: {inst_name} ({inst_cfg.module_name})")
            lines.append("    // " + "-"*68)

            param_decl = ""
            if inst_cfg.param_overrides:
                params = self.get_effective_params(inst_cfg)
                p_items = [f".{pk}({safe_eval_expr(pv, params)})"
                           for pk, pv in inst_cfg.param_overrides.items()]
                param_decl = f" #(\n        {', '.join(p_items)}\n    )"

            lines.append(f"    {inst_cfg.module_name}{param_decl} {inst_name} (")

            conn_dict = inst_port_map.get(inst_name, {})
            port_items = list(conn_dict.items())
            max_pname_len = max([len(p) for p, _ in port_items]) if port_items else 20

            for j, (p_name, expr) in enumerate(port_items):
                is_last_p = (j == len(port_items) - 1)
                p_comma = " " if is_last_p else ","
                if expr == "OPEN" or expr == "":
                    lines.append(f"        .{p_name:<{max_pname_len}} (){p_comma}")
                else:
                    lines.append(f"        .{p_name:<{max_pname_len}} ({expr}){p_comma}")

            lines.append("    );\n")

        lines.append(f"endmodule\n`default_nettype wire\n")
        return "\n".join(lines)

    def generate_wrapper_skeleton(self) -> str:
        lines = []
        lines.append("// " + "="*76)
        lines.append(f"// Tier-2: Top-Level Wrapper (Engineer-Maintained Frame)")
        lines.append(f"// Module Name: {self.spec.wrapper_module}")
        lines.append("// " + "="*76)
        lines.append("`default_nettype none\n")

        for inc in self.spec.includes:
            lines.append(f'`include "{inc}"')
        if self.spec.includes:
            lines.append("")

        lines.append(f"module {self.spec.wrapper_module} (")

        port_list = list(self.spec.top_ports.values())
        for i, port in enumerate(port_list):
            is_last = (i == len(port_list) - 1)
            comma = " " if is_last else ","
            lines.append(f"{port.get_decl_str()}{comma}")

        lines.append(");\n")

        lines.append("""    // ====================================================================
    // USER CUSTOM LOGIC ZONE: Clock Tree Buffers / Clock Gating / Reset Sync
    // ====================================================================
    /*
    // Example: User Clock Gating Logic
    // Insert project-specific clock/reset logic here when required.
    */

    // ====================================================================
    // Auto-Generated Interconnect Core Instantiation
    // ====================================================================
""")
        lines.append(f"    {self.spec.top_module} u_{self.spec.top_module} (")
        for i, port in enumerate(port_list):
            is_last = (i == len(port_list) - 1)
            comma = " " if is_last else ","
            lines.append(f"        .{port.name:<32} ({port.name}){comma}")
        lines.append("    );\n")

        lines.append(f"endmodule\n`default_nettype wire\n")
        return "\n".join(lines)


def parse_filelist(filelist_path: str, base_dir: str = ".") -> list:
    """Read plain source paths. Compiler switches/nested filelists are rejected."""
    path = Path(filelist_path).resolve()
    files = []
    with path.open(encoding='utf-8-sig') as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line or line.startswith(('#', '//')):
                continue
            if line.startswith(('-', '+')):
                raise ValueError(f"{path}:{number}: only plain RTL paths are supported")
            candidate = Path(line)
            if not candidate.is_absolute():
                relative = path.parent / candidate
                candidate = relative if relative.is_file() else Path(base_dir) / candidate
            if not candidate.is_file():
                raise ValueError(f"{path}:{number}: source not found: {line}")
            files.append(str(candidate.resolve()))
    return files


def atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n',
                                         dir=path.parent, prefix='.stitch-', delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(content)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description="RTL auto-stitch tool (restricted ANSI SystemVerilog subset)")
    parser.add_argument("--spec", "-s", required=True, help="Connection specification")
    parser.add_argument("--filelist", "-f", help="Plain source paths; limits the parsed files")
    parser.add_argument("--output-core", "-o", help="Generated interconnect core")
    parser.add_argument("--gen-wrapper-template", "-w", help="Optional wrapper skeleton")
    parser.add_argument("--search-dir", "-d", default=".", help="RTL search root when no filelist is given")
    parser.add_argument("--report", "-r", default="connectivity_audit.rpt", help="Audit report")
    parser.add_argument("--strict", action="store_true", help="Treat audit warnings as failures")
    args = parser.parse_args()

    try:
        spec = ConnectSpec.load(args.spec)
        if not spec.instances:
            raise ValueError("No instances specified")
        out_core = Path(args.output_core or f"{spec.top_module}.sv").resolve()
        destinations = [out_core, Path(args.report).resolve()]
        if args.gen_wrapper_template:
            destinations.append(Path(args.gen_wrapper_template).resolve())
        if len(set(destinations)) != len(destinations):
            raise ValueError("Output, report and wrapper paths must be distinct")
        filelists = [str(Path(args.spec).resolve().parent / path) for path in spec.filelists]
        if args.filelist:
            filelists.append(args.filelist)
        source_files = []
        for filelist in filelists:
            source_files.extend(parse_filelist(filelist, args.search_dir))
        if not filelists:
            for root, directories, files in os.walk(args.search_dir):
                directories[:] = sorted(d for d in directories if d not in ('.git', '__pycache__'))
                for name in sorted(files):
                    candidate = Path(root, name).resolve()
                    if candidate.suffix in ('.sv', '.v') and candidate not in destinations:
                        source_files.append(str(candidate))
        inputs = {Path(path).resolve() for path in source_files + filelists + [args.spec]}
        if inputs.intersection(destinations):
            raise ValueError("An output path aliases an input")
        known_modules = {}
        for source in sorted(set(source_files)):
            for name, module in RtlParser.parse_file(source).items():
                if name in known_modules:
                    raise ValueError(f"Duplicate module '{name}' in {source} and {known_modules[name].file_path}")
                known_modules[name] = module
        stitcher = TopStitchEngine(spec, known_modules)
        core_rtl = stitcher.run_stitch()
        report = [f"Core module: {spec.top_module}", f"Wrapper module: {spec.wrapper_module}", ""]
        report.extend(f"ERROR: {error}" for error in stitcher.audit_errors)
        report.extend(f"WARNING: {warning}" for warning in stitcher.audit_warnings)
        if not stitcher.audit_errors and not stitcher.audit_warnings:
            report.append("PASS: no issues detected within the supported audit scope.")
        atomic_write(args.report, "\n".join(report) + "\n")
        if stitcher.audit_errors or (args.strict and stitcher.audit_warnings):
            print(f"Generation failed; existing RTL preserved. See {args.report}", file=sys.stderr)
            return 1
        atomic_write(out_core, core_rtl)
        if args.gen_wrapper_template:
            atomic_write(args.gen_wrapper_template, stitcher.generate_wrapper_skeleton())
        print(f"Generated: {out_core}")
        print(f"Audit: {args.report}")
        return 0
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
