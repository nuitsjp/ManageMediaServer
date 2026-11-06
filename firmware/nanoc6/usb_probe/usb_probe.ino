// USB-only diagnostic coordinator. Wi-Fi/MQTT will be added after identification.
// Arduino-ESP32 3.3.6 / ESP32-C6 / 4 MiB / Zigbee ZCZR.
#include <Arduino.h>
#include <esp_zigbee_core.h>
#include <ha/esp_zigbee_ha_standard.h>
#include <zdo/esp_zigbee_zdo_command.h>
#include <zcl/esp_zigbee_zcl_command.h>
#include <nvs_flash.h>

#ifndef ZIGBEE_MODE_ZCZR
#error Select Zigbee ZCZR coordinator/router mode
#endif

constexpr uint8_t LOCAL_EP = 1;
constexpr size_t MAX_DEVICES = 32;
constexpr uint8_t MAX_ENDPOINTS = 8;
constexpr uint8_t MAX_CLUSTERS = 32;
constexpr uint8_t MAX_RAW = 96;
constexpr uint8_t CHANNEL = 20;
constexpr uint8_t MAX_CHILDREN = 20;

struct Device {
  bool used;
  uint16_t address;
  uint8_t ieee[8];
};
enum EventKind : uint8_t { READY, ANNOUNCE, DESCRIPTOR, ATTRIBUTE, CUSTOM, RESULT };
struct Event {
  EventKind kind;
  uint32_t uptime;
  uint16_t address, cluster, attribute, profile, device;
  uint8_t endpoint, type, status, size, in_count, out_count, command;
  uint8_t ieee[8];
  uint8_t raw[MAX_RAW];
  uint16_t clusters[MAX_CLUSTERS];
  bool truncated, report;
};
enum JobKind : uint8_t { ACTIVE_ENDPOINTS, SIMPLE_DESCRIPTOR, READ_ATTRIBUTES, BIND_CLUSTER };
struct Job { JobKind kind; uint16_t address; uint8_t endpoint; uint16_t cluster; };

static Device devices[MAX_DEVICES] = {};
static QueueHandle_t events, jobs;
static volatile bool network_ready = false;
static volatile uint32_t event_drops = 0, job_drops = 0;

static void post(Event &event) {
  event.uptime = millis();
  if (xQueueSend(events, &event, 0) != pdTRUE) ++event_drops;
}
static void schedule(JobKind kind, uint16_t address, uint8_t endpoint = 0, uint16_t cluster = 0) {
  Job job = {kind, address, endpoint, cluster};
  if (xQueueSend(jobs, &job, 0) != pdTRUE) ++job_drops;
}
static Device *remember(uint16_t address, const uint8_t *ieee) {
  Device *empty = nullptr;
  for (auto &device : devices) {
    if (!device.used) { if (!empty) empty = &device; continue; }
    if (memcmp(device.ieee, ieee, 8) == 0) { device.address = address; return &device; }
  }
  if (!empty) return nullptr;
  empty->used = true;
  empty->address = address;
  memcpy(empty->ieee, ieee, 8);
  return empty;
}
static void address_event(Event &event, uint16_t address, uint8_t endpoint) {
  event.address = address;
  event.endpoint = endpoint;
  // The stack owns the NWK->IEEE cache. Never identify a sensor only by NWK address.
  if (esp_zb_ieee_address_by_short(address, event.ieee) != ESP_OK) {
    memset(event.ieee, 0, 8);
    for (const auto &device : devices) {
      if (device.used && device.address == address) { memcpy(event.ieee, device.ieee, 8); break; }
    }
  }
}
static void attribute_event(uint16_t address, uint8_t endpoint, uint16_t cluster,
                            const esp_zb_zcl_attribute_t &attribute, uint8_t status, bool report) {
  Event event = {};
  event.kind = ATTRIBUTE;
  address_event(event, address, endpoint);
  event.cluster = cluster;
  event.attribute = attribute.id;
  event.type = attribute.data.type;
  event.status = status;
  event.report = report;
  if (status == 0 && attribute.data.value) {
    event.size = min(static_cast<size_t>(attribute.data.size), static_cast<size_t>(MAX_RAW));
    event.truncated = attribute.data.size > MAX_RAW;
    memcpy(event.raw, attribute.data.value, event.size);
  }
  post(event);
}
static esp_err_t action_handler(esp_zb_core_action_callback_id_t id, const void *data) {
  if (!data) return ESP_ERR_INVALID_ARG;
  if (id == ESP_ZB_CORE_REPORT_ATTR_CB_ID) {
    const auto *message = static_cast<const esp_zb_zcl_report_attr_message_t *>(data);
    attribute_event(message->src_address.u.short_addr, message->src_endpoint, message->cluster,
                    message->attribute, message->status, true);
  } else if (id == ESP_ZB_CORE_CMD_READ_ATTR_RESP_CB_ID) {
    const auto *message = static_cast<const esp_zb_zcl_cmd_read_attr_resp_message_t *>(data);
    if (message->info.status == ESP_ZB_ZCL_STATUS_SUCCESS) {
      for (auto *item = message->variables; item; item = item->next) {
        attribute_event(message->info.src_address.u.short_addr, message->info.src_endpoint,
                        message->info.cluster, item->attribute, item->status, false);
      }
    }
  } else if (id == ESP_ZB_CORE_CMD_CUSTOM_CLUSTER_REQ_CB_ID) {
    const auto *message = static_cast<const esp_zb_zcl_custom_cluster_command_message_t *>(data);
    Event event = {};
    event.kind = CUSTOM;
    address_event(event, message->info.src_address.u.short_addr, message->info.src_endpoint);
    event.cluster = message->info.cluster;
    event.command = message->info.command.id;
    event.size = min(static_cast<size_t>(message->data.size), static_cast<size_t>(MAX_RAW));
    event.truncated = message->data.size > MAX_RAW;
    if (message->data.value) memcpy(event.raw, message->data.value, event.size);
    post(event); // Tuya DP bytes are evidence, not guessed temperature/humidity values.
  }
  return ESP_OK;
}
static void bind_callback(esp_zb_zdp_status_t status, void *context) {
  Event event = {};
  event.kind = RESULT;
  uintptr_t packed = reinterpret_cast<uintptr_t>(context);
  event.address = packed >> 16;
  event.cluster = packed & 0xffff;
  event.status = status;
  post(event);
}
static void descriptor_callback(esp_zb_zdp_status_t status, esp_zb_af_simple_desc_1_1_t *desc, void *context) {
  uint16_t address = reinterpret_cast<uintptr_t>(context);
  if (status != ESP_ZB_ZDP_STATUS_SUCCESS || !desc) return;
  Event event = {};
  event.kind = DESCRIPTOR;
  address_event(event, address, desc->endpoint);
  event.profile = desc->app_profile_id;
  event.device = desc->app_device_id;
  event.in_count = min(desc->app_input_cluster_count, MAX_CLUSTERS);
  event.out_count = min(desc->app_output_cluster_count, static_cast<uint8_t>(MAX_CLUSTERS - event.in_count));
  event.truncated = desc->app_input_cluster_count + desc->app_output_cluster_count > MAX_CLUSTERS;
  for (uint8_t i = 0; i < event.in_count; ++i) event.clusters[i] = desc->app_cluster_list[i];
  for (uint8_t i = 0; i < event.out_count; ++i) {
    event.clusters[event.in_count + i] = desc->app_cluster_list[desc->app_input_cluster_count + i];
  }
  post(event);
  schedule(READ_ATTRIBUTES, address, desc->endpoint, 0x0000);
  for (uint8_t i = 0; i < desc->app_input_cluster_count; ++i) {
    uint16_t cluster = desc->app_cluster_list[i];
    if (cluster == 0x0402 || cluster == 0x0405 || cluster == 0x0001) {
      schedule(READ_ATTRIBUTES, address, desc->endpoint, cluster);
      schedule(BIND_CLUSTER, address, desc->endpoint, cluster);
    }
  }
}
static void endpoints_callback(esp_zb_zdp_status_t status, uint8_t count, uint8_t *list, void *context) {
  if (status != ESP_ZB_ZDP_STATUS_SUCCESS || !list) return;
  uint16_t address = reinterpret_cast<uintptr_t>(context);
  for (uint8_t i = 0; i < min(count, MAX_ENDPOINTS); ++i) schedule(SIMPLE_DESCRIPTOR, address, list[i]);
}
static void ready() {
  esp_zb_bdb_close_network();
  network_ready = true;
  Event event = {};
  event.kind = READY;
  post(event);
}
extern "C" void esp_zb_app_signal_handler(esp_zb_app_signal_t *signal) {
  auto kind = static_cast<esp_zb_app_signal_type_t>(*signal->p_app_signal);
  if (kind == ESP_ZB_ZDO_SIGNAL_SKIP_STARTUP) {
    esp_zb_bdb_start_top_level_commissioning(ESP_ZB_BDB_MODE_INITIALIZATION);
  } else if (kind == ESP_ZB_BDB_SIGNAL_DEVICE_FIRST_START || kind == ESP_ZB_BDB_SIGNAL_DEVICE_REBOOT) {
    if (signal->esp_err_status != ESP_OK) return;
    if (esp_zb_bdb_is_factory_new()) esp_zb_bdb_start_top_level_commissioning(ESP_ZB_BDB_MODE_NETWORK_FORMATION);
    else ready();
  } else if (kind == ESP_ZB_BDB_SIGNAL_FORMATION && signal->esp_err_status == ESP_OK) {
    ready(); // No automatic NETWORK_STEERING or permit-join on boot.
  } else if (kind == ESP_ZB_ZDO_SIGNAL_DEVICE_ANNCE) {
    const auto *device = static_cast<esp_zb_zdo_signal_device_annce_params_t *>(esp_zb_app_signal_get_params(signal->p_app_signal));
    if (!device) return;
    Event event = {};
    event.kind = ANNOUNCE;
    event.address = device->device_short_addr;
    memcpy(event.ieee, device->ieee_addr, 8);
    event.status = remember(event.address, event.ieee) ? 0 : 1;
    post(event);
    if (event.status == 0) schedule(ACTIVE_ENDPOINTS, event.address);
  }
}
static void zigbee_task(void *) {
  esp_zb_cfg_t config = {};
  config.esp_zb_role = ESP_ZB_DEVICE_TYPE_COORDINATOR;
  config.install_code_policy = false;
  config.nwk_cfg.zczr_cfg.max_children = MAX_CHILDREN;
  esp_zb_overall_network_size_set(64);
  esp_zb_init(&config);
  esp_zb_ep_list_t *endpoints = esp_zb_ep_list_create();
  esp_zb_cluster_list_t *clusters = esp_zb_zcl_cluster_list_create();
  esp_zb_basic_cluster_cfg_t basic = {};
  basic.zcl_version = 3;
  basic.power_source = 0x04; // DC power
  esp_zb_cluster_list_add_basic_cluster(clusters, esp_zb_basic_cluster_create(&basic), ESP_ZB_ZCL_CLUSTER_SERVER_ROLE);
  esp_zb_cluster_list_add_basic_cluster(clusters, esp_zb_zcl_attr_list_create(0x0000), ESP_ZB_ZCL_CLUSTER_CLIENT_ROLE);
  esp_zb_cluster_list_add_temperature_meas_cluster(clusters, esp_zb_zcl_attr_list_create(0x0402), ESP_ZB_ZCL_CLUSTER_CLIENT_ROLE);
  esp_zb_cluster_list_add_humidity_meas_cluster(clusters, esp_zb_zcl_attr_list_create(0x0405), ESP_ZB_ZCL_CLUSTER_CLIENT_ROLE);
  esp_zb_cluster_list_add_power_config_cluster(clusters, esp_zb_zcl_attr_list_create(0x0001), ESP_ZB_ZCL_CLUSTER_CLIENT_ROLE);
  esp_zb_cluster_list_add_custom_cluster(clusters, esp_zb_zcl_attr_list_create(0xef00), ESP_ZB_ZCL_CLUSTER_CLIENT_ROLE);
  esp_zb_endpoint_config_t endpoint = {};
  endpoint.endpoint = LOCAL_EP;
  endpoint.app_profile_id = 0x0104;
  endpoint.app_device_id = 0x0007; // Combined interface
  esp_zb_ep_list_add_ep(endpoints, clusters, endpoint);
  ESP_ERROR_CHECK(esp_zb_device_register(endpoints));
  esp_zb_core_action_handler_register(action_handler);
  ESP_ERROR_CHECK(esp_zb_set_primary_network_channel_set(1UL << CHANNEL));
  ESP_ERROR_CHECK(esp_zb_start(false));
  esp_zb_stack_main_loop();
}
static void run_job(const Job &job) {
  if (job.kind == ACTIVE_ENDPOINTS) {
    esp_zb_zdo_active_ep_req_param_t request = {};
    request.addr_of_interest = job.address;
    esp_zb_zdo_active_ep_req(&request, endpoints_callback, reinterpret_cast<void *>(static_cast<uintptr_t>(job.address)));
  } else if (job.kind == SIMPLE_DESCRIPTOR) {
    esp_zb_zdo_simple_desc_req_param_t request = {};
    request.addr_of_interest = job.address;
    request.endpoint = job.endpoint;
    esp_zb_zdo_simple_desc_req(&request, descriptor_callback, reinterpret_cast<void *>(static_cast<uintptr_t>(job.address)));
  } else if (job.kind == READ_ATTRIBUTES) {
    uint16_t basic[] = {0x0004, 0x0000, 0x0001, 0x0005, 0x0007, 0xfffe, 0x4000};
    uint16_t power[] = {0x0020, 0x0021};
    uint16_t value[] = {0x0000};
    esp_zb_zcl_read_attr_cmd_t request = {};
    request.zcl_basic_cmd.dst_addr_u.addr_short = job.address;
    request.zcl_basic_cmd.dst_endpoint = job.endpoint;
    request.zcl_basic_cmd.src_endpoint = LOCAL_EP;
    request.address_mode = ESP_ZB_APS_ADDR_MODE_16_ENDP_PRESENT;
    request.clusterID = job.cluster;
    request.attr_field = job.cluster == 0 ? basic : job.cluster == 1 ? power : value;
    request.attr_number = job.cluster == 0 ? 7 : job.cluster == 1 ? 2 : 1;
    esp_zb_zcl_read_attr_cmd_req(&request);
  } else if (job.kind == BIND_CLUSTER) {
    esp_zb_zdo_bind_req_param_t request = {};
    if (esp_zb_ieee_address_by_short(job.address, request.src_address) != ESP_OK) return;
    request.req_dst_addr = job.address;
    request.src_endp = job.endpoint;
    request.cluster_id = job.cluster;
    request.dst_addr_mode = ESP_ZB_ZDO_BIND_DST_ADDR_MODE_64_BIT_EXTENDED;
    esp_zb_get_long_address(request.dst_address_u.addr_long);
    request.dst_endp = LOCAL_EP;
    uintptr_t context = (static_cast<uintptr_t>(job.address) << 16) | job.cluster;
    esp_zb_zdo_device_bind_req(&request, bind_callback, reinterpret_cast<void *>(context));
  }
}
static void print_event(const Event &event) {
  static const char *names[] = {"ready", "announce", "descriptor", "attribute", "custom", "bind_result"};
  char ieee[17];
  for (int i = 0; i < 8; ++i) snprintf(ieee + i * 2, 3, "%02x", event.ieee[7-i]);
  Serial.printf("{\"v\":1,\"event\":\"%s\",\"uptime_ms\":%lu", names[event.kind], static_cast<unsigned long>(event.uptime));
  if (event.kind == READY) {
    Serial.printf(",\"firmware\":\"nanoc6-usb-probe-0.1\",\"channel\":%u,\"max_children\":%u,\"device_slots\":%u,\"join_open\":false",
                  CHANNEL, MAX_CHILDREN, static_cast<unsigned>(MAX_DEVICES));
  } else {
    Serial.printf(",\"ieee\":\"%s\",\"short\":%u,\"endpoint\":%u,\"status\":%u", ieee, event.address, event.endpoint, event.status);
    if (event.kind == DESCRIPTOR) {
      Serial.printf(",\"profile\":%u,\"device\":%u,\"in_clusters\":[", event.profile, event.device);
      for (uint8_t i=0; i<event.in_count; ++i) Serial.printf("%s%u", i ? "," : "", event.clusters[i]);
      Serial.print("],\"out_clusters\":[");
      for (uint8_t i=0; i<event.out_count; ++i) Serial.printf("%s%u", i ? "," : "", event.clusters[event.in_count+i]);
      Serial.printf("],\"truncated\":%s", event.truncated ? "true" : "false");
    } else if (event.kind == ATTRIBUTE || event.kind == CUSTOM) {
      Serial.printf(",\"cluster\":%u,\"attribute\":%u,\"type\":%u,\"command\":%u,\"report\":%s,\"truncated\":%s,\"raw\":\"",
                    event.cluster, event.attribute, event.type, event.command, event.report ? "true" : "false", event.truncated ? "true" : "false");
      for (uint8_t i=0; i<event.size; ++i) Serial.printf("%02x", event.raw[i]);
      Serial.print('"');
    } else if (event.kind == RESULT) Serial.printf(",\"cluster\":%u", event.cluster);
  }
  Serial.printf(",\"event_drops\":%lu,\"job_drops\":%lu}\n", static_cast<unsigned long>(event_drops), static_cast<unsigned long>(job_drops));
}
void setup() {
  Serial.begin(115200);
  Serial.setTxTimeoutMs(20);
  events = xQueueCreate(64, sizeof(Event));
  jobs = xQueueCreate(128, sizeof(Job));
  if (!events || !jobs) abort();
  ESP_ERROR_CHECK(nvs_flash_init()); // Never erase NVS automatically.
  esp_zb_platform_config_t config = {};
  config.radio_config.radio_mode = ZB_RADIO_MODE_NATIVE;
  config.host_config.host_connection_mode = ZB_HOST_CONNECTION_MODE_NONE;
  ESP_ERROR_CHECK(esp_zb_platform_config(&config));
  xTaskCreate(zigbee_task, "zigbee", 6144, nullptr, 5, nullptr);
}
void loop() {
  Event event;
  while (xQueueReceive(events, &event, 0) == pdTRUE) print_event(event);
  static uint32_t last_job = 0;
  Job job;
  if (network_ready && millis() - last_job > 180 && xQueueReceive(jobs, &job, 0) == pdTRUE) {
    esp_zb_lock_acquire(portMAX_DELAY);
    run_job(job);
    esp_zb_lock_release();
    last_job = millis();
  }
  static char command[48];
  static size_t length = 0;
  while (Serial.available()) {
    char character = Serial.read();
    if (character == '\r') continue;
    if (character != '\n') {
      if (length < sizeof(command)-1) command[length++] = character;
      continue;
    }
    command[length] = 0;
    if (network_ready) {
      esp_zb_lock_acquire(portMAX_DELAY);
      if (strcmp(command, "join") == 0) {
        esp_zb_bdb_open_network(180);
        Serial.println("{\"v\":1,\"event\":\"permit_join\",\"seconds\":180}");
      } else if (strcmp(command, "close") == 0) {
        esp_zb_bdb_close_network();
        Serial.println("{\"v\":1,\"event\":\"permit_join\",\"seconds\":0}");
      } else if (strcmp(command, "status") == 0) {
        // Status must not change permit-join state.
        Serial.printf("{\"v\":1,\"event\":\"status\",\"ready\":true,\"channel\":%u,\"max_children\":%u,\"event_drops\":%lu,\"job_drops\":%lu}\n",
                      esp_zb_get_current_channel(), MAX_CHILDREN, static_cast<unsigned long>(event_drops), static_cast<unsigned long>(job_drops));
      } else if (strncmp(command, "interview ", 10) == 0) {
        char *end = nullptr;
        unsigned long address = strtoul(command+10, &end, 16);
        if (end != command+10 && *end == 0 && address > 0 && address < 0xfff8) schedule(ACTIVE_ENDPOINTS, address);
      }
      esp_zb_lock_release();
    }
    length = 0;
  }
  delay(5);
}
