# =============================================================================
#  SystemVerilog lint / tooling helpers
#
#  Single source of truth = the *.sv files in $(RTL_DIR). The editor tooling
#  file lists (lint.f for Verilator, verible.filelist for the Verible language
#  server) are GENERATED from that, so you never hand-maintain them again.
#
#    make setup      scaffold a fresh repo: rtl/, tb/, and the dotfiles below
#    make lint       per-file Verilator lint (works on incomplete designs)
#    make elab       full-hierarchy lint from $(TOP) (once a top module exists)
#    make filelists  (re)generate lint.f + verible.filelist for the editor
#
#  `make setup` only ever *creates* missing files, so it is safe to re-run in a
#  repo that already has work in it -- nothing you have written gets clobbered.
#
#  All three keep the editor's lint.f / verible.filelist in sync as a side
#  effect, so running `make lint` after adding a file fixes the editor too.
# =============================================================================

RTL_DIR    ?= rtl
TB_DIR     ?= tb
VENV       ?= $(HOME)/.venv/hdlenv
STATE 	   ?= dump.surf.ron
# top module name used by `make elab` (keep comments off this line: make
# preserves the whitespace before a trailing `#`, which would corrupt $(TOP))
TOP        ?= packet_filter
VERILATOR  ?= verilator
VFLAGS     ?= -Wall -Wno-EOFNEWLINE   # override to relax further, e.g. add -Wno-UNUSEDSIGNAL

SOURCES    := $(wildcard $(RTL_DIR)/*.sv)
PACKAGES   := $(shell grep -lE '^[[:space:]]*package[[:space:]]' $(RTL_DIR)/*.sv 2>/dev/null)

LINT_F     := lint.f
VERIBLE_FL := verible.filelist

.PHONY: lint elab filelists setup

# ---- regenerate the editor/tool file lists ----------------------------------
filelists: $(LINT_F) $(VERIBLE_FL)

# Verilator command file: -y auto-resolves modules by filename, so only the
# packages need to be listed explicitly (auto-detected from the sources).
$(LINT_F): $(SOURCES) Makefile
	@{ \
	  echo '-I$(RTL_DIR)'; \
	  echo '-y $(RTL_DIR)'; \
	  echo '+libext+.sv+.v'; \
	  for p in $(PACKAGES); do echo "$$p"; done; \
	} > $@
	@echo "regenerated $@  (packages: $(PACKAGES))"

# Verible language-server project list: every source file, flat.
$(VERIBLE_FL): $(SOURCES) Makefile
	@printf '%s\n' $(SOURCES) > $@
	@echo "regenerated $@  ($(words $(SOURCES)) files)"

# ---- per-file lint (default; tolerates incomplete designs) ------------------
lint: filelists
	@rc=0; for f in $(SOURCES); do \
	  if ! out=$$($(VERILATOR) --lint-only $(VFLAGS) -Wno-MODDUP -f $(LINT_F) "$$f" 2>&1); then \
	    echo "--- $$f"; echo "$$out"; echo; rc=1; \
	  fi; \
	done; \
	if [ $$rc -eq 0 ]; then echo "lint: clean"; else echo "lint: issues found"; fi; \
	exit $$rc

# ---- full-hierarchy lint from the top (use once $(TOP) exists) --------------
elab: filelists
	$(VERILATOR) --lint-only $(VFLAGS) -Wno-MODDUP -f $(LINT_F) \
	  --top-module $(TOP) $(RTL_DIR)/$(TOP).sv

# =============================================================================
#  make setup -- scaffold a fresh repo
#
#  Every generated file is its own make target with no prerequisites, so an
#  existing file is simply "up to date" and is left alone. Contents are written
#  with $(file >), which needs no shell quoting: #, quotes and blank lines all
#  survive verbatim.
# =============================================================================

SETUP_FILES := $(TB_DIR)/common.py $(TB_DIR)/test_template.py \
               .gitignore .rules.verible_lint .vscode/settings.json

setup: $(SETUP_FILES) | $(RTL_DIR)
	@echo "setup: ready"
	@echo "  RTL   -> $(RTL_DIR)/<block>.sv"
	@echo "  tests -> cp $(TB_DIR)/test_template.py $(TB_DIR)/test_<block>.py"
	@echo "  run   -> make lint && pytest $(TB_DIR)/"

# Directories are order-only prerequisites (|): make builds them before it
# expands the recipes below, which matters because $(file >) is evaluated at
# expansion time, i.e. before any shell command in the same recipe has run.
$(RTL_DIR) $(TB_DIR) .vscode:
	@mkdir -p $@ && echo "created $@/"

define COMMON_PY
from pathlib import Path

from cocotb_tools.runner import get_runner

TB = Path(__file__).resolve().parent
ROOT = TB.parent
RTL = ROOT / "$(RTL_DIR)"


def run(top, test_module, sources=None, parameters=None):
    """Build `top` out of $(RTL_DIR)/ and run `test_module` against it."""
    runner = get_runner("verilator")
    runner.build(
        sources=sources or [RTL / f"{top}.sv"],
        hdl_toplevel=top,
        parameters=parameters or {},
        build_args=["--trace-fst"],
        build_dir=ROOT / "sim_build" / top,
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel=top, test_module=test_module, waves=True)
endef

define TEST_TEMPLATE_PY
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from common import run


@cocotb.test()
async def passthrough(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())

    dut.rst_ni.value = 0
    # park every block input at 0 here: unset inputs are X in Verilator and
    # the X propagates into the state registers.
    for _ in range(5):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)

    # stimulus + checking goes here


def test_template():
    # 1. copy this file to test_<block>.py
    # 2. rename this function to test_<block>
    # 3. delete the skip below and set the module name
    pytest.skip("template file: copy it per block, then remove this skip")
    run("template", test_module="test_template", parameters={})
endef

define GITIGNORE
*.vcd
*.fst
*.fst.hier
*.ghw
*.wlf
*.fsdb
*.vpd
obj_dir/
.pytest_cache/
*.log
*.vvp
*.png
.claude/
.vscode/
lint.f
verible.filelist
*__pycache__
sim_build
results.xml
*.result.xml
.surfer
*.ron
build/
endef

define VERIBLE_RULES
-no-trailing-spaces
-posix-eof
endef

define VSCODE_SETTINGS
{
  "verilog.linting.verilator.arguments": "-f lint.f -Wall -Wno-EOFNEWLINE -Wno-MODDUP",

  // cocotb lives in the hdlenv venv; point Pylance at it.
  "python.defaultInterpreterPath": "$(VENV)/bin/python",
  "python.terminal.activateEnvironment": true
}
endef

$(TB_DIR)/common.py: | $(TB_DIR)
	$(file > $@,$(COMMON_PY))
	@echo "created $@"

$(TB_DIR)/test_template.py: | $(TB_DIR)
	$(file > $@,$(TEST_TEMPLATE_PY))
	@echo "created $@"

.gitignore:
	$(file > $@,$(GITIGNORE))
	@echo "created $@"

.rules.verible_lint:
	$(file > $@,$(VERIBLE_RULES))
	@echo "created $@"

.vscode/settings.json: | .vscode
	$(file > $@,$(VSCODE_SETTINGS))
	@echo "created $@"


.PHONY: FORCE
FORCE:

surfer/%: FORCE
	surfer sim_build/$*/dump.fst -s $(STATE)
