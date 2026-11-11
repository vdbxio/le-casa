idf_component_register(
    SRCS "main.c" "frames.c" "sim.c" "devices.c" "aes_idf.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES bt nvs_flash mbedtls driver esp_timer
)
