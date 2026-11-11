// AES block for the ESP32 build (mbedTLS, hardware-accelerated).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "mbedtls/aes.h"

#include "frames.h"

void aes128_encrypt_block(const uint8_t key[16], const uint8_t in[16],
                          uint8_t out[16])
{
    mbedtls_aes_context c;
    mbedtls_aes_init(&c);
    mbedtls_aes_setkey_enc(&c, key, 128);
    mbedtls_aes_crypt_ecb(&c, MBEDTLS_AES_ENCRYPT, in, out);
    mbedtls_aes_free(&c);
}
