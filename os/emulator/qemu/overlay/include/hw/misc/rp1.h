/*
 * Raspberry Pi RP1 south bridge
 *
 * Copyright (c) 2026 The ElixirSSI authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_RP1_H
#define HW_MISC_RP1_H

#include "hw/pci/pci_device.h"
#include "hw/char/pl011.h"
#include "hw/net/cadence_gem.h"
#include "hw/usb/hcd-dwc3.h"
#include "qom/object.h"

#define TYPE_RP1 "rp1"
OBJECT_DECLARE_SIMPLE_TYPE(RP1State, RP1)

/* PCI identity, from Linux's rp1 driver and lspci on a Raspberry Pi 5 */
#define RP1_PCI_VENDOR_ID       0x1de4
#define RP1_PCI_DEVICE_ID       0x0001
#define RP1_PCI_REVISION        2               /* C0 */
#define RP1_C0_CHIP_ID          0x20001927
#define RP1_PLATFORM_ASIC       (1 << 1)

/* The three BARs, as lspci shows them: all 32-bit, non-prefetchable */
#define RP1_BAR0_SIZE           (16 * KiB)      /* MSI-X table and PBA */
#define RP1_BAR1_SIZE           (4 * MiB)       /* peripherals */
#define RP1_BAR2_SIZE           (64 * KiB)      /* shared SRAM */

/* MSI-X: the datasheet's MSIX_CFG_0..63; Linux uses the first 61 */
#define RP1_NUM_VECTORS         64
#define RP1_NUM_IRQS            61

#define RP1_NUM_UARTS           6
#define RP1_NUM_USB             2
#define RP1_NUM_GPIO_BANKS      3
#define RP1_NUM_GPIOS           54

/* A register block with the datasheet's atomic aliases (2.4) */
typedef struct RP1Block {
    MemoryRegion iomem;
    struct RP1State *rp1;
    int kind;
    int index;
    uint32_t regs[1024];
} RP1Block;

enum {
    RP1_BLK_CLOCKS_MAIN,
    RP1_BLK_CLOCKS_VIDEO,
    RP1_BLK_PLL_SYS,
    RP1_BLK_PLL_AUDIO,
    RP1_BLK_PLL_VIDEO,
    RP1_BLK_IO_BANK0,
    RP1_BLK_IO_BANK1,
    RP1_BLK_IO_BANK2,
    RP1_BLK_SYS_RIO0,
    RP1_BLK_SYS_RIO1,
    RP1_BLK_SYS_RIO2,
    RP1_BLK_PADS_BANK0,
    RP1_BLK_PADS_BANK1,
    RP1_BLK_PADS_BANK2,
    RP1_BLK_ETH_CFG,
    RP1_BLK_PCIE_CFG,
    RP1_NUM_BLOCKS
};

struct RP1State {
    /*< private >*/
    PCIDevice parent_obj;

    /*< public >*/
    MemoryRegion bar0;
    MemoryRegion bar1;
    MemoryRegion bar2;
    MemoryRegion unimp;
    MemoryRegion sysinfo;

    RP1Block blocks[RP1_NUM_BLOCKS];
    PL011State uart[RP1_NUM_UARTS];
    CadenceGEMState eth;
    USBDWC3 usb[RP1_NUM_USB];

    /* Interrupt lines into MSIX_CFG (6.2) */
    uint64_t lines;
    uint64_t awaiting_iack;

    /* The level each GPIO's pad presents when nothing drives it */
    uint64_t gpio_external;
    uint64_t gpio_driven;
    /* Inputs last seen, for the edge events */
    uint64_t gpio_last_in;
};

#endif
