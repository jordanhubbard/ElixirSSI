/*
 * Raspberry Pi RP1 south bridge
 *
 * RP1 is a PCIe 2.0 endpoint whose BAR1 is a window onto its own
 * peripheral bus (RP1 address 0x4000_0000 + offset). Sources, in order of
 * authority: the RP1 peripherals datasheet (2023-11, sections 2 to 7),
 * lspci of RP1 on a Raspberry Pi 5, and the Raspberry Pi Linux drivers
 * that are its reference implementation (drivers/mfd/rp1.c,
 * drivers/clk/clk-rp1.c, drivers/pinctrl/pinctrl-rp1.c, the macb
 * driver's raspberrypi,rp1-gem configuration).
 *
 * Modelled: the PCI function and its MSI-X translation (MSIn_CFG with
 * the IACK protocol), SYSINFO, the clock generators and PLLs (register
 * level: PLLs lock once powered), the GPIO banks with pin interrupts,
 * UART0-5 (PL011), the Ethernet MAC (Cadence GEM) and the two USB host
 * controllers (DesignWare USB3, xHCI), both mastering the host's memory
 * through the link. Every other block of the datasheet's
 * address map reads as zero and is logged with -d unimp under its name.
 *
 * Copyright (c) 2026 The ElixirSSI authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qemu/units.h"
#include "qapi/error.h"
#include "hw/core/qdev-properties.h"
#include "hw/core/irq.h"
#include "hw/pci/msix.h"
#include "hw/pci/pcie.h"
#include "hw/core/sysbus.h"
#include "migration/vmstate.h"
#include "hw/misc/rp1.h"

/* RP1 interrupt numbers, from include/dt-bindings/mfd/rp1.h */
#define RP1_INT_IO_BANK0        0
#define RP1_INT_ETH             6
#define RP1_INT_UART0           25
#define RP1_INT_UART1           42
#define RP1_INT_USBHOST0_0      31
#define RP1_INT_USBHOST1_0      36

/* Peripheral offsets in BAR1 (datasheet table 2 / dt-bindings/mfd/rp1.h) */
#define RP1_SYSINFO_BASE        0x000000
#define RP1_UART_BASE(n)        (0x030000 + (n) * 0x4000)
#define RP1_ETH_BASE            0x100000
#define RP1_USBHOST_BASE(n)     (0x200000 + (n) * 0x100000)

static const struct {
    hwaddr base;
    int kind;
    int index;
} rp1_block_map[] = {
    { 0x018000, RP1_BLK_CLOCKS_MAIN, 0 },
    { 0x01c000, RP1_BLK_CLOCKS_VIDEO, 0 },
    { 0x020000, RP1_BLK_PLL_SYS, 0 },
    { 0x024000, RP1_BLK_PLL_AUDIO, 1 },
    { 0x028000, RP1_BLK_PLL_VIDEO, 2 },
    { 0x0d0000, RP1_BLK_IO_BANK0, 0 },
    { 0x0d4000, RP1_BLK_IO_BANK1, 1 },
    { 0x0d8000, RP1_BLK_IO_BANK2, 2 },
    { 0x0e0000, RP1_BLK_SYS_RIO0, 0 },
    { 0x0e4000, RP1_BLK_SYS_RIO1, 1 },
    { 0x0e8000, RP1_BLK_SYS_RIO2, 2 },
    { 0x0f0000, RP1_BLK_PADS_BANK0, 0 },
    { 0x0f4000, RP1_BLK_PADS_BANK1, 1 },
    { 0x0f8000, RP1_BLK_PADS_BANK2, 2 },
    { 0x104000, RP1_BLK_ETH_CFG, 0 },
    { 0x108000, RP1_BLK_PCIE_CFG, 0 },
};

/* Every block of the datasheet's address map, to name unmodelled accesses */
static const struct {
    hwaddr base;
    const char *name;
} rp1_names[] = {
    { 0x000000, "sysinfo" }, { 0x004000, "tbman" }, { 0x008000, "syscfg" },
    { 0x00c000, "otp" }, { 0x010000, "power" }, { 0x014000, "resets" },
    { 0x018000, "clocks_main" }, { 0x01c000, "clocks_video" },
    { 0x020000, "pll_sys" }, { 0x024000, "pll_audio" },
    { 0x028000, "pll_video" }, { 0x030000, "uart0" }, { 0x034000, "uart1" },
    { 0x038000, "uart2" }, { 0x03c000, "uart3" }, { 0x040000, "uart4" },
    { 0x044000, "uart5" }, { 0x04c000, "spi8" }, { 0x050000, "spi0" },
    { 0x054000, "spi1" }, { 0x058000, "spi2" }, { 0x05c000, "spi3" },
    { 0x060000, "spi4" }, { 0x064000, "spi5" }, { 0x068000, "spi6" },
    { 0x06c000, "spi7" }, { 0x070000, "i2c0" }, { 0x074000, "i2c1" },
    { 0x078000, "i2c2" }, { 0x07c000, "i2c3" }, { 0x080000, "i2c4" },
    { 0x084000, "i2c5" }, { 0x088000, "i2c6" }, { 0x090000, "audio_in" },
    { 0x094000, "audio_out" }, { 0x098000, "pwm0" }, { 0x09c000, "pwm1" },
    { 0x0a0000, "i2s0" }, { 0x0a4000, "i2s1" }, { 0x0a8000, "i2s2" },
    { 0x0ac000, "timer" }, { 0x0b0000, "sdio0_apbs" },
    { 0x0b4000, "sdio1_apbs" }, { 0x0c0000, "busfabric_monitor" },
    { 0x0c4000, "busfabric_axishim" }, { 0x0c8000, "adc" },
    { 0x0d0000, "io_bank0" }, { 0x0d4000, "io_bank1" },
    { 0x0d8000, "io_bank2" }, { 0x0e0000, "sys_rio0" },
    { 0x0e4000, "sys_rio1" }, { 0x0e8000, "sys_rio2" },
    { 0x0f0000, "pads_bank0" }, { 0x0f4000, "pads_bank1" },
    { 0x0f8000, "pads_bank2" }, { 0x0fc000, "pads_eth" },
    { 0x100000, "eth" }, { 0x104000, "eth_cfg" }, { 0x108000, "pcie" },
    { 0x110000, "mipi0" }, { 0x128000, "mipi1" },
    { 0x140000, "video_out" }, { 0x150000, "xosc" },
    { 0x154000, "watchdog" }, { 0x158000, "dma_tick" },
    { 0x15c000, "sdio_clocks" }, { 0x160000, "usbhost0_apbs" },
    { 0x164000, "usbhost1_apbs" }, { 0x168000, "rosc0" },
    { 0x16c000, "rosc1" }, { 0x170000, "vbusctrl" },
    { 0x174000, "ticks" }, { 0x178000, "pio" }, { 0x180000, "sdio0" },
    { 0x184000, "sdio1" }, { 0x188000, "dma" }, { 0x1c0000, "sram" },
    { 0x200000, "usbhost0" }, { 0x300000, "usbhost1" },
};

static const char *rp1_name_of(hwaddr addr)
{
    const char *name = "reserved";

    for (int i = 0; i < ARRAY_SIZE(rp1_names) && rp1_names[i].base <= addr;
         i++) {
        name = rp1_names[i].name;
    }
    return name;
}

/*
 * Interrupts (datasheet 6.2). Each of the 61 lines is level: high for as
 * long as its peripheral's interrupt is. MSIn_CFG.ENABLE turns a rising
 * edge of the line (or of TEST, which forces it) into MSI-X vector n.
 * With IACK_EN, the vector is masked once sent until software writes
 * IACK; a line still high then sends it again. Without IACK_EN each
 * rising edge sends it.
 */
#define MSIX_CFG_ENABLE         (1 << 0)
#define MSIX_CFG_TEST           (1 << 1)
#define MSIX_CFG_IACK           (1 << 2)
#define MSIX_CFG_IACK_EN        (1 << 3)

#define PCIE_CFG_MSIX_CFG(n)    (0x008 + 4 * (n))
#define PCIE_CFG_INTSTATL       0x108
#define PCIE_CFG_INTSTATH       0x10c

static uint32_t *rp1_msix_cfg(RP1State *s, int n)
{
    return &s->blocks[RP1_BLK_PCIE_CFG].regs[PCIE_CFG_MSIX_CFG(n) / 4];
}

static bool rp1_vector_active(RP1State *s, int n)
{
    uint32_t cfg = *rp1_msix_cfg(s, n);

    return (cfg & MSIX_CFG_ENABLE) &&
           (((s->lines >> n) & 1) || (cfg & MSIX_CFG_TEST));
}

static void rp1_send(RP1State *s, int n)
{
    PCIDevice *pci = PCI_DEVICE(s);

    if (*rp1_msix_cfg(s, n) & MSIX_CFG_IACK_EN) {
        if (s->awaiting_iack & (1ULL << n)) {
            return;
        }
        s->awaiting_iack |= 1ULL << n;
    }
    if (msix_enabled(pci)) {
        msix_notify(pci, n);
    }
}

/* Called with the vector's state before a change, to see its edge */
static void rp1_vector_update(RP1State *s, int n, bool was_active)
{
    if (!was_active && rp1_vector_active(s, n)) {
        rp1_send(s, n);
    }
}

static void rp1_set_irq(void *opaque, int n, int level)
{
    RP1State *s = opaque;
    bool was = rp1_vector_active(s, n);

    s->lines = deposit64(s->lines, n, 1, !!level);
    rp1_vector_update(s, n, was);
}

static void rp1_msix_cfg_write(RP1State *s, int n, uint32_t value)
{
    bool was = rp1_vector_active(s, n);
    uint32_t *cfg = rp1_msix_cfg(s, n);

    *cfg = value & (MSIX_CFG_ENABLE | MSIX_CFG_TEST | MSIX_CFG_IACK_EN);
    if (!(*cfg & MSIX_CFG_IACK_EN)) {
        s->awaiting_iack &= ~(1ULL << n);
    }
    if (value & MSIX_CFG_IACK) {
        s->awaiting_iack &= ~(1ULL << n);
        if (rp1_vector_active(s, n)) {
            rp1_send(s, n);
            return;
        }
    }
    rp1_vector_update(s, n, was);
}

/*
 * GPIO (datasheet 3.1, register layout from pinctrl-rp1). Bank 0 has
 * GPIOs 0-27 (the 40-pin header), bank 1 28-33 and bank 2 34-53. A pin's
 * input is what drives its pad: RIO's output when RIO's output enable is
 * set and the pin is in function 5 (sys_rio), else whatever is attached
 * outside, else its pull. Output overrides apply as CTRL selects.
 */
static const struct {
    int first;
    int count;
} rp1_gpio_banks[RP1_NUM_GPIO_BANKS] = {
    { 0, 28 }, { 28, 6 }, { 34, 20 },
};

#define GPIO_STATUS(p)          (8 * (p))
#define GPIO_CTRL(p)            (8 * (p) + 4)
#define GPIO_PCIE_INTE          0x11c
#define GPIO_PCIE_INTF          0x120
#define GPIO_PCIE_INTS          0x124
#define GPIO_INTR               0x100

#define GPIO_CTRL_FUNCSEL       0x1f
#define GPIO_CTRL_OUTOVER(c)    extract32(c, 12, 2)
#define GPIO_CTRL_OEOVER(c)     extract32(c, 14, 2)
#define GPIO_CTRL_INOVER(c)     extract32(c, 16, 2)
#define GPIO_CTRL_IRQEN(c)      extract32(c, 20, 8)
#define GPIO_CTRL_IRQRESET      (1u << 28)
#define GPIO_CTRL_IRQOVER(c)    extract32(c, 30, 2)
#define GPIO_FSEL_SYS_RIO       5
#define GPIO_FSEL_NONE_HW       0x1f

#define GPIO_STATUS_OUTTOPAD    (1u << 9)
#define GPIO_STATUS_OETOPAD     (1u << 13)
#define GPIO_STATUS_INFROMPAD   (1u << 17)
#define GPIO_STATUS_INFILTERED  (1u << 18)
#define GPIO_STATUS_INTOPERI    (1u << 19)
#define GPIO_EV_EDGE_LOW        (1u << 20)
#define GPIO_EV_EDGE_HIGH       (1u << 21)
#define GPIO_EV_LEVEL_LOW       (1u << 22)
#define GPIO_EV_LEVEL_HIGH      (1u << 23)
#define GPIO_EV_F_EDGE_LOW      (1u << 24)
#define GPIO_EV_F_EDGE_HIGH     (1u << 25)
#define GPIO_EV_DB_LEVEL_LOW    (1u << 26)
#define GPIO_EV_DB_LEVEL_HIGH   (1u << 27)
#define GPIO_EV_LATCHED         (GPIO_EV_EDGE_LOW | GPIO_EV_EDGE_HIGH | \
                                 GPIO_EV_F_EDGE_LOW | GPIO_EV_F_EDGE_HIGH)
#define GPIO_STATUS_IRQCOMBINED (1u << 28)
#define GPIO_STATUS_IRQTOPROC   (1u << 29)

#define RIO_OUT                 0x0
#define RIO_OE                  0x4
#define RIO_IN                  0x8

#define PAD_PULL(p)             extract32(p, 2, 2)
#define PAD_PULL_DOWN           1
#define PAD_PULL_UP             2
#define PAD_IN_ENABLE           (1u << 6)
#define PAD_OUT_DISABLE         (1u << 7)

static uint32_t *rp1_gpio_ctrl(RP1State *s, int bank, int pin)
{
    return &s->blocks[RP1_BLK_IO_BANK0 + bank].regs[GPIO_CTRL(pin) / 4];
}

static uint32_t *rp1_gpio_status(RP1State *s, int bank, int pin)
{
    return &s->blocks[RP1_BLK_IO_BANK0 + bank].regs[GPIO_STATUS(pin) / 4];
}

static uint32_t rp1_pad(RP1State *s, int bank, int pin)
{
    /* Word 0 of the block is VOLTAGE_SELECT; pins start at 4 */
    return s->blocks[RP1_BLK_PADS_BANK0 + bank].regs[1 + pin];
}

static uint32_t rp1_override(int over, bool peri)
{
    switch (over) {
    case 0:
        return peri;
    case 1:
        return !peri;
    case 2:
        return 0;
    default:
        return 1;
    }
}

/* The pad's output enable and level, after CTRL's overrides */
static void rp1_gpio_output(RP1State *s, int bank, int pin, bool *oe,
                            bool *out)
{
    uint32_t ctrl = *rp1_gpio_ctrl(s, bank, pin);
    uint32_t *rio = s->blocks[RP1_BLK_SYS_RIO0 + bank].regs;
    bool peri_oe = false, peri_out = false;

    if ((ctrl & GPIO_CTRL_FUNCSEL) == GPIO_FSEL_SYS_RIO) {
        peri_oe = (rio[RIO_OE / 4] >> pin) & 1;
        peri_out = (rio[RIO_OUT / 4] >> pin) & 1;
    }
    *oe = rp1_override(GPIO_CTRL_OEOVER(ctrl), peri_oe) &&
          !(rp1_pad(s, bank, pin) & PAD_OUT_DISABLE);
    *out = rp1_override(GPIO_CTRL_OUTOVER(ctrl), peri_out);
}

static bool rp1_gpio_pad_level(RP1State *s, int bank, int pin)
{
    int gpio = rp1_gpio_banks[bank].first + pin;
    bool oe, out;

    rp1_gpio_output(s, bank, pin, &oe, &out);
    if (oe) {
        return out;
    }
    if ((s->gpio_driven >> gpio) & 1) {
        return (s->gpio_external >> gpio) & 1;
    }
    return PAD_PULL(rp1_pad(s, bank, pin)) == PAD_PULL_UP;
}

/* Recompute every pin's STATUS, its events and the banks' interrupts */
static void rp1_gpio_update(RP1State *s)
{
    for (int bank = 0; bank < RP1_NUM_GPIO_BANKS; bank++) {
        uint32_t *regs = s->blocks[RP1_BLK_IO_BANK0 + bank].regs;
        uint32_t *rio = s->blocks[RP1_BLK_SYS_RIO0 + bank].regs;
        uint32_t intr = 0, rio_in = 0;

        for (int pin = 0; pin < rp1_gpio_banks[bank].count; pin++) {
            int gpio = rp1_gpio_banks[bank].first + pin;
            uint32_t ctrl = *rp1_gpio_ctrl(s, bank, pin);
            uint32_t *status = rp1_gpio_status(s, bank, pin);
            bool pad = rp1_gpio_pad_level(s, bank, pin);
            bool last = (s->gpio_last_in >> gpio) & 1;
            bool in = rp1_override(GPIO_CTRL_INOVER(ctrl), pad);
            bool oe, out;
            uint32_t st = *status & GPIO_EV_LATCHED;
            uint32_t events, irq;

            rp1_gpio_output(s, bank, pin, &oe, &out);
            if (pad != last) {
                st |= pad ? (GPIO_EV_EDGE_HIGH | GPIO_EV_F_EDGE_HIGH)
                          : (GPIO_EV_EDGE_LOW | GPIO_EV_F_EDGE_LOW);
            }
            s->gpio_last_in = deposit64(s->gpio_last_in, gpio, 1, pad);
            st |= pad ? (GPIO_EV_LEVEL_HIGH | GPIO_EV_DB_LEVEL_HIGH)
                      : (GPIO_EV_LEVEL_LOW | GPIO_EV_DB_LEVEL_LOW);
            st |= oe ? GPIO_STATUS_OETOPAD : 0;
            st |= out ? GPIO_STATUS_OUTTOPAD : 0;
            st |= pad ? (GPIO_STATUS_INFROMPAD | GPIO_STATUS_INFILTERED) : 0;
            st |= in ? GPIO_STATUS_INTOPERI : 0;

            events = extract32(st, 20, 8) & GPIO_CTRL_IRQEN(ctrl);
            irq = rp1_override(GPIO_CTRL_IRQOVER(ctrl), events != 0);
            st |= events ? GPIO_STATUS_IRQCOMBINED : 0;
            st |= irq ? GPIO_STATUS_IRQTOPROC : 0;
            *status = st;
            intr |= irq << pin;
            /* RIO reads the pin as its peripheral sees it */
            rio_in |= (uint32_t)in << pin;
        }
        rio[RIO_IN / 4] = rio_in;
        regs[GPIO_INTR / 4] = intr;
        regs[GPIO_PCIE_INTS / 4] = (intr & regs[GPIO_PCIE_INTE / 4]) |
                                   regs[GPIO_PCIE_INTF / 4];
        rp1_set_irq(s, RP1_INT_IO_BANK0 + bank,
                    regs[GPIO_PCIE_INTS / 4] != 0);
    }
}

/* An external device drives a pin (input gpio "gpio-in", n = 0..53) */
static void rp1_gpio_set_external(void *opaque, int n, int level)
{
    RP1State *s = opaque;

    s->gpio_driven |= 1ULL << n;
    s->gpio_external = deposit64(s->gpio_external, n, 1, !!level);
    rp1_gpio_update(s);
}

/*
 * Clocks (datasheet 2.5 and clk-rp1). Dividers and selects read back as
 * written. A PLL reports CS.LOCK while its PWR register leaves it powered
 * (PD and VCOPD clear), as it would once locked. SEL reads as zero, which
 * clk-rp1 takes as "use CTRL's source".
 */
#define PLL_CS                  0x00
#define PLL_PWR                 0x04
#define PLL_FBDIV_INT           0x08
#define PLL_PRIM                0x10
#define PLL_SEC                 0x14
#define PLL_CS_LOCK             (1u << 31)
#define PLL_PWR_PD              (1u << 0)
#define PLL_PWR_VCOPD           (1u << 5)
#define PLL_SEC_IMPL            (1u << 31)

static uint32_t rp1_block_read_reg(RP1Block *b, hwaddr reg)
{
    RP1State *s = b->rp1;
    uint32_t value = b->regs[reg / 4];

    switch (b->kind) {
    case RP1_BLK_PLL_SYS:
    case RP1_BLK_PLL_AUDIO:
    case RP1_BLK_PLL_VIDEO:
        if (reg == PLL_CS) {
            value &= ~PLL_CS_LOCK;
            if (!(b->regs[PLL_PWR / 4] & (PLL_PWR_PD | PLL_PWR_VCOPD))) {
                value |= PLL_CS_LOCK;
            }
        }
        break;
    case RP1_BLK_PCIE_CFG:
        if (reg == PCIE_CFG_INTSTATL) {
            value = (uint32_t)s->lines;
        } else if (reg == PCIE_CFG_INTSTATH) {
            value = s->lines >> 32;
        }
        break;
    default:
        break;
    }
    return value;
}

static void rp1_block_write_reg(RP1Block *b, hwaddr reg, uint32_t value)
{
    RP1State *s = b->rp1;

    switch (b->kind) {
    case RP1_BLK_PCIE_CFG:
        if (reg >= PCIE_CFG_MSIX_CFG(0) &&
            reg < PCIE_CFG_MSIX_CFG(RP1_NUM_VECTORS)) {
            int n = (reg - PCIE_CFG_MSIX_CFG(0)) / 4;

            if (n < RP1_NUM_IRQS) {
                rp1_msix_cfg_write(s, n, value);
            }
            return;
        }
        if (reg == PCIE_CFG_INTSTATL || reg == PCIE_CFG_INTSTATH) {
            return;
        }
        break;
    case RP1_BLK_IO_BANK0:
    case RP1_BLK_IO_BANK1:
    case RP1_BLK_IO_BANK2:
        if (reg < GPIO_INTR && (reg & 4) == 0) {
            return;                         /* STATUS is read-only */
        }
        if (reg < GPIO_INTR && (value & GPIO_CTRL_IRQRESET)) {
            *rp1_gpio_status(s, b->index, reg / 8) &= ~GPIO_EV_LATCHED;
            value &= ~GPIO_CTRL_IRQRESET;
        }
        if (reg == GPIO_INTR || reg == GPIO_PCIE_INTS) {
            return;
        }
        b->regs[reg / 4] = value;
        rp1_gpio_update(s);
        return;
    case RP1_BLK_SYS_RIO0:
    case RP1_BLK_SYS_RIO1:
    case RP1_BLK_SYS_RIO2:
        if (reg == RIO_IN) {
            return;
        }
        b->regs[reg / 4] = value;
        rp1_gpio_update(s);
        return;
    case RP1_BLK_PADS_BANK0:
    case RP1_BLK_PADS_BANK1:
    case RP1_BLK_PADS_BANK2:
        b->regs[reg / 4] = value;
        rp1_gpio_update(s);
        return;
    case RP1_BLK_PLL_SYS:
    case RP1_BLK_PLL_AUDIO:
    case RP1_BLK_PLL_VIDEO:
        if (reg == PLL_SEC) {
            value |= PLL_SEC_IMPL;
        }
        break;
    default:
        break;
    }
    b->regs[reg / 4] = value;
}

/*
 * The atomic aliases (datasheet 2.4): +0x0000 read/write, +0x1000 XOR,
 * +0x2000 set, +0x3000 clear. PCIE_CFG is also written through
 * +0x800 (set) and +0xc00 (clear), as Linux's rp1 driver does: the
 * datasheet does not list these, but hardware honours them.
 */
static uint64_t rp1_block_read(void *opaque, hwaddr addr, unsigned size)
{
    RP1Block *b = opaque;
    hwaddr reg = addr & 0xffc;

    if (b->kind == RP1_BLK_PCIE_CFG && (addr & 0xfff) >= 0x800) {
        reg = addr & 0x7fc;
    }
    return rp1_block_read_reg(b, reg);
}

static void rp1_block_write(void *opaque, hwaddr addr, uint64_t value,
                            unsigned size)
{
    RP1Block *b = opaque;
    int alias = addr >> 12;
    hwaddr reg = addr & 0xffc;
    uint32_t old;

    if (b->kind == RP1_BLK_PCIE_CFG && alias == 0 && (addr & 0xfff) >= 0x800) {
        alias = (addr & 0x400) ? 3 : 2;
        reg = addr & 0x3fc;
    }
    old = b->regs[reg / 4];
    /* Write-one bits such as IACK and IRQRESET act whatever the alias */
    switch (alias) {
    case 1:
        value = old ^ value;
        break;
    case 2:
        value = old | value;
        break;
    case 3:
        value = old & ~value;
        if (b->kind == RP1_BLK_PCIE_CFG) {
            value &= ~MSIX_CFG_IACK;
        }
        break;
    default:
        break;
    }
    rp1_block_write_reg(b, reg, value);
}

static const MemoryRegionOps rp1_block_ops = {
    .read = rp1_block_read,
    .write = rp1_block_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

/* SYSINFO: CHIP_ID and PLATFORM */
static uint64_t rp1_sysinfo_read(void *opaque, hwaddr addr, unsigned size)
{
    switch (addr) {
    case 0x0:
        return RP1_C0_CHIP_ID;
    case 0x4:
        return RP1_PLATFORM_ASIC;
    default:
        return 0;
    }
}

static void rp1_sysinfo_write(void *opaque, hwaddr addr, uint64_t value,
                              unsigned size)
{
    qemu_log_mask(LOG_GUEST_ERROR, "rp1: write to read-only sysinfo 0x%"
                  HWADDR_PRIx "\n", addr);
}

static const MemoryRegionOps rp1_sysinfo_ops = {
    .read = rp1_sysinfo_read,
    .write = rp1_sysinfo_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

/* Everything not modelled reads as zero and ignores writes, by name */
static uint64_t rp1_unimp_read(void *opaque, hwaddr addr, unsigned size)
{
    qemu_log_mask(LOG_UNIMP, "rp1.%s: unimplemented read at 0x%" HWADDR_PRIx
                  "\n", rp1_name_of(addr), addr);
    return 0;
}

static void rp1_unimp_write(void *opaque, hwaddr addr, uint64_t value,
                            unsigned size)
{
    qemu_log_mask(LOG_UNIMP, "rp1.%s: unimplemented write of 0x%" PRIx64
                  " at 0x%" HWADDR_PRIx "\n", rp1_name_of(addr), value, addr);
}

static const MemoryRegionOps rp1_unimp_ops = {
    .read = rp1_unimp_read,
    .write = rp1_unimp_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 1,
    .valid.max_access_size = 8,
};

static void rp1_reset_blocks(RP1State *s)
{
    for (int i = 0; i < RP1_NUM_BLOCKS; i++) {
        memset(s->blocks[i].regs, 0, sizeof(s->blocks[i].regs));
    }
    /*
     * The PLLs as RP1's boot leaves them before Linux's clk-rp1 sets the
     * device tree's rates: from the 50 MHz crystal, SYS's VCO at 2 GHz
     * (datasheet 2.5.2), AUDIO's at 1.536 GHz (2.5.4); VIDEO powered down.
     */
    for (int i = RP1_BLK_PLL_SYS; i <= RP1_BLK_PLL_VIDEO; i++) {
        uint32_t *r = s->blocks[i].regs;

        r[PLL_CS / 4] = 1;                          /* REFDIV 1 */
        r[PLL_FBDIV_INT / 4] = i == RP1_BLK_PLL_AUDIO ? 30 : 40;
        r[PLL_PRIM / 4] = (1 << 16) | (1 << 12);    /* /1 /1 */
        r[PLL_SEC / 4] = PLL_SEC_IMPL;
        r[PLL_PWR / 4] = i == RP1_BLK_PLL_VIDEO ? 0x3f : 0;
    }
    /*
     * Pads reset to input-enabled with a pull-down, GPIOs to no function
     * (pinctrl-rp1's RP1_FSEL_NONE_HW).
     */
    for (int bank = 0; bank < RP1_NUM_GPIO_BANKS; bank++) {
        for (int pin = 0; pin < rp1_gpio_banks[bank].count; pin++) {
            s->blocks[RP1_BLK_PADS_BANK0 + bank].regs[1 + pin] =
                PAD_IN_ENABLE | (PAD_PULL_DOWN << 2) | (1 << 4) | (1 << 1);
            *rp1_gpio_ctrl(s, bank, pin) = GPIO_FSEL_NONE_HW;
        }
    }
}

static void rp1_reset(DeviceState *dev)
{
    RP1State *s = RP1(dev);

    s->lines = 0;
    s->awaiting_iack = 0;
    s->gpio_last_in = 0;
    rp1_reset_blocks(s);
    msix_reset(PCI_DEVICE(s));
    rp1_gpio_update(s);
}

static void rp1_init(Object *obj)
{
    RP1State *s = RP1(obj);

    for (int i = 0; i < RP1_NUM_UARTS; i++) {
        g_autofree char *name = g_strdup_printf("uart%d", i);

        object_initialize_child(obj, name, &s->uart[i], TYPE_PL011);
    }
    object_initialize_child(obj, "eth", &s->eth, TYPE_CADENCE_GEM);
    for (int i = 0; i < RP1_NUM_USB; i++) {
        g_autofree char *name = g_strdup_printf("usb%d", i);

        object_initialize_child(obj, name, &s->usb[i], TYPE_USB_DWC3);
    }
    object_property_add_alias(obj, "mac", OBJECT(&s->eth), "mac");
    object_property_add_alias(obj, "netdev", OBJECT(&s->eth), "netdev");
    for (int i = 0; i < RP1_NUM_UARTS; i++) {
        g_autofree char *name = g_strdup_printf("uart%d-chardev", i);

        object_property_add_alias(obj, name, OBJECT(&s->uart[i]), "chardev");
    }
    qdev_init_gpio_in_named(DEVICE(obj), rp1_set_irq, "irq", RP1_NUM_IRQS);
    qdev_init_gpio_in_named(DEVICE(obj), rp1_gpio_set_external, "gpio-in",
                            RP1_NUM_GPIOS);
}

static void rp1_realize(PCIDevice *pci, Error **errp)
{
    RP1State *s = RP1(pci);
    DeviceState *dev = DEVICE(pci);
    Object *obj = OBJECT(pci);
    uint8_t *conf = pci->config;
    int ret;

    pci_config_set_interrupt_pin(conf, 1);
    /* lspci shows RP1 without a subsystem */
    pci_set_word(conf + PCI_SUBSYSTEM_VENDOR_ID, 0);
    pci_set_word(conf + PCI_SUBSYSTEM_ID, 0);

    memory_region_init(&s->bar0, obj, "rp1.bar0", RP1_BAR0_SIZE);
    memory_region_init(&s->bar1, obj, "rp1.peripherals", RP1_BAR1_SIZE);
    if (!memory_region_init_ram(&s->bar2, obj, "rp1.shared-sram",
                                RP1_BAR2_SIZE, errp)) {
        return;
    }

    /* The whole peripheral window, beneath the modelled blocks */
    memory_region_init_io(&s->unimp, obj, &rp1_unimp_ops, s, "rp1.unimp",
                          RP1_BAR1_SIZE);
    memory_region_add_subregion_overlap(&s->bar1, 0, &s->unimp, -1000);

    memory_region_init_io(&s->sysinfo, obj, &rp1_sysinfo_ops, s,
                          "rp1.sysinfo", 0x4000);
    memory_region_add_subregion(&s->bar1, RP1_SYSINFO_BASE, &s->sysinfo);

    for (int i = 0; i < ARRAY_SIZE(rp1_block_map); i++) {
        RP1Block *b = &s->blocks[rp1_block_map[i].kind];
        g_autofree char *name = g_strdup_printf("rp1.%s",
                                    rp1_name_of(rp1_block_map[i].base));

        b->rp1 = s;
        b->kind = rp1_block_map[i].kind;
        b->index = rp1_block_map[i].index;
        memory_region_init_io(&b->iomem, obj, &rp1_block_ops, b, name,
                              0x4000);
        memory_region_add_subregion(&s->bar1, rp1_block_map[i].base,
                                    &b->iomem);
    }

    for (int i = 0; i < RP1_NUM_UARTS; i++) {
        SysBusDevice *sbd = SYS_BUS_DEVICE(&s->uart[i]);

        if (!sysbus_realize(sbd, errp)) {
            return;
        }
        memory_region_add_subregion(&s->bar1, RP1_UART_BASE(i),
                                    sysbus_mmio_get_region(sbd, 0));
        sysbus_connect_irq(sbd, 0, qdev_get_gpio_in_named(dev, "irq",
                           i == 0 ? RP1_INT_UART0 : RP1_INT_UART1 + i - 1));
    }

    /*
     * The Ethernet MAC is a bus master on RP1's fabric, which reaches the
     * host's memory across the link at PCI address 0x10_0000_0000 + x
     * (the rp1 node's dma-ranges); RP1 passes the address through, so the
     * MAC masters this function's PCI address space directly.
     */
    object_property_set_link(OBJECT(&s->eth), "dma",
                             OBJECT(&pci->bus_master_container_region),
                             &error_abort);
    qdev_prop_set_uint8(DEVICE(&s->eth), "phy-addr", 0);
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->eth), errp)) {
        return;
    }
    memory_region_add_subregion(&s->bar1, RP1_ETH_BASE,
                        sysbus_mmio_get_region(SYS_BUS_DEVICE(&s->eth), 0));
    sysbus_connect_irq(SYS_BUS_DEVICE(&s->eth), 0,
                       qdev_get_gpio_in_named(dev, "irq", RP1_INT_ETH));

    /*
     * USB: two xHCI controllers (DesignWare USB3 in host mode), each with
     * one USB 3 and one USB 2 port, the two of each on a Pi 5. Their first
     * interrupter raises USBHOST0_0 or USBHOST1_0, which the datasheet
     * names as RP1's only true edge-triggered vectors.
     */
    for (int i = 0; i < RP1_NUM_USB; i++) {
        SysBusDevice *xhci = SYS_BUS_DEVICE(&s->usb[i].sysbus_xhci);

        qdev_prop_set_uint32(DEVICE(xhci), "p2", 1);
        qdev_prop_set_uint32(DEVICE(xhci), "p3", 1);
        qdev_prop_set_uint32(DEVICE(xhci), "intrs", 1);
        /*
         * MaxSlots is not public; 64 is QEMU's limit. It must be set here:
         * the property's default does not reach an xHCI inside DWC3.
         */
        qdev_prop_set_uint32(DEVICE(xhci), "slots", 64);
        object_property_set_link(OBJECT(xhci), "dma",
                                 OBJECT(&pci->bus_master_container_region),
                                 &error_abort);
        if (!sysbus_realize(SYS_BUS_DEVICE(&s->usb[i]), errp)) {
            return;
        }
        memory_region_add_subregion(&s->bar1, RP1_USBHOST_BASE(i),
                        sysbus_mmio_get_region(SYS_BUS_DEVICE(&s->usb[i]), 0));
        sysbus_connect_irq(xhci, 0, qdev_get_gpio_in_named(dev, "irq",
                           i ? RP1_INT_USBHOST1_0 : RP1_INT_USBHOST0_0));
    }

    pci_register_bar(pci, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar0);
    pci_register_bar(pci, 1, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar1);
    pci_register_bar(pci, 2, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar2);

    /* Capabilities as lspci shows them: PM at 0x40, PCIe at 0x70 */
    if (pci_pm_init(pci, 0x40, errp) < 0) {
        return;
    }
    ret = pcie_endpoint_cap_init(pci, 0x70);
    if (ret < 0) {
        error_setg(errp, "rp1: cannot add the PCIe capability");
        return;
    }
    /*
     * MSI-X: the public lspci output stops before this capability, so its
     * position and the table's place in BAR0 are this model's choice.
     */
    ret = msix_init(pci, RP1_NUM_VECTORS, &s->bar0, 0, 0, &s->bar0, 0,
                    0x2000, 0xb0, errp);
    if (ret < 0) {
        return;
    }
    for (int i = 0; i < RP1_NUM_VECTORS; i++) {
        msix_vector_use(pci, i);
    }
    rp1_reset_blocks(s);
}

static void rp1_exit(PCIDevice *pci)
{
    msix_uninit(pci, &RP1(pci)->bar0, &RP1(pci)->bar0);
}

static const VMStateDescription vmstate_rp1_block = {
    .name = "rp1/block",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_UINT32_ARRAY(regs, RP1Block, 1024),
        VMSTATE_END_OF_LIST()
    },
};

static const VMStateDescription vmstate_rp1 = {
    .name = TYPE_RP1,
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_PCI_DEVICE(parent_obj, RP1State),
        VMSTATE_MSIX(parent_obj, RP1State),
        VMSTATE_STRUCT_ARRAY(blocks, RP1State, RP1_NUM_BLOCKS, 1,
                             vmstate_rp1_block, RP1Block),
        VMSTATE_UINT64(lines, RP1State),
        VMSTATE_UINT64(awaiting_iack, RP1State),
        VMSTATE_UINT64(gpio_external, RP1State),
        VMSTATE_UINT64(gpio_driven, RP1State),
        VMSTATE_UINT64(gpio_last_in, RP1State),
        VMSTATE_END_OF_LIST()
    },
};

static void rp1_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize = rp1_realize;
    k->exit = rp1_exit;
    k->vendor_id = RP1_PCI_VENDOR_ID;
    k->device_id = RP1_PCI_DEVICE_ID;
    k->revision = RP1_PCI_REVISION;
    /* lspci: "Ethernet controller [0200]" */
    k->class_id = PCI_CLASS_NETWORK_ETHERNET;
    dc->desc = "Raspberry Pi RP1 south bridge";
    dc->vmsd = &vmstate_rp1;
    device_class_set_legacy_reset(dc, rp1_reset);
    set_bit(DEVICE_CATEGORY_BRIDGE, dc->categories);
}

static const TypeInfo rp1_info = {
    .name = TYPE_RP1,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(RP1State),
    .instance_init = rp1_init,
    .class_init = rp1_class_init,
    .interfaces = (const InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { }
    },
};

static void rp1_register_types(void)
{
    type_register_static(&rp1_info);
}

type_init(rp1_register_types)
