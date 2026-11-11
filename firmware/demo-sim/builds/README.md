# Prebuilt demo-sim firmware

Built with PlatformIO (Espressif 32 55.3.38, ESP-IDF 5.5.4) from commit 66bb3e1.

## esp32-c6

Flash the all-in-one image at 0x0:

```bash
esptool.py --chip esp32c6 write_flash 0x0 builds/esp32-c6/firmware.factory.bin
```

Or flash the parts separately: bootloader.bin at 0x0, partitions.bin at 0x8000, firmware.bin at 0x10000.

These files are snapshots. Rebuild with `pio run -e esp32-c6` after changing the source.
