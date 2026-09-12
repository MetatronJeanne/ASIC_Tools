#!/usr/bin/perl
# Copyright (c) 2026 MetatronJeanne
# SPDX-License-Identifier: MIT
##########################################################################
# Version: 2.12
# Author: MetatronJeanne
# Update: 
# 2026/03/02 MetatronJeanne
#			1.Refacoring code using Perl, version update to 2.00
#	2026/03/03 MetatronJeanne
#			1.Update the regular matching expression in parse_input to exclude lines starting with "#>" using "^#(?!>)".
#			2.Refactoring gen_offset_macro, unifying the initial value to "Undefined", adding a deduplication Hash to ensure that the last offset will no longer be missed.
#			3.Refactoring gen_rw_macro to solve offset mismatch issue.Version update to 2.01.
#	2026/03/04 MetatronJeanne
#			1.Add subroutine flush_close_temp_handles for closing handles and flushing disks to prevent text from being stuck in memory buffers and causing *.temp files to read empty.
#			2.Fix duplicate handle declarations in inject_rtl.Version update to 2.02
#	2026/03/05 MetatronJeanne
#			1.Add subroutine split_wide_register to support automatic splitting of registers with a width of 32 bits or above.
#			2.Add subroutine gen_register_interface to support automatic packaging of registers into the interface based on column reg_define.txt settings and output to interface.sv, version update to 2.03.
#	2026/03/11 MetatronJeanne
#			1.Add the interface path of the register to the generated RTL.Version update to 2.04.
#	2026/03/13 MetatronJeanne
#			1.Fix the issue of signal confusion in modport during interface generation.
#			2.Fix global symbol missing issues. Version update to 2.05
#	2026/03/20 MetatronJeanne
#			1.Add multi segment merging function for the same register.
#			2.Reverse the signal direction of modport m and s. Version update to 2.06.
#   2026/03/26 MetatronJeanne
#           1.Add InterfaceType:InterfaceInstance to support module repetition instantiation.Version update to 2.07
#   2026/03/27 MetatronJeanne
#           1.Add C verification header file generation function, version update to 2.08
#   2026/04/14 MetatronJeanne
#           1.Change the input file format from .txt to .csv, now user can use Excel to manage the register table.Version update to 2.09
#   2026/05/12 MetatronJeanne
#           1.Add auto interface instantiation function.Version update to 2.10.
#   2026/05/15 MetatronJeanne
#           1.Add same register name detect between two or more different interface in a same module.Version update to 2.11.
# Description:
#			This is a register automation batch management script, which runs as follows:
#					1.Ensure that Perl 5.14 or above is installed in your work environment.
#					2.Provide a register table with --input or a JSON file with --config.
#					3.Run --help for options. RTL injection requires explicit --inject.
#
#	
##########################################################################
use strict;
use warnings;
use Text::ParseWords; # Perl core library, handling quotation marks and escape characters
use Getopt::Long;
use File::Find;
use File::Path qw/mkpath rmtree/;
use File::Temp qw/tempdir tempfile/;
use File::Basename qw/dirname basename/;
use File::Copy qw/copy/;
use JSON::PP qw/decode_json/;
use Math::BigInt;
use Cwd qw/abs_path/;
use File::Spec;
use FindBin qw($Bin);
use IO::Handle; # Import IO::Handle to support file handle flush method

# -------------------------- Global Configuration and Parameter Parsing --------------------------
my ($input_file, $output_macro, $work_dir, $rtl_root, $keep_temp, $interface_output, $sim_header_output, $map_output);
my ($default_module, $default_rtl_file, $default_base_addr, $skip_inject);
my ($map_description_width, $config_file, $work_parent, $apb_interface, $marker_prefix, $dry_run, $help);
my (@pending_outputs, @publish_files);
GetOptions(
    'config=s'         => \$config_file,
    'help|h'           => \$help,
    'input=s'          => \$input_file,
    'output=s'         => \$output_macro,
    'workdir=s'        => \$work_parent,
    'rtlroot=s'        => \$rtl_root,
    'keep-temp'        => \$keep_temp,
    'interface-output=s' => \$interface_output, # Add: Interface file output path
    'sim-header=s'       => \$sim_header_output,
    'map-output=s'       => \$map_output,
    'map-description-width=i' => \$map_description_width,
    'module=s'           => \$default_module,
    'rtl-file=s'         => \$default_rtl_file,
    'base-addr=s'        => \$default_base_addr,
    'skip-inject!'       => \$skip_inject,
    'inject'            => sub { $skip_inject = 0 },
    'dry-run'           => \$dry_run,
    'apb-interface=s'   => \$apb_interface,
    'marker-prefix=s'   => \$marker_prefix
) or die "[ERROR] Command line parameter parsing failed! Please check parameter format\n";

if ($help) {
    print <<'HELP';
Usage: perl gen_reg_inc.pl --input FILE [options]
       perl gen_reg_inc.pl --config FILE [overrides]

--config FILE             JSON configuration; paths are relative to FILE
--input FILE              Register table (required without configuration)
--output FILE             RTL macros (default: build/reggen/reg_inc.v)
--interface-output FILE   Register interfaces
--sim-header FILE         C header
--map-output FILE         Markdown register map
--workdir DIR             Parent of a new, private temporary directory
--keep-temp               Retain that private directory for inspection
--rtlroot DIR             RTL search root (required when injecting)
--module NAME             Module to override with --rtl-file / --base-addr
--rtl-file NAME           Exact RTL basename; ambiguous matches are errors
--base-addr NUMBER        Absolute base address, decimal or hexadecimal
--apb-interface NAME      Bus signal prefix (default: apb)
--marker-prefix NAME      Prefix before port/default/write/read (reggen_)
--inject                  Enable RTL injection (disabled by default)
--skip-inject             Generate only; --no-skip-inject also enables injection
--dry-run                 Validate and preview without publishing files
--map-description-width N Description wrapping width (default: 100)
--help                    Show this help

CLI options override JSON. Existing projects must explicitly configure their
addresses, bus name, marker prefix and RTL root. No parent project is assumed.
HELP
    exit 0;
}

my $config = {};
my %path_options = (
    input => \$input_file, output => \$output_macro, workdir => \$work_parent,
    rtlroot => \$rtl_root, interface_output => \$interface_output,
    sim_header => \$sim_header_output, map_output => \$map_output,
);
if (defined $config_file) {
    $config_file = normalize_path($config_file);
    open my $cfg_fh, '<:raw', $config_file or die "[ERROR] Cannot open config: $!\n";
    { local $/; $config = decode_json(<$cfg_fh>); }
    close $cfg_fh;
    die "[ERROR] Config must be a JSON object\n" unless ref($config) eq 'HASH';
    my %allowed = map { $_ => 1 } (keys %path_options, qw/modules apb_interface marker_prefix map_description_width/);
    for my $key (keys %$config) {
        die "[ERROR] Unknown config key: $key\n" unless $allowed{$key};
        die "[ERROR] Config $key must be a scalar value\n"
            if $key ne 'modules' && (!defined($config->{$key}) || ref($config->{$key}));
    }
    for my $key (keys %path_options) {
        next unless exists $config->{$key} && !defined ${$path_options{$key}};
        ${$path_options{$key}} = File::Spec->rel2abs($config->{$key}, dirname($config_file));
    }
    $apb_interface //= $config->{apb_interface};
    $marker_prefix //= $config->{marker_prefix};
    $map_description_width //= $config->{map_description_width};
}
die "[ERROR] --input or config input is required; use --help\n" unless defined $input_file;
die "[ERROR] Unexpected positional arguments: @ARGV\n" if @ARGV;
$output_macro     //= File::Spec->catfile('build', 'reggen', 'reg_inc.v');
$interface_output //= File::Spec->catfile('build', 'reggen', 'register_if.sv');
$sim_header_output //= File::Spec->catfile('build', 'reggen', 'regs.h');
$map_output       //= File::Spec->catfile('build', 'reggen', 'reg_map.md');
$work_parent      //= File::Spec->tmpdir();
$keep_temp        //= 0;
$map_description_width //= 100;
$default_rtl_file //= "";
$default_base_addr //= "";
$skip_inject      //= 1;
$apb_interface    //= 'apb';
$marker_prefix    //= 'reggen_';
die "[ERROR] --module is required for mapping overrides\n"
    if !defined($default_module) && ($default_rtl_file ne '' || $default_base_addr ne '');
die "[ERROR] --rtlroot is required when injecting\n" if !$skip_inject && !defined $rtl_root;
die "[ERROR] Invalid APB interface name\n" unless $apb_interface =~ /^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/;
die "[ERROR] Invalid marker prefix\n" unless $marker_prefix =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
die "[ERROR] --map-description-width must be a positive integer\n"
    unless $map_description_width =~ /^\d+$/ && $map_description_width > 0;

# Convert to absolute paths (avoid relative path issues, including files not created yet)
$input_file        = normalize_path($input_file) if defined $input_file;
$output_macro      = normalize_path($output_macro) if defined $output_macro;
$work_parent       = normalize_path($work_parent);
$rtl_root          = normalize_path($rtl_root) if defined $rtl_root;
$interface_output  = normalize_path($interface_output) if defined $interface_output;
$sim_header_output = normalize_path($sim_header_output) if defined $sim_header_output;
$map_output        = normalize_path($map_output) if defined $map_output;

# Global data structures
my @regs;               # Store split register info (for macro generation/RTL injection)
my @orig_regs;          # Store original unsplit register info (for interface generation)
my %module2rtl;         # Module-RTL file mapping: key=module name (UPPER CASE), value=RTL file name
my %module_temp;        # Module temporary file handles: key=module name, value={def, wr, rd}
my %module_base_addr;   # Store Base Address of each module
die "[ERROR] Config modules must be an object\n" if exists($config->{modules}) && ref($config->{modules}) ne 'HASH';
my %default_module_map = %{ $config->{modules} // {} };
for my $mod (keys %default_module_map) {
    die "[ERROR] Invalid config module: $mod (use uppercase identifiers)\n" unless $mod =~ /^[A-Z_][A-Z0-9_]*$/;
    my $mapping = $default_module_map{$mod};
    die "[ERROR] Mapping for $mod must be an object\n" unless ref($mapping) eq 'HASH';
    for my $key (keys %$mapping) {
        die "[ERROR] Invalid mapping key for $mod: $key\n"
            unless $key =~ /^(rtl_file|base_addr)$/ && defined($mapping->{$key}) && !ref($mapping->{$key});
    }
}

sub normalize_path {
    my $path = shift;
    return abs_path($path) if defined $path && -e $path;
    return File::Spec->canonpath(File::Spec->rel2abs($path));
}

sub get_output_dir {
    my $path = shift;
    my ($volume, $dirs, $file) = File::Spec->splitpath($path);
    my $dir = File::Spec->catpath($volume, $dirs, "");
    return $dir ne "" ? $dir : File::Spec->curdir();
}

sub trim {
    my $val = shift;
    $val = "" unless defined $val;
    $val =~ s/^\s+|\s+$//g;
    return $val;
}

sub split_table_row {
    my $line = shift // "";
    my @fields = map { trim($_) } split(/\|/, $line, -1);
    shift @fields if @fields && $fields[0] eq "";
    pop @fields if @fields && $fields[-1] eq "";
    return @fields;
}

sub is_description_separator {
    my @fields = @_;
    return 0 unless @fields >= 9;
    return 0 if grep { $_ ne "" } @fields[0..7];
    my $separator = trim(join("", @fields[8..$#fields]));
    return $separator =~ /^-{3,}$/ ? 1 : 0;
}

sub is_reserved_name {
    my $name = shift // "";
    return $name =~ /^reserved/i ? 1 : 0;
}

sub parse_int_literal {
    my $literal = trim(shift);
    return hex($literal) if $literal =~ /^0x[0-9a-fA-F]+$/;
    return int($literal) if $literal =~ /^\d+$/;
    die "[ERROR] Illegal integer literal: $literal\n";
}

sub normalize_offset_literal {
    my $literal = trim(shift);
    my $num = parse_int_literal($literal);
    return sprintf("0x%03x", $num) if $num >= 0x10 && $num < 0x100;
    return sprintf("0x%x", $num);
}

sub normalize_reset_literal {
    my $reset = lc(trim(shift));
    return "0x0" if $reset eq "" || $reset eq "-";
    return $reset if $reset =~ /^0x[0-9a-f]+$/;
    return sprintf("0x%x", $reset) if $reset =~ /^\d+$/;
    return $reset if $reset =~ /n\/a|todo/i;
    die "[ERROR] Illegal reset literal: $reset\n";
}

sub sanitize_macro_name {
    my $name = shift // "";
    $name = uc($name);
    $name =~ s/\[(\d+):(\d+)\]/_$1_$2/g;
    $name =~ s/[^A-Z0-9_]/_/g;
    $name =~ s/^_+//;
    return $name;
}

sub markdown_display_width {
    my $text = shift // "";
    my $width = 0;

    foreach my $cp (unpack("U*", $text)) {
        # Zero-width combining marks and variation selectors.
        next if ($cp >= 0x0300 && $cp <= 0x036F) ||
                ($cp >= 0x1AB0 && $cp <= 0x1AFF) ||
                ($cp >= 0x1DC0 && $cp <= 0x1DFF) ||
                ($cp >= 0x20D0 && $cp <= 0x20FF) ||
                ($cp >= 0xFE00 && $cp <= 0xFE0F) ||
                ($cp >= 0xFE20 && $cp <= 0xFE2F);

        my $is_wide =
            ($cp >= 0x1100 && $cp <= 0x115F) ||
            $cp == 0x2329 || $cp == 0x232A ||
            ($cp >= 0x2E80 && $cp <= 0xA4CF && $cp != 0x303F) ||
            ($cp >= 0xAC00 && $cp <= 0xD7A3) ||
            ($cp >= 0xF900 && $cp <= 0xFAFF) ||
            ($cp >= 0xFE10 && $cp <= 0xFE19) ||
            ($cp >= 0xFE30 && $cp <= 0xFE6F) ||
            ($cp >= 0xFF00 && $cp <= 0xFF60) ||
            ($cp >= 0xFFE0 && $cp <= 0xFFE6) ||
            ($cp >= 0x1F300 && $cp <= 0x1FAFF);
        $width += $is_wide ? 2 : 1;
    }

    return $width;
}

sub pad_markdown_cell {
    my ($text, $target_width) = @_;
    $text //= "";
    my $padding = $target_width - markdown_display_width($text);
    $padding = 0 if $padding < 0;
    return $text . (" " x $padding);
}

sub split_markdown_at_width {
    my ($text, $max_width) = @_;
    my @chars = unpack("U*", $text);
    my ($width, $cut, $last_space) = (0, 0, -1);

    for my $i (0 .. $#chars) {
        my $char = pack("U", $chars[$i]);
        my $char_width = markdown_display_width($char);
        last if $width + $char_width > $max_width;
        $width += $char_width;
        $cut = $i + 1;
        $last_space = $cut if $char =~ /\s/;
    }

    $cut = 1 if $cut == 0;
    $cut = $last_space if $last_space > 0;
    my $head = pack("U*", @chars[0 .. $cut - 1]);
    my $tail = $cut <= $#chars ? pack("U*", @chars[$cut .. $#chars]) : "";
    $head =~ s/\s+$//;
    $tail =~ s/^\s+//;
    return ($head, $tail);
}

sub wrap_markdown_description {
    my ($description, $max_width) = @_;
    return ("") if !defined($description) || $description eq "";

    my @wrapped;
    foreach my $segment (split(/<br>/i, $description, -1)) {
        $segment = trim($segment);
        if ($segment eq "") {
            push @wrapped, "";
            next;
        }
        while (markdown_display_width($segment) > $max_width) {
            my ($head, $tail) = split_markdown_at_width($segment, $max_width);
            push @wrapped, $head;
            $segment = $tail;
        }
        push @wrapped, $segment if $segment ne "" || !@wrapped;
    }
    return @wrapped;
}

# -------------------------- Resource Cleanup on Script Exit --------------------------
END {
    # Close all temporary file handles
    foreach my $mod (keys %module_temp) {
        close $module_temp{$mod}->{def} if exists $module_temp{$mod}->{def};
        close $module_temp{$mod}->{wr}  if exists $module_temp{$mod}->{wr};
        close $module_temp{$mod}->{rd}  if exists $module_temp{$mod}->{rd};
        close $module_temp{$mod}->{port} if exists $module_temp{$mod}->{port};
    }
    # Auto clean up temporary directory (unless --keep-temp is specified)
    unlink $_ for grep { -f $_ } @publish_files;
    if (!$keep_temp && defined($work_dir) && -d $work_dir
        && dirname($work_dir) eq $work_parent && basename($work_dir) =~ /^reggen-/) {
        rmtree($work_dir);
        print "[INFO] Temporary directory auto-cleaned: $work_dir\n";
    } elsif ($keep_temp && defined $work_dir) {
        print "[INFO] Temporary directory retained: $work_dir\n";
    }
}

# -------------------------- Core Subroutine: Pre-Check --------------------------
sub pre_check {
    die "[ERROR] Input file does not exist: $input_file\n" unless -f $input_file;
    die "[ERROR] Input file is not readable: $input_file\n" unless -r $input_file;
    mkpath($work_parent) unless -d $work_parent;
    $work_parent = abs_path($work_parent);
    $work_dir = tempdir('reggen-XXXXXXXX', DIR => $work_parent, CLEANUP => 0);
    $work_dir = abs_path($work_dir);
    for my $path_ref (\$output_macro, \$interface_output, \$sim_header_output, \$map_output) {
        $$path_ref = stage_output($$path_ref);
    }
    print "[INFO] Pre-check passed, starting processing...\n";
}

sub stage_output {
    my $destination = normalize_path(shift);
    my $key = $^O eq 'MSWin32' ? lc($destination) : $destination;
    for my $protected ($input_file, $config_file, map { $_->{destination} } @pending_outputs) {
        next unless defined $protected;
        $protected = lc($protected) if $^O eq 'MSWin32';
        die "[ERROR] Output aliases an input or another output: $destination\n" if $key eq $protected;
    }
    die "[ERROR] Output is not a regular file: $destination\n" if -e $destination && !-f $destination;
    my ($fh, $staged) = tempfile('output-XXXXXXXX', DIR => $work_dir, UNLINK => 0);
    close $fh;
    push @pending_outputs, { staged => $staged, destination => $destination };
    return $staged;
}

sub publish_outputs {
    if ($dry_run) {
        print "[PREVIEW] Would write $_->{destination}\n" for @pending_outputs;
        return;
    }
    # Prepare every replacement before publishing any of them. Each rename is
    # atomic on a local filesystem; the complete set is not a single transaction.
    for my $output (@pending_outputs) {
        my $destination = $output->{destination};
        my $dir = dirname($destination);
        mkpath($dir) unless -d $dir;
        my ($fh, $temp) = tempfile('.reggen-XXXXXXXX', DIR => $dir, UNLINK => 0);
        close $fh;
        push @publish_files, $temp;
        copy($output->{staged}, $temp) or die "[ERROR] Cannot stage $destination: $!\n";
        chmod((stat($destination))[2] & 07777, $temp) if -f $destination;
        $output->{replacement} = $temp;
    }
    for my $output (@pending_outputs) {
        rename($output->{replacement}, $output->{destination})
            or die "[ERROR] Cannot replace $output->{destination}: $!\n";
        print "[INFO] Written: $output->{destination}\n";
    }
}

# -------------------------- Core Subroutine: Parse Register Definition TXT --------------------------
sub parse_input {
    open my $fh, '<:encoding(UTF-8)', $input_file or die "[ERROR] Failed to open input file: $! \n";
    my $line_num = 0;
    my %overlap_check;
    my @parsed_regs;
    my @logical_rows;
    my ($pending_row, $pending_line);

    my $override_mod = uc($default_module // '');
    if ($default_rtl_file ne "" || $default_base_addr ne "") {
        $default_module_map{$override_mod}->{rtl_file} = $default_rtl_file if $default_rtl_file ne "";
        $default_module_map{$override_mod}->{base_addr} = $default_base_addr if $default_base_addr ne "";
    }

    while (my $line = <$fh>) {
        $line_num++;
        $line =~ s/^\x{FEFF}// if $line_num == 1;
        chomp $line;
        $line =~ s/\r$//;
        my $raw_line = trim($line);
        next if $raw_line eq "";
        if ($raw_line =~ /^#/ || $raw_line =~ /^\/\//) {
            if (defined $pending_row) {
                push @logical_rows, { line_num => $pending_line, text => $pending_row };
                undef $pending_row;
            }
            next;
        }

        if ($raw_line =~ /^\|/) {
            my @physical_fields = split_table_row($raw_line);
            if (is_description_separator(@physical_fields)) {
                if (defined $pending_row) {
                    push @logical_rows, { line_num => $pending_line, text => $pending_row };
                    undef $pending_row;
                }
                next;
            }
            my $is_desc_continuation =
                @physical_fields >= 9 &&
                !grep { $_ ne "" } @physical_fields[0..7];

            if ($is_desc_continuation) {
                my $continuation = trim(join(" | ", @physical_fields[8..$#physical_fields]));
                die "[ERROR] Line $line_num: Description continuation is empty\n"
                    if $continuation eq "";
                die "[ERROR] Line $line_num: Description continuation has no preceding register row\n"
                    unless defined $pending_row;
                $pending_row =~ s/\s*\|\s*$//;
                $pending_row .= "<br>$continuation |";
                next;
            }

            if (defined $pending_row) {
                push @logical_rows, { line_num => $pending_line, text => $pending_row };
            }
            $pending_row = $raw_line;
            $pending_line = $line_num;
        } elsif (!defined $pending_row) {
            $pending_row = $raw_line;
            $pending_line = $line_num;
        } else {
            $pending_row =~ s/\s*\|\s*$//;
            $pending_row .= "<br>$raw_line |";
        }
    }
    close $fh;

    if (defined $pending_row) {
        push @logical_rows, { line_num => $pending_line, text => $pending_row };
    }

    foreach my $logical (@logical_rows) {
        my $line_num = $logical->{line_num};
        my $raw_line = $logical->{text};

        my @fields;
        if ($raw_line =~ /\|/) {
            @fields = split_table_row($raw_line);
            next if @fields && !grep { $_ !~ /^:?-+:?$/ } @fields;
            if (@fields > 9) {
                my @fixed = @fields[0..7];
                push @fixed, join(" | ", @fields[8..$#fields]);
                @fields = @fixed;
            }
        } else {
            @fields = split(/\s+/, $raw_line, 9);
            @fields = map { trim($_) } @fields;
        }
        next unless @fields;
        next if lc($fields[0]) eq "module";

        if (scalar @fields < 7) {
            die "[ERROR] Line $line_num format error! Expected at least 7 columns: Module Offset BitRange RegName Reset Access Interface [Owner] [Description]\n";
        }

        my ($mod, $offset, $input_bit_range, $raw_field, $default_val, $attr, $raw_if) = @fields[0..6];
        my $owner = $fields[7] // "";
        my $desc = scalar(@fields) > 8 ? join(" | ", @fields[8..$#fields]) : "";
        $mod = uc(trim($mod));
        $offset = normalize_offset_literal($offset);
        $input_bit_range = trim($input_bit_range);
        $raw_field = trim($raw_field);
        $default_val = normalize_reset_literal($default_val);
        $attr = uc(trim($attr));
        $raw_if = trim($raw_if);
        $owner = trim($owner);
        $desc = trim($desc);

        die "[ERROR] Line $line_num: Invalid Module identifier\n" unless $mod =~ /^[A-Z_][A-Z0-9_]*$/;
        die "[ERROR] Line $line_num: Offset is empty\n" if $offset eq "";
        my ($msb, $lsb);
        if ($input_bit_range =~ /^\[(\d+)\]$/) {
            $msb = $1 + 0;
            $lsb = $msb;
        } elsif ($input_bit_range =~ /^\[(\d+):(\d+)\]$/) {
            $msb = $1 + 0;
            $lsb = $2 + 0;
            die "[ERROR] Line $line_num: BitRange MSB must be greater than or equal to LSB: $input_bit_range\n"
                if $msb < $lsb;
        } else {
            die "[ERROR] Line $line_num: BitRange must use [bit] or [msb:lsb] format: $input_bit_range\n";
        }
        my $width = $msb - $lsb + 1;
        die "[ERROR] Line $line_num: RegName is empty\n" if $raw_field eq "";
        die "[ERROR] Line $line_num: Register $raw_field attribute is illegal, only supports RW/RO/W1C/W1S\n" unless $attr =~ /^(RW|RO|W1C|W1S)$/;

        my $mapping = $default_module_map{$mod} // {};
        $module2rtl{$mod} = $mapping->{rtl_file} if defined $mapping->{rtl_file};
        $module_base_addr{$mod} = normalize_offset_literal($mapping->{base_addr} // '0');
        die "[ERROR] No RTL mapping for module $mod\n" if !$skip_inject && !defined $module2rtl{$mod};

        my $is_reserved = is_reserved_name($raw_field);
        my ($raw_name, $if_sig_name);
        if ($raw_field =~ /^([^\(]+)\(([^\)]+)\)$/) {
            $raw_name = trim($1);
            $if_sig_name = trim($2);
        } else {
            $raw_name = $raw_field;
            $if_sig_name = $raw_field;
        }
        for my $name ($raw_name, $if_sig_name) {
            die "[ERROR] Line $line_num: Invalid register identifier $name\n"
                unless $name =~ /^[A-Za-z_][A-Za-z0-9_]*(?:\[\d+:\d+\])?$/;
        }
        if ($default_val !~ /^(?:n\/a|todo)$/i) {
            my $reset = Math::BigInt->new($default_val);
            die "[ERROR] Line $line_num: Reset exceeds field width\n"
                if $reset->bcmp(Math::BigInt->new(2)->bpow($width)) >= 0;
        } elsif ($attr ne 'RO') {
            die "[ERROR] Line $line_num: Writable fields require a numeric reset\n";
        }

        my $is_manual_split_name = $raw_name =~ /^\w+\[\d+:\d+\]$/ ? 1 : 0;
        my $is_auto_wide_reg =
            !$is_reserved && !$is_manual_split_name && $width > 32 && $lsb == 0;

        if ($msb > 31 && !$is_auto_wide_reg) {
            die "\n[FATAL ERROR - BitRange Overflow]\n" .
                "Line $line_num: Module $mod offset $offset field '$raw_field' uses $input_bit_range outside [31:0].\n" .
                "Normal fields, manual wide-register segments, and Reserved rows must stay within one 32-bit offset.\n" .
                "A non-Reserved automatic wide register may use [N:0] with N >= 32.\n\n";
        }

        my %reg;
        $reg{line_num}   = $line_num;
        $reg{module}     = $mod;
        $reg{offset}     = $offset;
        $reg{lsb}        = $lsb;
        $reg{wd}         = $width + 0;
        $reg{msb}        = $msb;
        $reg{input_bit_range} = $input_bit_range;
        $reg{raw_name}   = $raw_name;
        $reg{base_name}  = $raw_name;
        $reg{if_sig_name} = $if_sig_name;
        $reg{if_base_name} = $if_sig_name;
        $reg{bit_range} = "";
        $reg{bit_msb} = 0;
        $reg{bit_lsb} = 0;
        $reg{is_manual_split} = 0;
        $reg{is_reserved} = $is_reserved;

        if ($raw_name =~ /^(\w+)\[(\d+):(\d+)\]$/) {
            $reg{base_name} = $1;
            $reg{bit_msb} = $2 + 0;
            $reg{bit_lsb} = $3 + 0;
            $reg{bit_range} = "[$reg{bit_msb}:$reg{bit_lsb}]";
            $reg{is_manual_split} = 1;
        }
        if ($if_sig_name =~ /^(\w+)\[(\d+):(\d+)\]$/) {
            $reg{if_base_name} = $1;
        }

        $reg{name}       = $raw_name;
        $reg{name_upper} = sanitize_macro_name($raw_name);
        $reg{default}    = $default_val;
        $reg{attr}       = $attr;
        $reg{owner}      = $owner;
        $reg{desc}       = $desc;
        $reg{interface}  = $raw_if;
        $reg{if_type}    = "";
        $reg{if_instance} = "";
        $reg{is_no_if}   = 1;

        if (!$is_reserved && $raw_if ne "" && $raw_if ne "-" && $raw_if !~ /^(n\/a|na)$/i) {
            $reg{is_no_if} = 0;
            if ($raw_if =~ /^([^:]+):([^:]+)$/) {
                $reg{if_type}     = trim($1);
                $reg{if_instance} = trim($2);
            } else {
                $reg{if_type}     = $raw_if;
                $reg{if_instance} = $raw_if;
            }
            if ($reg{if_type} !~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
                die "[ERROR] Line $line_num: Invalid interface type $reg{if_type}\n";
            }
            if ($reg{if_instance} !~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
                die "[ERROR] Line $line_num: Invalid interface instance $reg{if_instance}\n";
            }
            $reg{sig_path} = "$reg{if_instance}.$reg{if_sig_name}";
        } else {
            $reg{interface} = "-" if $is_reserved || $raw_if eq "";
            $reg{sig_path} = $raw_name;
        }

        if ($reg{is_no_if}) {
            if ($reg{wd} == 1) {
                $reg{port_decl} = $reg{attr} eq "RW" || $reg{attr} eq "W1C" || $reg{attr} eq "W1S" ? "output reg $reg{name}" : "input $reg{name}";
            } else {
                $reg{port_decl} = $reg{attr} eq "RW" || $reg{attr} eq "W1C" || $reg{attr} eq "W1S" ? "output reg [".($reg{wd}-1).":0] $reg{name}" : "input [".($reg{wd}-1).":0] $reg{name}";
            }
        } else {
            $reg{port_decl} = "";
        }

        my $base_offset_num = hex($reg{offset});
        for my $bit ($reg{lsb} .. $reg{msb}) {
            my $word_offset = int($bit / 32) * 4;
            my $actual_offset_num = $base_offset_num + $word_offset;
            my $actual_offset_hex = normalize_offset_literal(sprintf("0x%x", $actual_offset_num));
            my $relative_bit = $bit % 32;

            if (exists $overlap_check{$reg{module}}{$actual_offset_hex}{$relative_bit}) {
                my $conflict = $overlap_check{$reg{module}}{$actual_offset_hex}{$relative_bit};
                die "\n[FATAL ERROR - Physical address overlap]\nLine $line_num: $reg{module} $actual_offset_hex bit [$relative_bit] is occupied by '$conflict' and '$raw_name'\n\n";
            }
            $overlap_check{$reg{module}}{$actual_offset_hex}{$relative_bit} = $raw_name;
        }

        push @parsed_regs, \%reg unless $is_reserved;
    }

    my %name_check;
    my %name_count;
    foreach my $reg (@parsed_regs) {
        my $name_key = "$reg->{module}|" . lc($reg->{name});
        $name_count{$name_key}++;
        my $inst = $reg->{is_no_if} ? "" : $reg->{if_instance};
        if (exists $name_check{$name_key}{$inst}) {
            my $first_line = $name_check{$name_key}{$inst};
            die "\n[FATAL ERROR - Same Register Name]\nLine $reg->{line_num}: Register '$reg->{name}' already exists in Module $reg->{module} with the same interface instance '$inst' (first declared at line $first_line).\n" .
                "Please distinguish repeated registers by Interface instance, for example interface_type:instance0 and interface_type:instance1.\n\n";
        }
        $name_check{$name_key}{$inst} = $reg->{line_num};
    }

    foreach my $reg (@parsed_regs) {
        my $name_key = "$reg->{module}|" . lc($reg->{name});
        if ($name_count{$name_key} > 1) {
            my $inst = $reg->{if_instance} || "no_if";
            $reg->{name_upper} = sanitize_macro_name($inst . "_" . $reg->{name});
        }
        push @orig_regs, { %$reg };
        push @regs, $reg;
    }

    @orig_regs = sort { $a->{module} cmp $b->{module} || hex($a->{offset}) <=> hex($b->{offset}) || $a->{lsb} <=> $b->{lsb} } @orig_regs;
    @regs = sort { $a->{module} cmp $b->{module} || hex($a->{offset}) <=> hex($b->{offset}) || $a->{lsb} <=> $b->{lsb} } @regs;
    die "[ERROR] No register definitions parsed!\n" unless scalar @regs > 0;

    foreach my $mod (keys %module2rtl) {
        $module_base_addr{$mod} //= "0x00000000";
    }
    print "[INFO] Input file parsing completed, total ".scalar(@regs)." original registers parsed\n";
    foreach my $mod_name (sort keys %module_base_addr) {
        print "[INFO] Mapping: module=$mod_name, rtl=".($module2rtl{$mod_name} // "").", base=$module_base_addr{$mod_name}\n";
    }
}

# -------------------------- Core Subroutine: Open Module Temporary File Handles --------------------------
sub open_module_temp {
    my $mod = shift;
    return if exists $module_temp{$mod};
    # Define temporary file paths
    my $def_temp = "$work_dir/${mod}_default.temp";
    my $wr_temp  = "$work_dir/${mod}_write.temp";
    my $rd_temp  = "$work_dir/${mod}_read.temp";
    my $port_temp = "$work_dir/${mod}_port.temp"; # New: Port declaration temporary file
    # Open file handles (overwrite mode)
    open my $def_fh, '>', $def_temp or die "[ERROR] Failed to create default value temporary file: $! \n";
    open my $wr_fh,  '>', $wr_temp  or die "[ERROR] Failed to create write operation temporary file: $! \n";
    open my $rd_fh,  '>', $rd_temp  or die "[ERROR] Failed to create read operation temporary file: $! \n";
    open my $port_fh, '>', $port_temp or die "[ERROR] Failed to create port declaration temporary file: $! \n";
    # Store handles
    $module_temp{$mod} = {
        def => $def_fh,
        wr  => $wr_fh,
        rd  => $rd_fh,
        port => $port_fh # New: Port handle
    };
    print "[INFO] Created temporary files for module $mod\n";
}

# -------------------------- Core Subroutine: Flush and Close All Temporary File Handles --------------------------
sub flush_close_temp_handles {
    foreach my $mod (keys %module_temp) {
        print "[INFO] Flushing and closing temporary file handles for module $mod...\n";
        # Flush and close default value handle
        if (exists $module_temp{$mod}->{def}) {
            my $fh = $module_temp{$mod}->{def};
            $fh->flush(); # Fix: Use IO::Handle flush method
            close $fh;
            delete $module_temp{$mod}->{def};
        }
        # Flush and close write operation handle
        if (exists $module_temp{$mod}->{wr}) {
            my $fh = $module_temp{$mod}->{wr};
            $fh->flush(); # Fix: Use IO::Handle flush method
            close $fh;
            delete $module_temp{$mod}->{wr};
        }
        # Flush and close read operation handle
        if (exists $module_temp{$mod}->{rd}) {
            my $fh = $module_temp{$mod}->{rd};
            $fh->flush(); # Fix: Use IO::Handle flush method
            close $fh;
            delete $module_temp{$mod}->{rd};
        }
        # Flush and close port declaration handle
        if (exists $module_temp{$mod}->{port}) {
            my $fh = $module_temp{$mod}->{port};
            $fh->flush(); # Fix: Use IO::Handle flush method
            close $fh;
            delete $module_temp{$mod}->{port};
        }
    }
    print "[INFO] All temporary file handles flushed and closed, content written to disk!\n\n";
}

# -------------------------- Core Subroutine: Auto-Split Wide Registers --------------------------
sub split_wide_register {
    my @new_regs; # Store final split register list
    my $split_total = 0; # Count split registers

    print "[INFO] Starting automatic splitting of wide registers...\n";
    foreach my $reg (@regs) {
        my $mod = $reg->{module};
        my $orig_offset = $reg->{offset};
        my $orig_lsb = $reg->{lsb};
        my $orig_wd = $reg->{wd};
        my $orig_name = $reg->{name};
        my $orig_default = $reg->{default};
        my $orig_attr = $reg->{attr};
        my $orig_interface = $reg->{interface}; # Inherit interface attribute
        my $orig_owner = $reg->{owner};
        my $line_num = $reg->{line_num} // "Unknown";
		# -------------------------- Skip manual splited register ------------
		if ($reg->{is_manual_split}) {
			push @new_regs, $reg;
			next;
		}
        # -------------------------- Legality Check --------------------------
        # Check offset must be 4-byte aligned (IC register address specification)
        my $offset_num = hex($orig_offset);
        if ($offset_num % 4 != 0) {
            die "[ERROR] Register $orig_name offset $orig_offset invalid (wide registers must be 4-byte aligned)\n";
        }
        # Wide registers must have lsb=0 (no offset lsb for cross-address registers)
        if ($orig_wd > 32 && $orig_lsb != 0) {
            die "[ERROR] Register $orig_name width $orig_wd>32bit, LSB must be 0 (current LSB=$orig_lsb)\n";
        }

        # -------------------------- Normal Registers (≤32bit) Retain Directly --------------------------
        if ($orig_wd <= 32) {
            push @new_regs, $reg;
            next;
        }

        # -------------------------- Wide Register Split Logic --------------------------
        print "[INFO] Detected wide register: $mod.$orig_name, total width $orig_wd, start offset $orig_offset\n";
        my $remain_wd = $orig_wd; # Remaining unsplit width
        my $current_offset = $orig_offset; # Current sub-register offset
        my $current_bit_start = 0; # Start bit of current sub-register (relative to original)
        my $split_cnt = 0; # Number of split sub-registers

        # Process default value
        my $default_hex = $orig_default;
        $default_hex =~ s/^0x//;
        my $hex_length = int(($orig_wd + 3) / 4);
        $default_hex = sprintf("%0${hex_length}s", $default_hex);
        $default_hex =~ s/ /0/g; # Replace spaces with 0

        # Loop split until remaining width is 0
        while ($remain_wd > 0) {
            my $sub_wd = $remain_wd >= 32 ? 32 : $remain_wd; # Sub-register width
            my $sub_bit_end = $current_bit_start + $sub_wd - 1; # End bit of current sub-register (relative to original register)
            $split_cnt++;
            $split_total++;

            # -------------------------- Sub-Register Default Value Split --------------------------
            my $sub_default = $orig_default;
            if ($orig_default !~ /n\/a|todo/i) {
                # Slice hex string from right to left: 8 chars = 32bit each
                my $digits = int(($sub_wd + 3) / 4);
                my $start_pos = $hex_length - ($current_bit_start / 4) - $digits;
                my $sub_hex = substr($default_hex, $start_pos, $digits);
                $sub_hex =~ s/^0*//;
                $sub_hex = $sub_hex eq '' ? '0' : $sub_hex;
                $sub_default = "0x$sub_hex";
            }

            # -------------------------- Sub-Register Name and Macro Name Generation --------------------------
            my $sub_name = "${orig_name}[${sub_bit_end}:${current_bit_start}]";
            my $sub_name_upper = $reg->{name_upper}."_${sub_bit_end}_${current_bit_start}";
            my $sub_if_sig_name = $reg->{if_sig_name} . "[${sub_bit_end}:${current_bit_start}]"; # 继承接口名

            # -------------------------- Sub-Register Info Construction (Inherit interface attribute) --------------------------
            my %sub_reg = (
                line_num    => $line_num,
                module      => $mod,
                offset      => $current_offset,
                lsb         => 0, # LSB fixed to 0 in independent offset
                wd          => $sub_wd,
                name        => $sub_name,
                name_upper  => $sub_name_upper,
                raw_name    => $sub_name,
                base_name   => $reg->{base_name},
                if_base_name => $reg->{if_base_name},
                default     => $sub_default,
                attr        => $orig_attr,
                owner       => $orig_owner,
                desc        => $reg->{desc},
                interface   => $reg->{interface},
                if_type     => $reg->{if_type},
                # Inherit interface/port attributes
                if_instance => $reg->{if_instance},
                # Fix: Concatenate path based on if_instance existence
                if_sig_name => $sub_if_sig_name,
                sig_path    => $reg->{if_instance} ? "$reg->{if_instance}.$sub_if_sig_name" : $sub_name,
                msb         => $sub_wd - 1,
                bit_msb     => $sub_bit_end,
                bit_lsb     => $current_bit_start,
                is_manual_split => 1,
                is_reserved => 0,
                is_no_if    => $reg->{is_no_if},
                port_decl   => "" # No separate port for split wide registers (original register already generated)
            );

            # Add to new register list
            push @new_regs, \%sub_reg;
            print "[INFO]  └─ Split to create sub-register: $sub_name, width $sub_wd, offset $current_offset, default $sub_default\n";

            # -------------------------- Update Next Sub-Register Parameters --------------------------
            $remain_wd -= $sub_wd;
            $current_bit_start += $sub_wd;
            my $current_offset_num = hex($current_offset);
            $current_offset_num += 4; # Offset +0x4 (4 bytes) each time
            $current_offset = normalize_offset_literal(sprintf("0x%x", $current_offset_num));
        }
        print "[INFO] Register $orig_name split completed, total $split_cnt sub-registers generated\n\n";
    }

    # Replace original list with split new register list
    @regs = @new_regs;
    # Re-sort by module + offset
    @regs = sort { $a->{module} cmp $b->{module} || hex($a->{offset}) <=> hex($b->{offset}) || $a->{lsb} <=> $b->{lsb} } @regs;

    print "[INFO] Wide register split processing completed, total $split_total wide registers split, final valid register count: ".scalar(@regs)."\n\n";
}

# -------------------------- Core Subroutine: Generate Offset Macro Definitions --------------------------
sub gen_offset_macro {
    open my $mf, '>>', $output_macro or die "[ERROR] Failed to write to macro file: $! \n";
    print $mf "//offset config\n";
    # Unified initial value as string Undefined, add deduplication hash
    my $pre_module = "Undefined";
    my $pre_offset = "Undefined";
    my %generated_offsets;

    foreach my $reg (@regs) {
        my ($mod, $off) = ($reg->{module}, $reg->{offset});
        my $off_hex = $off;
        $off_hex =~ s/^0x//;
        my $offset_key = "$mod|$off_hex";

        # Generate macro for previous offset when module/offset changes
        if ($pre_module ne "Undefined" && ($pre_module ne $mod || $pre_offset ne $off)) {
            my $pre_off_hex = $pre_offset;
            $pre_off_hex =~ s/^0x//;
            my $pre_offset_key = "$pre_module|$pre_off_hex";
            if (!exists $generated_offsets{$pre_offset_key}) {
                print $mf "`define ${pre_module}_REG_${pre_off_hex}_OFFSET 'h$pre_off_hex\n";
                $generated_offsets{$pre_offset_key} = 1;
            }
        }
        # Update previous variables
        $pre_module = $mod;
        $pre_offset = $off;
    }

    # Fallback to generate macro for last offset
    if ($pre_module ne "Undefined" && $pre_offset ne "Undefined") {
        my $last_off_hex = $pre_offset;
        $last_off_hex =~ s/^0x//;
        my $last_offset_key = "$pre_module|$last_off_hex";
        if (!exists $generated_offsets{$last_offset_key}) {
            print $mf "`define ${pre_module}_REG_${last_off_hex}_OFFSET 'h$last_off_hex\n";
            $generated_offsets{$last_offset_key} = 1;
        }
    }

    print $mf "\n";
    close $mf;
    print "[INFO] Offset macro definitions generated, total ".scalar(keys %generated_offsets)." offset macros\n";
}

# -------------------------- Core Subroutine: Generate Default Value Macros and Temporary Files --------------------------
sub gen_default_macro {
    open my $mf, '>>', $output_macro or die "[ERROR] Failed to write to macro file: $! \n";
    print $mf "//Config and design specific programmable registers\n";
    my %generated_defs;

    foreach my $reg (@regs) {
        next unless $reg->{attr} =~ /^(RW|W1C|W1S)$/;
        next if $reg->{default} =~ /n\/a|todo/i;

        my $name_upper = sanitize_macro_name($reg->{name_upper});
        my $mod_upper = uc($reg->{module});
        my $def_key = "$mod_upper|$name_upper";
        next if exists $generated_defs{$def_key};
        $generated_defs{$def_key} = 1;

        my $def_hex = $reg->{default};
        $def_hex =~ s/^0x//;
        print $mf "`define ${mod_upper}_${name_upper}_DEF 'h$def_hex\n";
        open_module_temp($reg->{module});
        print { $module_temp{$reg->{module}}->{def} } "    $reg->{sig_path} <= `${mod_upper}_${name_upper}_DEF;\n";
    }
    print $mf "\n";
    close $mf;
    print "[INFO] Default value macros and module temporary files generated\n";
}

# -------------------------- Core Subroutine: Generate Read/Write Operation Macros & Temporary Files --------------------------
sub gen_rw_macro {
    open my $mf, '>>', $output_macro or die "[ERROR] Failed to write to macro file: $! \n";
    print $mf "//Register operating\n";
    
    # Initialize configuration hashes
    my %wr_cfg;  # Write config: key=module|offset, value=write statement
    my %rd_cfg;  # Read config: key=module|offset, value=read statement
    my $pre_module = "Undefined";
    my $pre_offset = "Undefined";
    my $pre_csr    = "Undefined";

    foreach my $reg (@regs) {
        my ($mod, $off, $csr, $lsb, $wd, $attr) = ($reg->{module}, $reg->{offset}, $reg->{name}, $reg->{lsb}, $reg->{wd}, $reg->{attr});
        my $end_bit = $lsb + $wd - 1;
        my $off_hex = $off;
        $off_hex =~ s/^0x//;
        my $cfg_key = "$mod|$off";  # Strong binding key: module + offset

        # default 0 for every new offset
        if (!exists $rd_cfg{$cfg_key}) {
            $rd_cfg{$cfg_key} = "$apb_interface.prdata <= 32'd0; ";
        }
        $wr_cfg{$cfg_key} //= "";

        # Process and write config for previous offset when module/offset changes
        if ($pre_module ne "Undefined" && ($pre_module ne $mod || $pre_offset ne $off)) {
            my $pre_cfg_key = "$pre_module|$pre_offset";
            my $pre_off_hex = $pre_offset;
            $pre_off_hex =~ s/^0x//;
            
            # Process write config for previous offset
            if (exists $wr_cfg{$pre_cfg_key} && $wr_cfg{$pre_cfg_key} ne "") {
                print $mf "`define ${pre_module}_REG_${pre_off_hex}_OFFSET_WR `${pre_module}_REG_${pre_off_hex}_OFFSET : begin $wr_cfg{$pre_cfg_key} end\n";
                open_module_temp($pre_module);
                print { $module_temp{$pre_module}->{wr} } "    `${pre_module}_REG_${pre_off_hex}_OFFSET : begin $wr_cfg{$pre_cfg_key} end\n";
                delete $wr_cfg{$pre_cfg_key};
            }
            # Process read config for previous offset
            if (exists $rd_cfg{$pre_cfg_key} && $rd_cfg{$pre_cfg_key} ne "") {
                print $mf "`define ${pre_module}_REG_${pre_off_hex}_OFFSET_RD `${pre_module}_REG_${pre_off_hex}_OFFSET : begin $rd_cfg{$pre_cfg_key} end\n";
                open_module_temp($pre_module);
                print { $module_temp{$pre_module}->{rd} } "    `${pre_module}_REG_${pre_off_hex}_OFFSET : begin $rd_cfg{$pre_cfg_key} end\n";
                delete $rd_cfg{$pre_cfg_key};
            }
            print $mf "\n" if $pre_module ne "Undefined";
        }

        # Write current register logic to current offset config (use interface path)
        if ($attr eq "RW") {
            $wr_cfg{$cfg_key} .= "$reg->{sig_path} <= $apb_interface.pwdata[$end_bit:$lsb]; ";
            $rd_cfg{$cfg_key} .= "$apb_interface.prdata[$end_bit:$lsb] <= $reg->{sig_path}; ";
        } elsif ($attr eq "W1C") {
            $wr_cfg{$cfg_key} .= "$reg->{sig_path} <= $reg->{sig_path} & ~$apb_interface.pwdata[$end_bit:$lsb]; ";
            $rd_cfg{$cfg_key} .= "$apb_interface.prdata[$end_bit:$lsb] <= $reg->{sig_path}; ";
        } elsif ($attr eq "W1S") {
            $wr_cfg{$cfg_key} .= "$reg->{sig_path} <= $reg->{sig_path} | $apb_interface.pwdata[$end_bit:$lsb]; ";
            $rd_cfg{$cfg_key} .= "$apb_interface.prdata[$end_bit:$lsb] <= $reg->{sig_path}; ";
        } elsif ($attr eq "RO") {
            $rd_cfg{$cfg_key} .= "$apb_interface.prdata[$end_bit:$lsb] <= $reg->{sig_path}; ";
        }

        # Update previous variables
        $pre_module = $mod;
        $pre_offset = $off;
        $pre_csr    = $csr;
    }

    # Fallback processing for last offset config
    if ($pre_module ne "Undefined" && $pre_offset ne "Undefined") {
        my $last_cfg_key = "$pre_module|$pre_offset";
        my $last_off_hex = $pre_offset;
        $last_off_hex =~ s/^0x//;
        # Process write config for last offset
        if (exists $wr_cfg{$last_cfg_key} && $wr_cfg{$last_cfg_key} ne "") {
            print $mf "`define ${pre_module}_REG_${last_off_hex}_OFFSET_WR `${pre_module}_REG_${last_off_hex}_OFFSET : begin $wr_cfg{$last_cfg_key} end\n";
            open_module_temp($pre_module);
            print { $module_temp{$pre_module}->{wr} } "    `${pre_module}_REG_${last_off_hex}_OFFSET : begin $wr_cfg{$last_cfg_key} end\n";
        }
        # Process read config for last offset
        if (exists $rd_cfg{$last_cfg_key} && $rd_cfg{$last_cfg_key} ne "") {
            print $mf "`define ${pre_module}_REG_${last_off_hex}_OFFSET_RD `${pre_module}_REG_${last_off_hex}_OFFSET : begin $rd_cfg{$last_cfg_key} end\n";
            open_module_temp($pre_module);
            print { $module_temp{$pre_module}->{rd} } "    `${pre_module}_REG_${last_off_hex}_OFFSET : begin $rd_cfg{$last_cfg_key} end\n";
        }
    }

    close $mf;
    print "[INFO] Read/write operation macros and module temporary files generated\n";
}

# -------------------------- Core Subroutine: Generate Port Declarations for Non-Interface Registers --------------------------
sub gen_port_declaration {
	print "[INFO] Starting generation of port declarations for non-interface registers...\n";
    # Grouping by module without interface register declaration
    my %mod_ports; 
    my %manual_split_merge;
    my %mod_interfaces;

    foreach my $reg (@regs) {
        # if its interface,log declaration and skip port process
        if (!$reg->{is_no_if}) {
            my $mod = $reg->{module};
            # default use modport s，format example：cfg_timer_if.s cfg_timer0_if
            my $if_decl = "$reg->{if_type}.s $reg->{if_instance}";
            $mod_interfaces{$mod}{$if_decl} = 1;
            next; 
        }
        
        # port process
        if ($reg->{is_manual_split}) {
            my $merge_key = $reg->{module} . "|" . $reg->{base_name};
            unless (exists $manual_split_merge{$merge_key}) {
                $manual_split_merge{$merge_key} = { module => $reg->{module}, name => $reg->{base_name}, min_lsb => $reg->{bit_lsb}, max_msb => $reg->{bit_msb}, attr => $reg->{attr} };
            } else {
                $manual_split_merge{$merge_key}->{min_lsb} = $reg->{bit_lsb} if $reg->{bit_lsb} < $manual_split_merge{$merge_key}->{min_lsb};
                $manual_split_merge{$merge_key}->{max_msb} = $reg->{bit_msb} if $reg->{bit_msb} > $manual_split_merge{$merge_key}->{max_msb};
            }
            next; 
        }
        my $mod = $reg->{module};
        push @{$mod_ports{$mod}}, $reg->{port_decl};
    }

    # wide port process
    foreach my $merge_key (sort keys %manual_split_merge) {
        my $info = $manual_split_merge{$merge_key};
        my $mod = $info->{module}; my $name = $info->{name}; my $total_wd = $info->{max_msb} - $info->{min_lsb} + 1; my $attr = $info->{attr};
        my $port_decl;
        if ($total_wd == 1) { $port_decl = $attr =~ /^(RW|W1C|W1S)$/ ? "output reg $name" : "input $name"; }
        else { $port_decl = $attr =~ /^(RW|W1C|W1S)$/ ? "output reg [".($total_wd-1).":0] $name" : "input [".($total_wd-1).":0] $name"; }
        push @{$mod_ports{$mod}}, $port_decl;
    }

    # merge port and interface
    my %all_mods = map { $_ => 1 } (keys %mod_ports, keys %mod_interfaces);

    foreach my $mod (keys %all_mods) {
        my @sorted_ports;
        
        # 1. unique port
        if (exists $mod_ports{$mod}) {
            my %unique_ports = map { $_ => 1 } @{$mod_ports{$mod}};
            push @sorted_ports, sort keys %unique_ports;
        }
        
        # 2. unique interface
        if (exists $mod_interfaces{$mod}) {
            push @sorted_ports, sort keys %{$mod_interfaces{$mod}};
        }
        
        next unless scalar @sorted_ports > 0;
        
        # declaration inject
        my $port_content = join(",\n    ", @sorted_ports);
        $port_content .= "," if $port_content ne ""; # add ","
        
        my $port_temp = "$work_dir/${mod}_port.temp";
        open my $port_fh, '>', $port_temp; print $port_fh $port_content; close $port_fh;
        #$module_temp{$mod}->{port} = $port_temp;
    }
}

# -------------------------- Core Subroutine: Find RTL Files --------------------------
sub find_rtl_file {
    my $rtl_name = shift;
    die "[ERROR] RTL mapping must be a basename\n"
        unless $rtl_name =~ /^[A-Za-z_][A-Za-z0-9_.-]*\.(?:sv|v)$/;
    die "[ERROR] RTL root is not a directory: $rtl_root\n" unless -d $rtl_root;
    my @found;
    find({ no_chdir => 1, wanted => sub {
        push @found, normalize_path($File::Find::name)
            if -f $_ && basename($_) eq $rtl_name;
    } }, $rtl_root);
    die "[ERROR] Ambiguous RTL target $rtl_name: @found\n" if @found > 1;
    return @found ? $found[0] : "";
}

sub inject_rtl {
    for my $mod (sort keys %module2rtl) {
        my $path = find_rtl_file($module2rtl{$mod});
        die "[ERROR] RTL file for module $mod not found\n" unless $path;
        open my $fh, '<:raw', $path or die "[ERROR] Cannot read $path: $!\n";
        my $content = do { local $/; <$fh> };
        close $fh;
        my $newline = $content =~ /\r\n/ ? "\r\n" : "\n";
        $content =~ s/\r\n/\n/g;
        my @markers = $content =~ /^[ \t]*\/\/\Q$marker_prefix\E(port|default|write|read)_(on|off)[ \t]*$/mg;
        die "[ERROR] Expected exactly four marker pairs in $path\n" unless @markers == 16;
        while (@markers) {
            my ($section, $state, $end_section, $end_state) = splice(@markers, 0, 4);
            die "[ERROR] Nested or misordered markers in $path\n"
                unless $section eq $end_section && $state eq 'on' && $end_state eq 'off';
        }
        for my $section (qw/port default write read/) {
            my $on = $marker_prefix . $section . '_on';
            my $off = $marker_prefix . $section . '_off';
            my $on_count = () = $content =~ /^[ \t]*\/\/\Q$on\E[ \t]*$/mg;
            my $off_count = () = $content =~ /^[ \t]*\/\/\Q$off\E[ \t]*$/mg;
            die "[ERROR] Missing or duplicate $section markers in $path\n"
                unless $on_count == 1 && $off_count == 1;
            my $temp = "$work_dir/${mod}_${section}.temp";
            open my $part_fh, '<:raw', $temp or die "[ERROR] Missing generated $section content: $!\n";
            my $part = do { local $/; <$part_fh> } // '';
            close $part_fh;
            $part =~ s/\r\n/\n/g;
            $part .= "\n" if $part ne '' && $part !~ /\n$/;
            my $changed = $content =~ s/(^[ \t]*\/\/\Q$on\E[ \t]*\n).*?(^[ \t]*\/\/\Q$off\E[ \t]*$)/$1$part$2/sm;
            die "[ERROR] Invalid $section marker region in $path\n" unless $changed == 1;
        }
        $content =~ s/\n/$newline/g;
        my $staged = stage_output($path);
        open my $out, '>:raw', $staged or die "[ERROR] Cannot stage RTL: $!\n";
        print $out $content;
        close $out or die "[ERROR] Cannot close staged RTL: $!\n";
        print "[PREVIEW] $path\n$content\n" if $dry_run;
    }
}

# -------------------------- Core Subroutine: Generate SystemVerilog Interface --------------------------
sub gen_register_interface {
    print "[INFO] Starting generation of register interface file...\n";
    # Group registers by interface name
    my %if_groups;
		my %base_reg_merge;
    my %if_reg_check; # Duplicate register check
    my $if_count = 0;

    # Traverse original unsplit registers, group by interface
    foreach my $reg (@orig_regs) {
        my $if_type = $reg->{if_type} // "";
        my $if_sig_name = $reg->{if_sig_name};
        my $if_base_name = $reg->{if_base_name};
        my $is_manual_split = $reg->{is_manual_split};
		my $reg_attr = $reg->{attr};

        # Filter rules: skip empty, N/A/NA/n/a/na
        next if $if_type eq "" || $if_type =~ /^(n\/a|na)$/i;


		# process manual spilted registers
		if ($is_manual_split) {
            my $merge_key = "$if_type|$if_base_name";
			    if (!exists $base_reg_merge{$merge_key}) {
					$base_reg_merge{$merge_key} = {
							base_name => $if_base_name,
							total_wd => 0,
							max_msb => 0,
							min_lsb => 0,
							attr => $reg_attr
					};
				}
				# update wd range
				$base_reg_merge{$merge_key}->{max_msb} = $reg->{bit_msb} if $reg->{bit_msb} > $base_reg_merge{$merge_key}->{max_msb};
				$base_reg_merge{$merge_key}->{min_lsb} = $reg->{bit_lsb} if $reg->{bit_lsb} < $base_reg_merge{$merge_key}->{min_lsb};
				$base_reg_merge{$merge_key}->{total_wd} = $base_reg_merge{$merge_key}->{max_msb} - $base_reg_merge{$merge_key}->{min_lsb} + 1;
				next;
		}
        # Duplicate register check
        next if exists $if_reg_check{$if_type}{$if_sig_name};
        $if_reg_check{$if_type}{$if_sig_name} = 1;
        
        $if_groups{$if_type} //= { rw_regs => [], ro_regs => [] };
        my $reg_info = { name => $if_sig_name, wd => $reg->{wd} };
        $reg_attr =~ /^(RW|W1C|W1S)$/ ? push @{$if_groups{$if_type}->{rw_regs}}, $reg_info : push @{$if_groups{$if_type}->{ro_regs}}, $reg_info;
    }

    foreach my $merge_key (sort keys %base_reg_merge) {
        my ($if_type, $if_base_name) = split /\|/, $merge_key;
        my $merge_info = $base_reg_merge{$merge_key};
        
        next if exists $if_reg_check{$if_type}{$if_base_name};
        $if_reg_check{$if_type}{$if_base_name} = 1;
        
        $if_groups{$if_type} //= { rw_regs => [], ro_regs => [] };
        my $reg_info = { name => $if_base_name, wd => $merge_info->{total_wd} };
        $merge_info->{attr} =~ /^(RW|W1C|W1S)$/ ? push @{$if_groups{$if_type}->{rw_regs}}, $reg_info : push @{$if_groups{$if_type}->{ro_regs}}, $reg_info;
    }
    # No valid interfaces found, print warning and exit
    unless (scalar keys %if_groups) {
        print "[WARN] No valid interface configurations parsed, skipping interface file generation\n\n";
        return;
    }

    # Generate interface.sv file
    open my $if_fh, '>', $interface_output or die "[ERROR] Failed to create interface file: $! \n";
    # Write file header
    print $if_fh "// ==============================================================\n";
    print $if_fh "// Auto-generated register interface file, do not modify manually\n";
    print $if_fh "// Rule: modport m (hardware consumer): RW=input, RO=output\n";
    print $if_fh "// Rule: modport s (register block): RW=output, RO=input\n";
    print $if_fh "// ==============================================================\n";
    print $if_fh "`timescale 1ns/1ps\n\n";

    # Traverse each interface to generate definitions
    foreach my $if_name (sort keys %if_groups) {
        my $rw_regs = $if_groups{$if_name}->{rw_regs};
        my $ro_regs = $if_groups{$if_name}->{ro_regs};
				my $total_regs = scalar(@$rw_regs) + scalar(@$ro_regs);
				# skip empty interface
				if ($total_regs == 0) {
						print "[WARN] interface $if_name has no valid register, skip generation.\n";
						next;
				}
        print $if_fh "\n" if $if_count > 0;
        $if_count++;
        print "[INFO] Generating interface: $if_name, contains RW registers ".scalar(@$rw_regs).", contains RO registers ".scalar(@$ro_regs)."\n";

        # Start interface definition
        print $if_fh "interface $if_name;\n";
        print $if_fh "// Register signal declarations\n";

        # Generate signal declaration (rw registers)
        foreach my $reg (@$rw_regs) {
            my $name = $reg->{name};
            my $wd = $reg->{wd};
            if ($wd == 1) {
                print $if_fh "    logic $name;\n";
            } else {
                print $if_fh "    logic [".($wd-1).":0] $name;\n";
            }
        }

        # Generate signal declaration (ro registers)
        foreach my $reg (@$ro_regs) {
            my $name = $reg->{name};
            my $wd = $reg->{wd};
            if ($wd == 1) {
                print $if_fh "    logic $name;\n";
            } else {
                print $if_fh "    logic [".($wd-1).":0] $name;\n";
            }
        }

        print $if_fh "\n";

        # Generate modport m: all output, used by register driver side
        print $if_fh "// Register driver side modport (used by *_domain_misc.sv)\n";
        print $if_fh "    modport m (\n";
        my @m_ports;
				# rw registers
        foreach my $reg (@$rw_regs) {
            push @m_ports, "        input $reg->{name}";
        }
				# ro registers
        foreach my $reg (@$ro_regs) {
            push @m_ports, "        output $reg->{name}";
        }
				# avoid empty modport
				if (scalar(@m_ports) > 0) {
						print $if_fh join(",\n", @m_ports)."\n";
				} else {
						print $if_fh "    );\n\n";
				}
				print $if_fh "    );\n\n";

        # Generate modport s: all input, used by external consumer side
        print $if_fh "// Register consumer side modport (used by external modules)\n";
        print $if_fh "    modport s (\n";
        my @s_ports;
				# rw registers
        foreach my $reg (@$rw_regs) {
            push @s_ports, "        output $reg->{name}";
        }
				# ro registers
        foreach my $reg (@$ro_regs) {
            push @s_ports, "        input $reg->{name}";
        }
				# avoid empty modport
				if (scalar(@s_ports) > 0) {
						print $if_fh join(",\n", @s_ports)."\n";
				} else {
						print $if_fh "    );\n\n";
				}
				print $if_fh "    );\n\n";

        # End interface definition
        print $if_fh "endinterface\n";
    }

    close $if_fh;
    print "[INFO] Interface file generated, total $if_count interfaces created, output path: $interface_output\n\n";
}

# -------------------------- Core Subroutine: Generate Markdown Register Map --------------------------
sub gen_reg_map {
    print "[INFO] Generating Markdown register map...\n";
    open my $map_fh, '>:encoding(UTF-8)', $map_output or die "[ERROR] Failed to create map file: $! \n";

    my @headers = ("Base Offset", "Offset", "BitRange", "Field",
                   "Access", "Reset", "Owner", "Description");
    my @rows;

    foreach my $reg (@orig_regs) {
        my $base_addr = $module_base_addr{$reg->{module}} // "0x0";
        my $abs_offset = parse_int_literal($base_addr) + hex($reg->{offset});
        my $bit_range = $reg->{msb} == $reg->{lsb} ? "[$reg->{lsb}]" : "[$reg->{msb}:$reg->{lsb}]";
        my $reset = $reg->{default} // "0x0";
        my $owner = $reg->{owner} // "-";
        $owner = "-" if $owner eq "";
        my $desc = $reg->{desc} // "";
        $desc =~ s/\|/\//g;
        push @rows, [
            sprintf("0x%08X", $abs_offset),
            $reg->{offset},
            $bit_range,
            $reg->{name},
            $reg->{attr},
            $reset,
            $owner,
            $desc,
        ];
    }

    my @widths;
    foreach my $col (0 .. 6) {
        $widths[$col] = markdown_display_width($headers[$col]);
        foreach my $row (@rows) {
            my $cell_width = markdown_display_width($row->[$col]);
            $widths[$col] = $cell_width if $cell_width > $widths[$col];
        }
    }
    $widths[7] = $map_description_width;
    my $description_header_width = markdown_display_width($headers[7]);
    $widths[7] = $description_header_width
        if $description_header_width > $widths[7];

    my @header_cells;
    foreach my $col (0 .. 7) {
        push @header_cells, pad_markdown_cell($headers[$col], $widths[$col]);
    }
    print $map_fh "| " . join(" | ", @header_cells) . " |\n";

    my @separators = map { "-" x ($_ + 2) } @widths;
    print $map_fh "|" . join("|", @separators) . "|\n";

    foreach my $row (@rows) {
        my @description_lines =
            wrap_markdown_description($row->[7], $map_description_width);
        @description_lines = ("") unless @description_lines;

        for my $line_idx (0 .. $#description_lines) {
            my @cells;
            foreach my $col (0 .. 6) {
                my $value = $line_idx == 0 ? $row->[$col] : "";
                push @cells, pad_markdown_cell($value, $widths[$col]);
            }
            push @cells,
                pad_markdown_cell($description_lines[$line_idx], $widths[7]);
            print $map_fh "| " . join(" | ", @cells) . " |\n";
        }

        my @separator_cells =
            map { " " x ($widths[$_] + 2) } 0 .. 6;
        push @separator_cells, "-" x ($widths[7] + 2);
        print $map_fh "|" . join("|", @separator_cells) . "|\n";
    }

    close $map_fh;
    print "[INFO] Markdown register map generated, output path: $map_output\n\n";
}

# -------------------------- Core Subroutine: Generate verification C Header --------------------------
sub gen_sim_header {
    print "[INFO] Generating verification C header...\n";
    open my $hf, '>', $sim_header_output or die "[ERROR] Cannot create header：$! \n";

    print $hf "// ==============================================================\n";
    print $hf "// Automatically generated hardware register header file\n";
    print $hf "// Used for software drivers(C/C++) and verification environments\n";
    print $hf "// ==============================================================\n";
    print $hf "#ifndef __SIM_INC_H__\n";
    print $hf "#define __SIM_INC_H__\n\n";

    my $pre_module = "";
    foreach my $reg (@regs) {
        my $mod = $reg->{module};
        
        # Print Module Name and Base Address when switch
        if ($mod ne $pre_module) {
            my $base_addr = $module_base_addr{$mod} // "0x00000000 /* TODO: Fill Base Addr */";
            print $hf "// " . "="x50 . "\n";
            print $hf "// Module: $mod\n";
            print $hf "// Base Address: $base_addr\n";
            print $hf "// " . "="x50 . "\n";
            print $hf "#define ${mod}_BASE_ADDR $base_addr\n\n";
            $pre_module = $mod;
        }

        # clean macro name（replace [31:0] with _31_0_ to avoid syntax error）
        my $macro_name = $reg->{name_upper};
        $macro_name =~ s/\[(\d+):(\d+)\]/_$1_$2/g;
        $macro_name =~ s/[^A-Za-z0-9_]/_/g;

        my $off_hex = $reg->{offset};
        my $lsb     = $reg->{lsb};
        my $wd      = $reg->{wd};
        my $attr    = $reg->{attr};
        my $def     = $reg->{default};

        # Calculate bit mask：if width is N，the Mask is 2^N - 1
        my $mask = $wd >= 32 ? "0xffffffff" : sprintf("0x%x", (1 << $wd) - 1);

        # Print attribute of registers
        print $hf "// Register/Field: $reg->{name} ($attr)\n";
        print $hf "#define ${mod}_${macro_name}_OFFSET  $off_hex\n";
        print $hf "#define ${mod}_${macro_name}_SHIFT   $lsb\n";
        print $hf "#define ${mod}_${macro_name}_MASK    $mask\n";
        print $hf "#define ${mod}_${macro_name}_DEFAULT $def\n\n";
    }

    print $hf "#endif // __SIM_INC_H__\n";
    close $hf;
    print "[INFO] C header generated，output path：$sim_header_output\n\n";
}

# -------------------------- Main Execution Flow --------------------------
print "====================================\n";
print "RTL Register Auto-Generation & Injection Tool\n";
print "====================================\n";
&pre_check;
&parse_input;
&split_wide_register;
&gen_offset_macro;
&gen_default_macro;
&gen_rw_macro;
&flush_close_temp_handles;
&gen_port_declaration; # New: Generate port declarations for non-interface registers
if ($skip_inject) {
    print "[INFO] Generation-only mode; RTL code injection is disabled.\n";
} else {
    &inject_rtl;
}
&gen_register_interface; # Generate interface file
&gen_reg_map;
&gen_sim_header;
&publish_outputs;
print "====================================\n";
print $dry_run ? "[PREVIEW] Validation complete; no files published.\n" : "[SUCCESS] All operations completed!\n";
print "[SUCCESS] Output: $_->{destination}\n" for $dry_run ? () : @pending_outputs;
print "====================================\n";
exit 0;
