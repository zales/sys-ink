/*
 * Prints the ioctl request numbers the daemon uses, as the kernel headers
 * define them, to check against the values derived in the Zig sources.
 *
 * The Zig side computes most of these from struct sizes (see iowr() in
 * src/gpio_native.zig and NVME_IOCTL_ADMIN_CMD in src/system_ops.zig), so a
 * layout mismatch shows up here as a differing number. Build and run on the
 * target, or cross-compile with any Linux toolchain:
 *
 *     zig cc -target aarch64-linux-musl -o check_ioctl tools/check_ioctl.c
 */
#include <stdio.h>
#include <linux/gpio.h>
#include <linux/nvme_ioctl.h>
#include <linux/spi/spidev.h>
#include <sys/ioctl.h>

int main(void) {
    /* src/waveshare_epd/epdconfig.zig */
    printf("SPI_IOC_WR_MODE:               0x%08lx\n", (unsigned long)SPI_IOC_WR_MODE);
    printf("SPI_IOC_WR_BITS_PER_WORD:      0x%08lx\n", (unsigned long)SPI_IOC_WR_BITS_PER_WORD);
    printf("SPI_IOC_WR_MAX_SPEED_HZ:       0x%08lx\n", (unsigned long)SPI_IOC_WR_MAX_SPEED_HZ);

    /* src/config.zig */
    printf("GPIO_GET_CHIPINFO_IOCTL:       0x%08lx\n", (unsigned long)GPIO_GET_CHIPINFO_IOCTL);

    /* src/gpio_native.zig, v2 ABI */
    printf("GPIO_V2_GET_LINE_IOCTL:        0x%08lx\n", (unsigned long)GPIO_V2_GET_LINE_IOCTL);
    printf("GPIO_V2_LINE_GET_VALUES_IOCTL: 0x%08lx\n", (unsigned long)GPIO_V2_LINE_GET_VALUES_IOCTL);
    printf("GPIO_V2_LINE_SET_VALUES_IOCTL: 0x%08lx\n", (unsigned long)GPIO_V2_LINE_SET_VALUES_IOCTL);

    /* src/system_ops.zig */
    printf("NVME_IOCTL_ADMIN_CMD:          0x%08lx\n", (unsigned long)NVME_IOCTL_ADMIN_CMD);
    return 0;
}
