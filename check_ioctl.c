#include <stdio.h>
#include <linux/spi/spidev.h>
#include <linux/gpio.h>
#include <sys/ioctl.h>

int main() {
    printf("SPI_IOC_WR_MODE: 0x%08lx\n", SPI_IOC_WR_MODE);
    printf("SPI_IOC_WR_BITS_PER_WORD: 0x%08lx\n", SPI_IOC_WR_BITS_PER_WORD);
    printf("SPI_IOC_WR_MAX_SPEED_HZ: 0x%08lx\n", SPI_IOC_WR_MAX_SPEED_HZ);
    printf("GPIO_GET_LINEHANDLE_IOCTL: 0x%08lx\n", GPIO_GET_LINEHANDLE_IOCTL);
    printf("GPIOHANDLE_SET_LINE_VALUES_IOCTL: 0x%08lx\n", GPIOHANDLE_SET_LINE_VALUES_IOCTL);
    printf("GPIOHANDLE_GET_LINE_VALUES_IOCTL: 0x%08lx\n", GPIOHANDLE_GET_LINE_VALUES_IOCTL);
    return 0;
}
