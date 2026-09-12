# ASIC_Tools 中文指南

[English](README.md) | [贡献与测试约定](CONTRIBUTING.md)

ASIC_Tools 用于收集、开发和维护 ASIC 开发工具与脚本，辅助 ASIC 工程师调试设计、
减少重复性工作，并提高代码质量与可读性。

## 工具概览

| 工具 | 用途 |
| --- | --- |
| [寄存器生成器](tools/reggen/gen_reg_inc.pl) | 从寄存器表生成 RTL 宏、interface、C 头文件和地址文档。 |
| [TopStitcher](tools/topstitcher/stitch_top.py) | 从连接规范生成顶层 RTL，在有限的 SystemVerilog 语法范围内检查连接关系和位宽。 |

## 目录结构

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

每个工具在 `tools/` 下使用按功能命名的独立目录，不按实现语言分类。
工具专用的辅助模块与入口脚本放在同一目录；独立示例放在 `examples/`，
回归入口放在 `tests/`。生成物放在 `build/`，不纳入版本管理。

## 1. 环境

- 寄存器生成器：Perl 5.14 或更新版本及其核心模块，包括 JSON::PP、Math::BigInt。
- TopStitcher 和测试入口：Python 3.9 或更新版本，仅使用标准库。
- HDL 示例验证：slang、Verilator，以及 Verilator 所需的 C++ 构建工具链。

命令均从仓库根目录运行；Linux 中若 Python 3 的入口名为 `python3`，请将下文
命令中的 `python` 换成 `python3`。具体跨平台测试矩阵见贡献说明。

## 2. 寄存器生成

```sh
perl tools/reggen/gen_reg_inc.pl --config examples/reggen/config.json
```

默认只生成，不修改 RTL。四类输出位于 `build/reggen/`：

| 文件 | 内容 |
| --- | --- |
| `reg_inc.v` | 地址、复位和读写 RTL 宏 |
| `register_if.sv` | 寄存器 interface 定义 |
| `regs.h` | 软件/验证使用的 C 宏 |
| `reg_map.md` | 地址和字段文档 |

示例包含重复控制实例、只读状态、W1C/W1S、保留位和 48 位寄存器。
表格和生成 RTL 使用相对偏移；配置的基地址用于 C 头文件和地址文档。
生成逻辑不会自动从 APB 地址减去基地址，系统集成时应自行处理地址译码。

### 配置规则

示例配置位于 [examples/reggen/config.json](examples/reggen/config.json)。

| JSON 字段 | 对应参数 | 含义 |
| --- | --- | --- |
| `input` | `--input` | 输入寄存器表 |
| `output` | `--output` | RTL 宏文件 |
| `interface_output` | `--interface-output` | interface 文件 |
| `sim_header` | `--sim-header` | C 头文件 |
| `map_output` | `--map-output` | Markdown 文档 |
| `rtlroot` | `--rtlroot` | 注入目标搜索目录 |
| `workdir` | `--workdir` | 每次运行使用的独立临时子目录的父目录 |
| `apb_interface` | `--apb-interface` | APB 信号前缀，默认 `apb` |
| `marker_prefix` | `--marker-prefix` | 注入标记前缀，默认 `reggen_` |
| `map_description_width` | `--map-description-width` | 描述列换行宽度，默认 100 |
| `modules` | 见下文 | 模块到 RTL 文件及基地址的映射 |

JSON 中的路径相对于配置文件；命令行路径相对于当前目录。同一选项以命令行为准。
未知配置键会报错。模块映射的键使用大写标识符，例如：

```json
{
  "modules": {
    "DEMO": {"rtl_file": "demo_regs.sv", "base_addr": "0x2000"}
  }
}
```

`rtl_file` 是文件名，不是相对路径；注入时必须在 `rtlroot` 中恰好找到一个目标。
未设置的基地址为零。使用 `--module DEMO --rtl-file demo_regs.sv --base-addr 0x2000`
可覆盖单个模块映射，但不能省略 `--module`。

### 输入格式

示例使用 UTF-8 竖线表格，不支持直接读取逗号分隔的 CSV 文件。
参考 [registers.txt](examples/reggen/registers.txt)：

```text
| Module | Offset | BitRange | RegName | Reset | Access | Interface | Owner | Description |
| DEMO | 0x0 | [7:0] | control | 0x12 | RW | demo_control_if:ctrl0 | - | Example control |
```

- `Offset` 是十进制或 `0x` 十六进制字节偏移；示例按 32 位字安排地址。
- `BitRange` 使用 `[bit]` 或 `[msb:lsb]`。普通字段应位于单个 32 位字内。
- 自动跨字字段使用从零开始的范围，如 `[47:0]`，每个后续字增加 4 字节。
- `Reset` 使用字段自身的数值，不预先左移到总线位置；不能超过字段宽度。
- `Access` 仅接受 `RW`、`RO`、`W1C`、`W1S`。
- `Interface` 为 `-` 时生成普通端口；`类型:实例` 可区分同类型的多个实例。
- 同名寄存器必须通过不同 interface 实例区分；宏名会在需要时包含实例名。
- `Reserved` 开头的字段用于保留位占位，不生成可写寄存器；仍参与重叠检查。
- `Owner`、`Description` 分别为可选的责任人和字段说明。

空行及以 `#` 或 `//` 开头的注释可用于组织输入。

### RTL 集成

先预览：

```sh
perl tools/reggen/gen_reg_inc.pl --config examples/reggen/config.json --inject --dry-run
```

省略 `--dry-run` 后会改写示例配置指向的 `examples/reggen/rtl/demo_regs.sv`。
后文的示例测试在临时副本中执行完整流程，不修改仓库模板。

目标文件必须包含四组独占一行的标记，每组恰好一对且不能嵌套：

```text
//reggen_port_on
//reggen_port_off
//reggen_default_on
//reggen_default_off
//reggen_write_on
//reggen_write_off
//reggen_read_on
//reggen_read_off
```

四组标记分别放在端口、复位、写和读逻辑区域。
完整外壳参考 [demo_regs.sv](examples/reggen/rtl/demo_regs.sv)。
缺失、重复、错序标记或多个同名目标会阻止输出写入。

集成时配置地址、模块映射、APB 前缀、标记前缀和路径；需要修改 RTL 时添加
`--inject`。例如标记为 `//custom_regport_on`，配置前缀为 `custom_reg`。
`--skip-inject` 禁用注入，`--no-skip-inject` 启用注入。目标搜索范围由 `rtlroot` 指定。

临时文件放在每次运行独立的子目录，结束时只清理该子目录；`--keep-temp` 可保留检查。
校验完成后才替换目标文件。多文件替换不是一个整体事务，写入过程中发生磁盘故障
可能导致部分文件已更新；运行期间应避免并发修改目标文件。

W1C/W1S 只描述软件写入行为。硬件事件置位/清零、并发优先级、字节写使能和
跨字原子访问需要单独实现集成逻辑。

## 3. TopStitcher

```sh
python tools/topstitcher/stitch_top.py --spec examples/topstitch/connect.txt --output-core build/demo_top.sv --report build/top_audit.txt --strict
```

示例把子模块参数设为 16，并自动导出端口。主要参数：

| 参数 | 含义 |
| --- | --- |
| `--spec` | 连线规范，必填 |
| `--filelist` | 限定输入 RTL 文件 |
| `--search-dir` | 没有文件列表时的扫描目录，默认当前目录 |
| `--output-core` | 自动生成的顶层 |
| `--gen-wrapper-template` | 可选外层骨架；只在明确需要重新生成时指定 |
| `--report` | 审计报告路径 |
| `--strict` | 将审计警告也视为失败，推荐用于自动测试 |

连接规范使用以下节，完整例子见 [connect.txt](examples/topstitch/connect.txt)：

```text
[GLOBAL]
CORE_MODULE = demo_top
WRAPPER_MODULE = demo_wrapper
FILELIST = files.f
[INSTANCES]
u_pair = data_pair #(W=16)
[AUTO_CONNECT]
AUTO_TOP u_pair
```

`[TOP_PORTS]` 可写 `input [7:0] data` 等显式顶层端口；`[CONNECTIONS]` 使用
`实例.端口 = 网络或表达式`；`[WIRES]` 可写 `wire [7:0] bus`；`[PARAMETERS]`
使用 `实例.参数 = 整数表达式`。参数覆盖应放在实例定义后，不能重复定义。
`OPEN` 表示显式悬空；悬空输入会警告。

规范内的 `FILELIST` 相对于规范文件，命令行文件列表相对于当前目录。
列表中每行一个 RTL 路径，优先相对于列表文件解析；兼容回退到 `--search-dir`。
不支持编译器开关或嵌套文件列表。建议总是使用明确列表，避免扫描无关 RTL。

支持标量/单维 ANSI 端口、共享声明、signed/unsigned、有限整数参数表达式和整网检查。
参数化顶层及自动内部连线使用解析后的具体范围。输入切片/拼接只做有限位宽检查；
输出或 inout 表达式直接拒绝，接口 modport 方向未验证时给出警告。
切片索引边界、复杂类型、预处理和完整定宽整数语义不由该工具完整检查。

严重错误返回非零状态；严格模式下警告也会阻止生成，审计失败保留旧 RTL。
进入审计阶段后会更新报告；解析阶段失败可能保留旧报告，应同时检查退出状态。
外层模板不是手工代码合并器，重新指定该输出会覆盖已有模板。

TopStitcher 不是完整 SystemVerilog 编译器，不能替代 HDL 检查、仿真、CDC、时序
或双向电气连接签核。使用不支持的头部语法时，应简化输入或选择完整编译器前端。

## 4. 验证与贡献

```sh
python -B tests/test_tools.py
python -B tests/run_examples.py
```

第一条执行标准库回归测试；第二条把示例复制到临时目录，生成两套设计，再执行
slang 展开和 Verilator 自检仿真，不修改仓库中的示例模板。

自定义工具位置可通过 `PERL`、`SLANG`、`VERILATOR`、`VERILATOR_RUN` 环境变量提供。
示例运行器也支持 `--perl`、`--slang`、`--verilator`、`--verilator-run` 参数；Windows
可传入本机的启动脚本路径。

[CI 工作流](.github/workflows/ci.yml) 包含 Linux/Windows 生成器回归和 Linux HDL 测试。
测试矩阵、贡献规范及缺陷报告要求见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 5. 许可证

ASIC_Tools 使用 [MIT 许可证](LICENSE)。

Copyright (c) 2026 MetatronJeanne.
