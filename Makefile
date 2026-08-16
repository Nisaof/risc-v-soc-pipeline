# ============================================================
# Project : Custom RISC-V SoC (RV32IM)
# Board   : Digilent Nexys A7
# HDL     : SystemVerilog
# ============================================================

# --- Cross-compiler toolchain prefix ---
# We use the 64-bit toolchain with 32-bit flags.
# riscv64-unknown-elf-gcc supports both 32 and 64 bit targets.
CROSS_COMPILE  = riscv64-unknown-elf
CC             = $(CROSS_COMPILE)-gcc
OBJCOPY        = $(CROSS_COMPILE)-objcopy
OBJDUMP        = $(CROSS_COMPILE)-objdump

# --- Compiler flags ---
# -march=rv32im_zicsr : RV32I base + M (mul/div) + Zicsr (CSR instructions)
# -mabi=ilp32         : 32-bit ABI, integers and pointers are 32 bits wide
# -nostdlib           : do not link the standard C library (no OS, no malloc/printf)
# -nostartfiles       : do not use default startup code (we write our own crt0.S)
# -g                  : include debug symbols (useful for simulation inspection)
CFLAGS         = -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -g

# --- Simulator tools ---
IVERILOG       = iverilog
VVP            = vvp
GTKWAVE        = gtkwave

# --- Directory shortcuts ---
RTL_DIR        = rtl
TB_DIR         = tb
SW_DIR         = sw

# --- Vivado implementation output directory ---
# Default matches the Vivado project's auto-generated run directory name.
# Override with: make update_bitstream PROG=... VIVADO_IMPL_DIR=path/to/impl_1
VIVADO_IMPL_DIR ?= impl_1

# --- Default target ---
# Runs when you type 'make' with no arguments
.PHONY: all
all:
	@echo "================================================"
	@echo " RISC-V SoC Build System"
	@echo "================================================"
	@echo " Available targets:"
	@echo "   make sim_alu      - Simulate the ALU module"
	@echo "   make sim_all      - Run the RTL regression suite"
	@echo "   make sim_cpu_isa  - Run the compiled ISA diagnostic"
	@echo "   make sim_soc_diag - Run the full-SoC software diagnostic"
	@echo "   make compile_sw   - Compile test software"
	@echo "   make clean        - Remove all generated files"
	@echo "================================================"

# --- Simulation targets (will be filled in as modules are built) ---

# --- Clean up all generated files ---
.PHONY: clean
clean:
	rm -f *.vvp *.vcd *.fst *.lxt
	rm -f *.elf *.bin *.hex *.map
	rm -f *.o *.a
	rm -f sw/tests/*.elf sw/tests/*.bin sw/tests/*.o
	rm -f sw/riscv-tests/*.elf sw/riscv-tests/*.bin sw/riscv-tests/*.mem sw/riscv-tests/*.dmem.mem
	rm -f sim_riscv_tests.vvp
	@echo "Clean complete."

# --- ALU Simulation ---
sim_alu:
	iverilog -g2012 -o sim_alu.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/alu.sv \
		tb/core/tb_alu.sv
	vvp sim_alu.vvp

# --- MDU (multi-cycle multiplier/divider) Simulation ---
sim_mdu:
	iverilog -g2012 -o sim_mdu.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/mdu.sv \
		tb/core/tb_mdu.sv
	vvp sim_mdu.vvp

# --- Register File Simulation ---
sim_regfile:
	iverilog -g2012 -o sim_regfile.vvp \
		rtl/core/register_file.sv \
		tb/core/tb_register_file.sv
	vvp sim_regfile.vvp

# --- CSR Unit Simulation ---
sim_csr:
	iverilog -g2012 -o sim_csr.vvp \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/csr_file.sv \
		tb/core/tb_csr.sv
	vvp sim_csr.vvp

# --- CPU Integration Simulation ---
sim_cpu:
	iverilog -g2012 -o sim_cpu.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		tb/core/tb_cpu.sv
	vvp sim_cpu.vvp

# --- CPU Regression Simulation ---
sim_cpu_regression:
	iverilog -g2012 -o sim_cpu_regression.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		tb/core/tb_cpu_regression.sv
	vvp sim_cpu_regression.vvp

# --- CPU CSR/Trap Integration Simulation ---
sim_cpu_csr:
	iverilog -g2012 -o sim_cpu_csr.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		tb/core/tb_cpu_csr.sv
	vvp sim_cpu_csr.vvp

# --- IMEM Simulation ---
sim_imem:
	iverilog -g2012 -o sim_imem.vvp \
		rtl/memory/imem.sv \
		tb/memory/tb_imem.sv
	vvp sim_imem.vvp

# --- DMEM Simulation ---
sim_dmem:
	iverilog -g2012 -o sim_dmem.vvp \
		rtl/memory/dmem.sv \
		tb/memory/tb_dmem.sv
	vvp sim_dmem.vvp

# --- UART Simulation ---
sim_uart:
	iverilog -g2012 -o sim_uart.vvp \
		rtl/peripheral/uart.sv \
		tb/peripheral/tb_uart.sv
	vvp sim_uart.vvp

# --- Timer Simulation ---
sim_timer:
	iverilog -g2012 -o sim_timer.vvp \
		rtl/peripheral/timer.sv \
		tb/peripheral/tb_timer.sv
	vvp sim_timer.vvp

# --- GPIO Simulation ---
sim_gpio:
	iverilog -g2012 -o sim_gpio.vvp \
		rtl/peripheral/gpio.sv \
		tb/peripheral/tb_gpio.sv
	vvp sim_gpio.vvp

# --- SPI Flash Controller Simulation ---
sim_spi_flash:
	iverilog -g2012 -o sim_spi_flash.vvp \
		rtl/peripheral/spi_flash.sv \
		tb/peripheral/tb_spi_flash.sv
	vvp sim_spi_flash.vvp

# --- 7-Segment Display Simulation ---
sim_sevenseg:
	iverilog -g2012 -o sim_sevenseg.vvp \
		rtl/peripheral/sevenseg.sv \
		tb/peripheral/tb_sevenseg.sv
	vvp sim_sevenseg.vvp

# --- SoC Top-Level Decode Simulation ---
sim_soc_decode:
	iverilog -g2012 -o sim_soc_decode.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		rtl/memory/imem.sv \
		rtl/memory/dmem.sv \
		rtl/peripheral/uart.sv \
		rtl/peripheral/timer.sv \
		rtl/peripheral/gpio.sv \
		rtl/peripheral/sevenseg.sv \
		rtl/peripheral/spi_flash.sv \
		rtl/soc_top.sv \
		tb/integration/tb_soc_top_decode.sv
	vvp sim_soc_decode.vvp

# --- CPU Exception Integration Simulation ---
sim_cpu_exceptions:
	iverilog -g2012 -o sim_cpu_exceptions.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		tb/core/tb_cpu_exceptions.sv
	vvp sim_cpu_exceptions.vvp

# --- SVA Property Check ---
# Runs the ISA diagnostic as a stimulus witness while 5 clocked assertions
# check CPU invariants (P1: PC aligned, P2: RW mutex, P3: FSM valid,
# P4: no DMEM in FETCH/DECODE, P5: write needs byte enables).
sim_sva: compile_isa_diag
	iverilog -g2012 -o sim_sva.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		tb/core/tb_sva.sv
	vvp sim_sva.vvp

# --- Full RTL Regression Suite ---
# ============================================================
# Official RISC-V Compliance Tests (riscv-tests)
# ============================================================

RISCV_TESTS_ISA = third_party/riscv-tests/isa
RISCV_TESTS_SW  = sw/riscv-tests

# rv32ui: all integer tests except those requiring writable IMEM (fence_i),
# misaligned trapping (ma_data), or RV64-only instructions (ld_st, st_ld).
RV32UI_TESTS = add addi and andi auipc beq bge bgeu blt bltu bne \
               jal jalr lb lbu lh lhu lui lw ma_data or ori sb sh \
               sll slli slt slti sltiu sltu sra srai srl srli \
               sub sw xor xori simple

# rv32um: all 8 multiply/divide tests
RV32UM_TESTS = div divu mul mulh mulhsu mulhu rem remu

# RTL source list shared by all riscv-tests sim targets
RISCV_RTL_SRCS = \
	rtl/core/alu_ops.sv \
	rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
	rtl/core/alu.sv \
	rtl/core/mdu.sv \
	rtl/core/register_file.sv \
	rtl/core/imm_gen.sv \
	rtl/core/csr_file.sv \
	rtl/core/control_unit.sv \
	rtl/core/datapath.sv \
	rtl/core/cpu.sv

# Compile one riscv-test to a .mem file.
# Include paths: sw/riscv-tests (riscv_test.h) and the macros directory.
RISCV_OBJCOPY_FLAGS = -O binary \
	--only-section=.text.init \
	--only-section=.text \
	--only-section=.rodata

$(RISCV_TESTS_SW)/rv32ui-p-%.mem: $(RISCV_TESTS_ISA)/rv32ui/%.S
	@mkdir -p $(RISCV_TESTS_SW)
	$(CC) $(CFLAGS) \
		-I $(RISCV_TESTS_SW) \
		-I $(RISCV_TESTS_ISA)/macros/scalar \
		-T $(RISCV_TESTS_SW)/link.ld \
		-o $(RISCV_TESTS_SW)/rv32ui-p-$*.elf $<
	$(OBJCOPY) $(RISCV_OBJCOPY_FLAGS) \
		$(RISCV_TESTS_SW)/rv32ui-p-$*.elf \
		$(RISCV_TESTS_SW)/rv32ui-p-$*.bin
	python3 scripts/bin_to_mem.py -d 4096 $(RISCV_TESTS_SW)/rv32ui-p-$*.bin $@
	$(OBJCOPY) --only-section=.data -O binary \
		$(RISCV_TESTS_SW)/rv32ui-p-$*.elf \
		$(RISCV_TESTS_SW)/rv32ui-p-$*.dmem.bin
	python3 scripts/bin_to_mem.py -d 4096 $(RISCV_TESTS_SW)/rv32ui-p-$*.dmem.bin \
		$(RISCV_TESTS_SW)/rv32ui-p-$*.dmem.mem

$(RISCV_TESTS_SW)/rv32um-p-%.mem: $(RISCV_TESTS_ISA)/rv32um/%.S
	@mkdir -p $(RISCV_TESTS_SW)
	$(CC) $(CFLAGS) \
		-I $(RISCV_TESTS_SW) \
		-I $(RISCV_TESTS_ISA)/macros/scalar \
		-T $(RISCV_TESTS_SW)/link.ld \
		-o $(RISCV_TESTS_SW)/rv32um-p-$*.elf $<
	$(OBJCOPY) $(RISCV_OBJCOPY_FLAGS) \
		$(RISCV_TESTS_SW)/rv32um-p-$*.elf \
		$(RISCV_TESTS_SW)/rv32um-p-$*.bin
	python3 scripts/bin_to_mem.py -d 4096 $(RISCV_TESTS_SW)/rv32um-p-$*.bin $@
	$(OBJCOPY) --only-section=.data -O binary \
		$(RISCV_TESTS_SW)/rv32um-p-$*.elf \
		$(RISCV_TESTS_SW)/rv32um-p-$*.dmem.bin
	python3 scripts/bin_to_mem.py -d 4096 $(RISCV_TESTS_SW)/rv32um-p-$*.dmem.bin \
		$(RISCV_TESTS_SW)/rv32um-p-$*.dmem.mem

# Build the shared riscv-tests VVP binary (compiled once, run with +test=)
sim_riscv_tests.vvp: $(RISCV_RTL_SRCS) tb/riscv-tests/tb_riscv_tests.sv
	$(IVERILOG) -g2012 -o $@ $^

# Run one test: sim_rv32ui_add, sim_rv32um_mul, etc.
sim_rv32ui_%: $(RISCV_TESTS_SW)/rv32ui-p-%.mem sim_riscv_tests.vvp
	$(VVP) sim_riscv_tests.vvp +test=$(RISCV_TESTS_SW)/rv32ui-p-$*

sim_rv32um_%: $(RISCV_TESTS_SW)/rv32um-p-%.mem sim_riscv_tests.vvp
	$(VVP) sim_riscv_tests.vvp +test=$(RISCV_TESTS_SW)/rv32um-p-$*

# Run all riscv-tests
sim_riscv_tests: $(foreach t,$(RV32UI_TESTS),sim_rv32ui_$t) \
                 $(foreach t,$(RV32UM_TESTS),sim_rv32um_$t)
	@echo "All riscv-tests passed."

sim_all: sim_alu sim_mdu sim_regfile sim_imem sim_dmem sim_uart sim_timer sim_gpio sim_spi_flash sim_sevenseg sim_csr sim_cpu sim_soc_decode sim_cpu_regression sim_cpu_isa sim_cpu_csr sim_cpu_exceptions sim_sva sim_soc_diag sim_calculator

# --- ISA Diagnostic Software Build ---
compile_isa_diag:
	riscv64-unknown-elf-gcc $(CFLAGS) \
		-T sw/linker/linker.ld \
		-o sw/tests/isa_diag.elf \
		sw/startup/crt0.S \
		sw/tests/isa_diag.S
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/isa_diag.elf \
		sw/tests/isa_diag.bin
	python3 scripts/bin_to_mem.py \
		sw/tests/isa_diag.bin \
		sw/tests/isa_diag.mem
	@echo "ISA diagnostic compiled successfully"

# --- CPU ISA Diagnostic Simulation ---
sim_cpu_isa: compile_isa_diag
	iverilog -g2012 -o sim_cpu_isa.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		tb/core/tb_cpu_isa_diag.sv
	vvp sim_cpu_isa.vvp

# --- Full SoC Diagnostic Software Build ---
compile_soc_diag:
	riscv64-unknown-elf-gcc $(CFLAGS) \
		-T sw/linker/linker.ld \
		-o sw/tests/soc_diag.elf \
		sw/startup/crt0.S \
		sw/drivers/uart.c \
		sw/drivers/gpio.c \
		sw/drivers/timer.c \
		sw/tests/soc_diag.c
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/soc_diag.elf \
		sw/tests/soc_diag.bin
	python3 scripts/bin_to_mem.py \
		sw/tests/soc_diag.bin \
		sw/tests/soc_diag.mem
	@echo "SoC diagnostic compiled successfully"

# --- Full SoC Diagnostic Simulation ---
sim_soc_diag: compile_soc_diag
	iverilog -g2012 -o sim_soc_diag.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		rtl/memory/imem.sv \
		rtl/memory/dmem.sv \
		rtl/peripheral/uart.sv \
		rtl/peripheral/timer.sv \
		rtl/peripheral/gpio.sv \
		rtl/peripheral/sevenseg.sv \
		rtl/peripheral/spi_flash.sv \
		rtl/soc_top.sv \
		tb/integration/tb_soc_diag.sv
	vvp sim_soc_diag.vvp

# --- Calculator Software Build ---
compile_calculator:
	riscv64-unknown-elf-gcc $(CFLAGS) \
		-T sw/linker/linker.ld \
		-o sw/tests/calculator.elf \
		sw/startup/crt0.S \
		sw/drivers/uart.c \
		sw/drivers/gpio.c \
		sw/drivers/sevenseg.c \
		sw/tests/calculator.c
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/calculator.elf \
		sw/tests/calculator.bin
	python3 scripts/bin_to_mem.py \
		sw/tests/calculator.bin \
		sw/tests/calculator.mem
	@echo "Calculator compiled successfully"

# --- Calculator Simulation ---
sim_calculator: compile_calculator
	iverilog -g2012 -o sim_calculator.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		rtl/memory/imem.sv \
		rtl/memory/dmem.sv \
		rtl/peripheral/uart.sv \
		rtl/peripheral/timer.sv \
		rtl/peripheral/gpio.sv \
		rtl/peripheral/sevenseg.sv \
		rtl/peripheral/spi_flash.sv \
		rtl/soc_top.sv \
		tb/integration/tb_calculator.sv
	vvp sim_calculator.vvp

# --- Benchmark Software Build ---
compile_benchmark:
	riscv64-unknown-elf-gcc $(CFLAGS) \
		-T sw/linker/linker.ld \
		-o sw/tests/benchmark.elf \
		sw/startup/crt0.S \
		sw/drivers/uart.c \
		sw/tests/benchmark.c
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/benchmark.elf \
		sw/tests/benchmark.bin
	python3 scripts/bin_to_mem.py \
		sw/tests/benchmark.bin \
		sw/tests/benchmark.mem
	@echo "Benchmark compiled successfully"

# --- Benchmark Simulation ---
sim_benchmark: compile_benchmark
	iverilog -g2012 -o sim_benchmark.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		rtl/memory/imem.sv \
		rtl/memory/dmem.sv \
		rtl/peripheral/uart.sv \
		rtl/peripheral/timer.sv \
		rtl/peripheral/gpio.sv \
		rtl/peripheral/sevenseg.sv \
		rtl/peripheral/spi_flash.sv \
		rtl/soc_top.sv \
		tb/integration/tb_benchmark.sv
	vvp sim_benchmark.vvp

# --- IRQ Demo Software Build ---
compile_irq_demo:
	riscv64-unknown-elf-gcc $(CFLAGS) \
		-T sw/linker/linker.ld \
		-o sw/tests/irq_demo.elf \
		sw/startup/crt0.S \
		sw/drivers/uart.c \
		sw/drivers/gpio.c \
		sw/drivers/timer.c \
		sw/drivers/sevenseg.c \
		sw/tests/irq_demo.c
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/irq_demo.elf \
		sw/tests/irq_demo.bin
	python3 scripts/bin_to_mem.py \
		sw/tests/irq_demo.bin \
		sw/tests/irq_demo.mem
	@echo "IRQ demo compiled successfully (hardware build)"

compile_irq_demo_sim:
	riscv64-unknown-elf-gcc $(CFLAGS) -DSIM_MODE \
		-T sw/linker/linker.ld \
		-o sw/tests/irq_demo_sim.elf \
		sw/startup/crt0.S \
		sw/drivers/uart.c \
		sw/drivers/gpio.c \
		sw/drivers/timer.c \
		sw/drivers/sevenseg.c \
		sw/tests/irq_demo.c
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/irq_demo_sim.elf \
		sw/tests/irq_demo_sim.bin
	python3 scripts/bin_to_mem.py \
		sw/tests/irq_demo_sim.bin \
		sw/tests/irq_demo_sim.mem
	@echo "IRQ demo compiled successfully (simulation build)"

# --- IRQ Demo Simulation ---
sim_irq_demo: compile_irq_demo_sim
	iverilog -g2012 -o sim_irq_demo.vvp \
		rtl/core/alu_ops.sv \
		rtl/core/riscv_pkg.sv \
		rtl/core/pipeline_decode.sv \
		rtl/core/pipeline_control.sv \
		rtl/core/forwarding_unit.sv \
		rtl/core/alu.sv \
		rtl/core/mdu.sv \
		rtl/core/register_file.sv \
		rtl/core/imm_gen.sv \
		rtl/core/csr_file.sv \
		rtl/core/control_unit.sv \
		rtl/core/datapath.sv \
		rtl/core/cpu.sv \
		rtl/memory/imem.sv \
		rtl/memory/dmem.sv \
		rtl/peripheral/uart.sv \
		rtl/peripheral/timer.sv \
		rtl/peripheral/gpio.sv \
		rtl/peripheral/sevenseg.sv \
		rtl/peripheral/spi_flash.sv \
		rtl/soc_top.sv \
		tb/integration/tb_irq_demo.sv
	vvp sim_irq_demo.vvp

# --- Bootloader Software Build ---
# Compiles the UART bootloader and creates a combined .mem image:
#   words 0–3839  : zeros (user program slot, filled at runtime)
#   words 3840–4095: bootloader binary at 0x3C00
compile_bootloader:
	riscv64-unknown-elf-gcc $(CFLAGS) -Os \
		-T sw/linker/linker_boot.ld \
		-o sw/tests/bootloader.elf \
		sw/startup/crt0_boot.S \
		sw/drivers/uart.c \
		sw/drivers/spi_flash.c \
		sw/tests/bootloader.c
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/bootloader.elf \
		sw/tests/bootloader.bin
	python3 scripts/make_boot_mem.py \
		sw/tests/bootloader.bin \
		sw/tests/bootloader.mem
	@echo "Bootloader compiled successfully"

# --- Fast bitstream patching via updatemem ---
# Usage: make update_bitstream PROG=sw/tests/<name>.elf
#   PROG must be a compiled .elf (built by compile_<name> first).
#   Requires the Vivado implementation to have been run once so that
#   $(VIVADO_IMPL_DIR)/nexys_a7_top.mmi and .bit exist.
#   updatemem must be on PATH (source Vivado settings64.sh / settings64.bat first).
.PHONY: update_bitstream
update_bitstream:
	@if [ -z "$(PROG)" ]; then \
		echo "Usage: make update_bitstream PROG=sw/tests/<name>.elf"; \
		echo "       VIVADO_IMPL_DIR defaults to '$(VIVADO_IMPL_DIR)'"; \
		exit 1; \
	fi
	@if [ ! -f "$(VIVADO_IMPL_DIR)/nexys_a7_top.mmi" ]; then \
		echo "ERROR: $(VIVADO_IMPL_DIR)/nexys_a7_top.mmi not found."; \
		echo "       Run Vivado implementation first to generate the .mmi file."; \
		exit 1; \
	fi
	@if [ ! -f "$(VIVADO_IMPL_DIR)/nexys_a7_top.bit" ]; then \
		echo "ERROR: $(VIVADO_IMPL_DIR)/nexys_a7_top.bit not found."; \
		exit 1; \
	fi
	updatemem -force \
		-meminfo $(VIVADO_IMPL_DIR)/nexys_a7_top.mmi \
		-data $(PROG) \
		-bit $(VIVADO_IMPL_DIR)/nexys_a7_top.bit \
		-proc nexys_a7_top/u_soc/u_imem \
		-out nexys_a7_top_updated.bit
	@echo "Patched bitstream written to nexys_a7_top_updated.bit"
	@echo "Program the board: open_hw_manager → program with nexys_a7_top_updated.bit"

# --- Software Compilation ---
compile_sw:
	riscv64-unknown-elf-gcc $(CFLAGS) \
		-T sw/linker/linker.ld \
		-o sw/tests/program.elf \
		sw/startup/crt0.S \
		sw/drivers/uart.c \
		sw/drivers/gpio.c \
		sw/drivers/timer.c \
		sw/tests/main.c
	riscv64-unknown-elf-objcopy -O binary \
		sw/tests/program.elf \
		sw/tests/program.bin
	python3 scripts/bin_to_mem.py \
		sw/tests/program.bin \
		sw/tests/program.mem
	@echo "Software compiled successfully"
