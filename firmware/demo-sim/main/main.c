// Le'Casa demo simulator: makes any ESP32 look like a small bus power
// system (two Victron solar chargers, a SmartShunt, a MultiPlus and two
// BTHome sensors) so Le'Casa has something live to show at a shop
// counter or a conference table.
//
// One radio, many devices: the board takes turns advertising as each
// device, each from its own random static address, a fraction of a
// second at a time.
//
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "driver/gpio.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include "devices.h"
#include "sim.h"

static const char *TAG = "demo-sim";

// How long each device holds the radio before the next one takes over.
// Six devices at 120 ms means each is heard about every 0.7 s.
#define DWELL_MS 120

// Boot button: GPIO0 on the ESP32 and S3, GPIO9 on the C3, C6 and H2.
#if CONFIG_IDF_TARGET_ESP32 || CONFIG_IDF_TARGET_ESP32S3
#define BUTTON_GPIO GPIO_NUM_0
#else
#define BUTTON_GPIO GPIO_NUM_9
#endif

static sim_t sim;
static SemaphoreHandle_t sim_lock;
static EventGroupHandle_t gap_events;

#define EV_ADV_DATA BIT0
#define EV_RSP_DATA BIT1
#define EV_START BIT2
#define EV_STOP BIT3
#define EV_ADDR BIT4
#define EV_FAIL BIT7

static void gap_cb(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *p)
{
    EventBits_t bit = 0;
    esp_bt_status_t st = ESP_BT_STATUS_SUCCESS;
    switch (event) {
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
        bit = EV_ADV_DATA;
        st = p->adv_data_raw_cmpl.status;
        break;
    case ESP_GAP_BLE_SCAN_RSP_DATA_RAW_SET_COMPLETE_EVT:
        bit = EV_RSP_DATA;
        st = p->scan_rsp_data_raw_cmpl.status;
        break;
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        bit = EV_START;
        st = p->adv_start_cmpl.status;
        break;
    case ESP_GAP_BLE_ADV_STOP_COMPLETE_EVT:
        bit = EV_STOP;
        st = p->adv_stop_cmpl.status;
        break;
    case ESP_GAP_BLE_SET_STATIC_RAND_ADDR_EVT:
        bit = EV_ADDR;
        st = p->set_rand_addr_cmpl.status;
        break;
    default:
        return;
    }
    if (st != ESP_BT_STATUS_SUCCESS) {
        ESP_LOGW(TAG, "gap event %d failed: %d", event, st);
        bit |= EV_FAIL;
    }
    xEventGroupSetBits(gap_events, bit);
}

static bool wait_for(EventBits_t bit)
{
    EventBits_t got = xEventGroupWaitBits(gap_events, bit | EV_FAIL, pdTRUE,
                                          pdFALSE, pdMS_TO_TICKS(500));
    return (got & bit) && !(got & EV_FAIL);
}

// Slot i's address: the board's own MAC with the slot mixed in, marked as
// a random static address (top two bits set). Stable across reboots, so
// Le'Casa keeps each card's name, key and place on the dashboard.
static void slot_addr(size_t i, esp_bd_addr_t out)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_BT);
    memcpy(out, mac, 6);
    out[0] = (out[0] ^ (uint8_t)(0x5A + i * 0x11)) | 0xC0;
    out[5] = out[5] ^ (uint8_t)(i * 0x3B);
}

static esp_ble_adv_params_t adv_params = {
    .adv_int_min = 0x20,  // 20 ms
    .adv_int_max = 0x30,  // 30 ms
    .adv_type = ADV_TYPE_SCAN_IND,  // scannable, not connectable
    .own_addr_type = BLE_ADDR_TYPE_RANDOM,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static void advertise_slot(size_t i)
{
    uint8_t adv[ADV_MAX], rsp[ADV_MAX];
    size_t adv_len = 0, rsp_len = 0;
    xSemaphoreTake(sim_lock, portMAX_DELAY);
    bool ok = demo_device_frames(&demo_devices[i], &sim, adv, &adv_len, rsp,
                                 &rsp_len);
    xSemaphoreGive(sim_lock);
    if (!ok) return;

    esp_bd_addr_t addr;
    slot_addr(i, addr);

    esp_ble_gap_stop_advertising();
    wait_for(EV_STOP);  // fails harmlessly the very first time
    esp_ble_gap_set_rand_addr(addr);
    if (!wait_for(EV_ADDR)) return;
    esp_ble_gap_config_adv_data_raw(adv, adv_len);
    if (!wait_for(EV_ADV_DATA)) return;
    if (rsp_len == 0) {
        // BTHome sensors put everything in the advert. A single zero
        // byte is an empty scan response (a zero-length AD structure
        // ends the data), and avoids a zero-length raw config.
        rsp[0] = 0;
        rsp_len = 1;
    }
    esp_ble_gap_config_scan_rsp_data_raw(rsp, rsp_len);
    if (!wait_for(EV_RSP_DATA)) return;
    esp_ble_gap_start_advertising(&adv_params);
    wait_for(EV_START);
}

static void radio_task(void *arg)
{
    for (size_t i = 0;; i = (i + 1) % demo_device_count) {
        advertise_slot(i);
        vTaskDelay(pdMS_TO_TICKS(DWELL_MS));
    }
}

static void sim_task(void *arg)
{
    int64_t last = esp_timer_get_time();
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(100));
        int64_t now = esp_timer_get_time();
        xSemaphoreTake(sim_lock, portMAX_DELAY);
        sim_step(&sim, (now - last) / 1e6f);
        xSemaphoreGive(sim_lock);
        last = now;
    }
}

static void print_status(void)
{
    xSemaphoreTake(sim_lock, portMAX_DELAY);
    sim_t s = sim;
    xSemaphoreGive(sim_lock);
    solar_reading_t roof, port;
    sim_roof(&s, &roof);
    sim_portable(&s, &port);
    printf("scene %-8s  %02d:%02d  sun %4.0f W + %3.0f W  battery %5.1f %% "
           "%5.2f V %+6.1f A  AC %4.0f W%s\n",
           scene_name(s.scene), (int)s.hour, (int)((s.hour - (int)s.hour) * 60),
           roof.solar_w, port.solar_w, s.soc, s.battery_v, s.battery_a,
           s.ac_load_w + s.ac_event_w, s.shore ? "  (shore power)" : "");
}

static void print_keys(void)
{
    printf("\nDemo devices (paste each key into Le'Casa once):\n");
    for (size_t i = 0; i < demo_device_count; i++) {
        demo_device_t *d = &demo_devices[i];
        esp_bd_addr_t a;
        slot_addr(i, a);
        printf("  %-15s %02X:%02X:%02X:%02X:%02X:%02X  ", d->name, a[0], a[1],
               a[2], a[3], a[4], a[5]);
        if (d->kind == DEV_CABIN || d->kind == DEV_FRIDGE) {
            printf("BTHome, no key\n");
            continue;
        }
        for (int k = 0; k < 16; k++) printf("%02x", d->key[k]);
        printf("\n");
    }
    printf("\nCommands: scene <auto|sunny|cloudy|night|big-load|shore>, "
           "kettle, soc <0-100>, day <minutes>, status, keys.\n"
           "The BOOT button steps through the scenes.\n\n");
}

static void set_scene(scene_t sc)
{
    xSemaphoreTake(sim_lock, portMAX_DELAY);
    sim_set_scene(&sim, sc);
    xSemaphoreGive(sim_lock);
    printf("scene: %s\n", scene_name(sc));
}

static void handle_line(char *line)
{
    char *arg = strchr(line, ' ');
    if (arg) *arg++ = 0;
    if (!strcasecmp(line, "scene") && arg) {
        for (scene_t sc = 0; sc < SCENE_COUNT; sc++) {
            if (!strcasecmp(arg, scene_name(sc))) {
                set_scene(sc);
                return;
            }
        }
        printf("unknown scene '%s'\n", arg);
    } else if (!strcasecmp(line, "kettle")) {
        xSemaphoreTake(sim_lock, portMAX_DELAY);
        sim_kettle(&sim);
        xSemaphoreGive(sim_lock);
        printf("kettle on for 20 s\n");
    } else if (!strcasecmp(line, "soc") && arg) {
        xSemaphoreTake(sim_lock, portMAX_DELAY);
        sim.soc = atof(arg);
        xSemaphoreGive(sim_lock);
    } else if (!strcasecmp(line, "day") && arg && atof(arg) > 0) {
        xSemaphoreTake(sim_lock, portMAX_DELAY);
        sim.day_minutes = atof(arg);
        xSemaphoreGive(sim_lock);
        printf("one demo day now lasts %s minutes\n", arg);
    } else if (!strcasecmp(line, "keys")) {
        print_keys();
    } else if (*line) {
        print_status();
    }
}

static void console_task(void *arg)
{
    char line[64];
    size_t n = 0;
    int last_button = 1;
    int64_t last_status = 0;
    for (;;) {
        int c = getchar();
        if (c == '\n' || c == '\r') {
            line[n] = 0;
            if (n) handle_line(line);
            n = 0;
        } else if (c >= 0 && n < sizeof line - 1) {
            line[n++] = (char)c;
        }

        int b = gpio_get_level(BUTTON_GPIO);
        if (b == 0 && last_button == 1) {
            set_scene((scene_t)((sim.scene + 1) % SCENE_COUNT));
        }
        last_button = b;

        int64_t now = esp_timer_get_time();
        if (now - last_status > 10 * 1000000LL) {
            print_status();
            last_status = now;
        }
        if (c < 0) vTaskDelay(pdMS_TO_TICKS(30));
    }
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    gpio_config_t btn = {
        .pin_bit_mask = 1ULL << BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    gpio_config(&btn);

    sim_lock = xSemaphoreCreateMutex();
    gap_events = xEventGroupCreate();
    sim_defaults(&sim);
    sim.seed ^= (uint32_t)esp_random();
    sim_init(&sim);

#if CONFIG_IDF_TARGET_ESP32
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));
#endif
    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_cb));

    printf("\nLe'Casa demo simulator: %u devices\n",
           (unsigned)demo_device_count);
    print_keys();

    xTaskCreate(sim_task, "sim", 4096, NULL, 5, NULL);
    xTaskCreate(radio_task, "radio", 4096, NULL, 6, NULL);
    xTaskCreate(console_task, "console", 4096, NULL, 3, NULL);
}
