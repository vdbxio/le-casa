// AES block for the laptop build of the frame builders (OpenSSL).
// SPDX-License-Identifier: GPL-3.0-or-later
#include <openssl/evp.h>

#include "../main/frames.h"

void aes128_encrypt_block(const uint8_t key[16], const uint8_t in[16],
                          uint8_t out[16])
{
    EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
    int n = 0;
    EVP_EncryptInit_ex(c, EVP_aes_128_ecb(), NULL, key, NULL);
    EVP_CIPHER_CTX_set_padding(c, 0);
    EVP_EncryptUpdate(c, out, &n, in, 16);
    EVP_CIPHER_CTX_free(c);
}
