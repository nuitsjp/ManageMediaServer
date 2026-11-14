#pragma once
#include "gateway_model.h"
#include "sensor_numbers.h"
#include <WiFi.h>
#include <Preferences.h>
#include <nvs.h>
#include <mqtt_client.h>
#include <esp_coexist.h>
#include <cJSON.h>
#include <atomic>
#include <time.h>

#if !CONFIG_ESP_COEX_SW_COEXIST_ENABLE
#error Wi-Fi / IEEE802154 software coexistence is required
#endif
// Only the network worker owns Fleet, Preferences, MQTT handles and in-flight state.
// Zigbee callbacks never wait for Wi-Fi, TLS, broker acknowledgements or flash writes.
static QueueHandle_t gateway_events, gateway_acks, number_requests;
static gateway::Fleet fleet;
static gateway::SensorNumbers sensor_numbers;
static bool number_storage_healthy = true;
struct NumberRequest { char ieee[17]; uint8_t number; bool query; };
static esp_mqtt_client_handle_t mqtt = nullptr;
static std::atomic<bool> mqtt_connected{false}, mqtt_reset{false}, discovery_reset{false}, join_requested{false};
static std::atomic<uint32_t> gateway_drops{0};
static std::atomic<bool> power_refresh_requested{false};
static uint32_t stale_drops = 0, unacked_retries = 0, received_attributes = 0;
static uint32_t power_reads = 0, power_config_requests = 0, power_config_successes = 0, power_config_failures = 0;
static gateway::PowerBudget power_budget;
static unsigned power_cursor = 0;
static const char *FIRMWARE_VERSION = "nanoc6-wifi-gateway-0.3";
static String wifi_ssid, wifi_password, mqtt_host, mqtt_user, mqtt_password, mqtt_ca;
static const char *ROOT_TOPIC = "smarthome/nanoc6";
static const char *GW_AVAIL = "smarthome/nanoc6/gateway/availability";
static const char *JOIN_TOPIC = "smarthome/nanoc6/gateway/join/set";
static const char *METRIC_NAMES[] = {"temperature", "humidity", "battery", "voltage"};
static const char *METRIC_UNITS[] = {"°C", "%", "%", "V"};
static const char *METRIC_CLASSES[] = {"temperature", "humidity", "battery", "voltage"};
struct InFlight { int id = -1; gateway::Metric *metric = nullptr; uint32_t received = 0; };
static InFlight in_flight[64];

static const char *json_string(cJSON *object, const char *key) {
  cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
  return cJSON_IsString(item) ? item->valuestring : "";
}
static void gw_log(const char *event) {
  if (Serial && xSemaphoreTake(usb_mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
    Serial.printf("{\"v\":1,\"event\":\"%s\"}\n", event);
    xSemaphoreGive(usb_mutex);
  }
}
static int gw_publish(const char *topic, const char *payload, bool retain = false, int qos = 1) {
  if (!mqtt || !mqtt_connected || esp_mqtt_client_get_outbox_size(mqtt) > 24576) return -1;
  return esp_mqtt_client_enqueue(mqtt, topic, payload, 0, qos, retain, true);
}
static int gw_json(const char *topic, cJSON *payload, bool retain = false, int qos = 1) {
  char *text = cJSON_PrintUnformatted(payload);
  int result = text ? gw_publish(topic, text, retain, qos) : -1;
  cJSON_free(text); cJSON_Delete(payload); return result;
}
static cJSON *gw_device(const gateway::Identity &id) {
  cJSON *device = cJSON_CreateObject(), *identifiers = cJSON_AddArrayToObject(device, "identifiers");
  String identifier = String("nanoc6_") + id.ieee;
  cJSON_AddItemToArray(identifiers, cJSON_CreateString(identifier.c_str()));
  String name = String("TH ") + id.ieee + " (" + id.model + ")";
  unsigned number = sensor_numbers.number_for(id.ieee);
  if (number) {
    char numbered_name[32];
    snprintf(numbered_name, sizeof(numbered_name), "温湿度計%02u", number);
    name = numbered_name;
  }
  cJSON_AddStringToObject(device, "name", name.c_str());
  cJSON_AddStringToObject(device, "manufacturer", id.manufacturer);
  cJSON_AddStringToObject(device, "model", id.model);
  cJSON_AddStringToObject(device, "via_device", "nanoc6_gateway");
  return device;
}
static bool gw_discovery(gateway::Node &node, unsigned k) {
  String prefix = String(ROOT_TOPIC) + "/" + node.identity.ieee + "/" + METRIC_NAMES[k];
  String unique = String("nanoc6_") + node.identity.ieee + "_" + METRIC_NAMES[k];
  String topic = String("homeassistant/sensor/nanoc6/") + unique + "/config";
  cJSON *j = cJSON_CreateObject();
  cJSON_AddStringToObject(j, "name", METRIC_NAMES[k]);
  cJSON_AddStringToObject(j, "unique_id", unique.c_str());
  cJSON_AddStringToObject(j, "state_topic", (prefix + "/state").c_str());
  cJSON_AddStringToObject(j, "value_template", "{{ value_json.value }}");
  cJSON_AddStringToObject(j, "json_attributes_topic", (prefix + "/state").c_str());
  cJSON_AddStringToObject(j, "availability_topic", GW_AVAIL);
  cJSON_AddStringToObject(j, "device_class", METRIC_CLASSES[k]);
  cJSON_AddStringToObject(j, "unit_of_measurement", METRIC_UNITS[k]);
  cJSON_AddStringToObject(j, "state_class", "measurement");
  cJSON_AddNumberToObject(j, "expire_after", k < 2 ? 10800 : 172800);
  cJSON_AddNumberToObject(j, "qos", 1);
  if (k >= 2) cJSON_AddStringToObject(j, "entity_category", "diagnostic");
  cJSON_AddItemToObject(j, "device", gw_device(node.identity));
  return gw_json(topic.c_str(), j, true) >= 0;
}
static bool gw_signal_discovery(gateway::Node &node, bool timestamp) {
  const char *kind = timestamp ? "last_seen" : "reception";
  String unique = String("nanoc6_") + node.identity.ieee + "_" + kind;
  String topic = String("homeassistant/sensor/nanoc6/") + unique + "/config";
  String state = String(ROOT_TOPIC) + "/" + node.identity.ieee + "/" + kind + "/state";
  cJSON *j = cJSON_CreateObject();
  cJSON_AddStringToObject(j, "name", timestamp ? "最終受信" : "受信状況");
  cJSON_AddStringToObject(j, "unique_id", unique.c_str());
  cJSON_AddStringToObject(j, "state_topic", state.c_str());
  cJSON_AddStringToObject(j, "availability_topic", GW_AVAIL);
  cJSON_AddStringToObject(j, "entity_category", "diagnostic");
  if (timestamp) cJSON_AddStringToObject(j, "device_class", "timestamp");
  cJSON_AddNumberToObject(j, "qos", 1);
  cJSON_AddItemToObject(j, "device", gw_device(node.identity));
  return gw_json(topic.c_str(), j, true) >= 0;
}
static bool gw_button_discovery() {
  cJSON *j = cJSON_CreateObject(), *d = cJSON_AddObjectToObject(j, "device");
  cJSON *ids = cJSON_AddArrayToObject(d, "identifiers");
  cJSON_AddItemToArray(ids, cJSON_CreateString("nanoc6_gateway"));
  cJSON_AddStringToObject(d, "name", "Nano C6 Zigbee gateway");
  cJSON_AddStringToObject(d, "manufacturer", "M5Stack");
  cJSON_AddStringToObject(d, "model", "Nano C6");
  cJSON_AddStringToObject(j, "name", "Permit Zigbee joining (180 seconds)");
  cJSON_AddStringToObject(j, "unique_id", "nanoc6_gateway_permit_join");
  cJSON_AddStringToObject(j, "command_topic", JOIN_TOPIC);
  cJSON_AddStringToObject(j, "payload_press", "180");
  cJSON_AddStringToObject(j, "entity_category", "config");
  cJSON_AddStringToObject(j, "availability_topic", GW_AVAIL);
  cJSON_AddNumberToObject(j, "qos", 1);
  return gw_json("homeassistant/button/nanoc6/permit_join/config", j, true) >= 0;
}
static void gw_mqtt_event(void *, esp_event_base_t, int32_t id, void *data) {
  auto *event = static_cast<esp_mqtt_event_handle_t>(data);
  if (id == MQTT_EVENT_CONNECTED) {
    mqtt_connected = true; discovery_reset = true;
  } else if (id == MQTT_EVENT_DISCONNECTED) {
    mqtt_connected = false; mqtt_reset = true;
  } else if (id == MQTT_EVENT_PUBLISHED) {
    int message = event->msg_id;
    if (xQueueSend(gateway_acks, &message, 0) != pdTRUE) ++gateway_drops;
  } else if (id == MQTT_EVENT_DATA && event->current_data_offset == 0 && event->data_len == event->total_data_len) {
    if (event->topic_len == strlen(JOIN_TOPIC) && !memcmp(event->topic, JOIN_TOPIC, event->topic_len)
        && !event->retain && event->data_len == 3 && !memcmp(event->data, "180", 3)) join_requested = true;
    if (!event->retain && event->topic_len == 20 && !memcmp(event->topic, "homeassistant/status", 20)
        && event->data_len == 6 && !memcmp(event->data, "online", 6)) discovery_reset = true;
  }
}
static void gw_reset_client() {
  mqtt_connected = false;
  if (mqtt) { esp_mqtt_client_stop(mqtt); esp_mqtt_client_destroy(mqtt); mqtt = nullptr; }
  for (auto &f : in_flight) { if (f.metric) ++unacked_retries; f = InFlight{}; }
  int ignored; while (xQueueReceive(gateway_acks, &ignored, 0) == pdTRUE) {}
  mqtt_reset = false;
}
static void gw_connect() {
  esp_mqtt_client_config_t cfg = {};
  cfg.broker.address.hostname = mqtt_host.c_str();
  cfg.broker.address.port = 8883;
  cfg.broker.address.transport = MQTT_TRANSPORT_OVER_SSL;
  cfg.broker.verification.certificate = mqtt_ca.c_str();
  cfg.credentials.client_id = "nanoc6_gateway";
  cfg.credentials.username = mqtt_user.c_str();
  cfg.credentials.authentication.password = mqtt_password.c_str();
  cfg.session.keepalive = 30;
  cfg.session.last_will.topic = GW_AVAIL;
  cfg.session.last_will.msg = "offline";
  cfg.session.last_will.qos = 1; cfg.session.last_will.retain = 1;
  cfg.network.disable_auto_reconnect = true;
  cfg.network.timeout_ms = 5000;
  cfg.buffer.size = 2048; cfg.outbox.limit = 32768;
  mqtt = esp_mqtt_client_init(&cfg);
  if (!mqtt) return;
  esp_mqtt_client_register_event(mqtt, MQTT_EVENT_ANY, gw_mqtt_event, nullptr);
  if (esp_mqtt_client_start(mqtt) != ESP_OK) mqtt_reset = true;
}
static void gw_load() {
  Preferences prefs; prefs.begin("gwconfig", true);
  String text = prefs.getString("json", ""); prefs.end();
  cJSON *j = cJSON_Parse(text.c_str());
  if (!j) return;
  wifi_ssid = json_string(j, "wifi_ssid"); wifi_password = json_string(j, "wifi_password");
  mqtt_host = json_string(j, "mqtt_host"); mqtt_user = json_string(j, "mqtt_user");
  mqtt_password = json_string(j, "mqtt_password"); mqtt_ca = json_string(j, "ca_pem");
  Preferences registry; registry.begin("gwfleet", true);
  gateway::Identity saved[gateway::CAPACITY] = {};
  if (registry.getBytesLength("identities") == sizeof(saved)) {
    registry.getBytes("identities", saved, sizeof(saved));
    for (auto &id : saved) {
      id.ieee[16] = id.manufacturer[32] = id.model[32] = 0;
      if (auto *node = fleet.find(id.ieee)) node->identity = id;
    }
  }
  registry.end();
  nvs_handle_t number_handle;
  esp_err_t number_open = nvs_open("gwnumbers", NVS_READONLY, &number_handle);
  if (number_open == ESP_ERR_NVS_NOT_FOUND) {
    number_storage_healthy = true;  // First use, before any assignments.
  } else if (number_open != ESP_OK) {
    number_storage_healthy = false;
    gw_log("number_registry_unavailable");
  } else {
    size_t size = 0;
    esp_err_t result = nvs_get_blob(number_handle, "map", nullptr, &size);
    if (result != ESP_ERR_NVS_NOT_FOUND &&
        (result != ESP_OK || size != sizeof(sensor_numbers) ||
         nvs_get_blob(number_handle, "map", &sensor_numbers, &size) != ESP_OK ||
         size != sizeof(sensor_numbers) || !sensor_numbers.valid())) {
      sensor_numbers = gateway::SensorNumbers{};
      number_storage_healthy = false;
      gw_log("number_registry_invalid");
    }
    nvs_close(number_handle);
  }
  cJSON *seed = nullptr;
  cJSON_ArrayForEach(seed, cJSON_GetObjectItemCaseSensitive(j, "devices")) {
    if (auto *node = fleet.find(json_string(seed, "ieee"))) {
      strlcpy(node->identity.manufacturer, json_string(seed, "manufacturer"), sizeof(node->identity.manufacturer));
      strlcpy(node->identity.model, json_string(seed, "model"), sizeof(node->identity.model));
    }
  }
  cJSON_Delete(j);
}
static void gw_store() {
  gateway::Identity saved[gateway::CAPACITY] = {};
  for (unsigned i = 0; i < gateway::CAPACITY; ++i) saved[i] = fleet.nodes[i].identity;
  Preferences prefs; prefs.begin("gwfleet", false);
  if (prefs.putBytes("identities", saved, sizeof(saved)) != sizeof(saved)) gw_log("registry_save_failed");
  prefs.end();
}
static void gw_refresh_power(uint32_t now) {
  if (!network_ready || !power_budget.ready(now)) return;
  for (unsigned offset=0; offset<gateway::CAPACITY; ++offset) {
    unsigned index = (power_cursor + offset) % gateway::CAPACITY;
    auto &node = fleet.nodes[index];
    if (!gateway::known(node.identity)) continue;
    if (node.address == 0 || node.address >= 0xfff8) {
      // Restore the live NWK mapping from the stack, never from a saved short address.
      esp_zb_ieee_addr_t ieee;
      for (unsigned i=0; i<8; ++i) {
        char byte[3] = {node.identity.ieee[i*2], node.identity.ieee[i*2+1], 0};
        ieee[7-i] = strtoul(byte, nullptr, 16);
      }
      if (esp_zb_lock_acquire(pdMS_TO_TICKS(10))) {
        node.address = esp_zb_address_short_by_ieee(ieee);
        esp_zb_lock_release();
      }
    }
    if (node.address == 0 || node.address >= 0xfff8) continue;
    bool awake = node.seen && static_cast<uint32_t>(now-node.last_seen_ms) < 10000;
    if (!node.power.due(now, node.metrics[gateway::BATTERY], node.metrics[gateway::VOLTAGE], awake)) continue;
    bool configure = node.power.needs_configuration();
    if (!schedule_power(node.address, configure)) return;
    node.power.scheduled(now, configure); power_budget.sent(now);
    ++power_reads; if (configure) ++power_config_requests;
    power_cursor = (index+1) % gateway::CAPACITY;
    return;
  }
  power_budget.sent(now); // Also rate-limit stack lookups for sleeping/unresolved devices.
}
static void gw_worker(void *) {
  gw_load();
  if (wifi_ssid.isEmpty() || mqtt_ca.isEmpty()) { gw_log("provision_required"); vTaskDelete(nullptr); return; }
  WiFi.mode(WIFI_STA); WiFi.setAutoReconnect(true);
  ESP_ERROR_CHECK(esp_coex_wifi_i154_enable());
  WiFi.begin(wifi_ssid.c_str(), wifi_password.c_str());
  configTime(0, 0, "ntp.nict.jp", "time.cloudflare.com", "pool.ntp.org");
  uint32_t last_wifi = millis(), last_connect = 0, last_telemetry = 0, dirty_at = 0;
  bool button_discovered = false;
  for (;;) {
    uint32_t now = millis();
    NumberRequest request;
    if (xQueueReceive(number_requests, &request, 0) == pdTRUE) {
      if (request.query) {
        unsigned number = sensor_numbers.number_for(request.ieee);
        if (xSemaphoreTake(usb_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
          Serial.printf("{\"v\":1,\"event\":\"number_value\",\"ieee\":\"%s\",\"number\":%u,\"healthy\":%s}\n",
                        request.ieee, number, number_storage_healthy ? "true" : "false");
          xSemaphoreGive(usb_mutex);
        }
      } else {
        gateway::Node *target = nullptr;
        for (auto &node : fleet.nodes) if (!strcmp(node.identity.ieee, request.ieee)) { target = &node; break; }
        gateway::SensorNumbers candidate = sensor_numbers;
        bool accepted = number_storage_healthy && target && gateway::known(target->identity)
                        && candidate.assign(request.number, request.ieee);
        if (accepted && memcmp(&candidate, &sensor_numbers, sizeof(candidate))) {
          Preferences store;
          accepted = store.begin("gwnumbers", false);
          if (accepted) {
            accepted = store.putBytes("map", &candidate, sizeof(candidate)) == sizeof(candidate);
            gateway::SensorNumbers readback;
            accepted = accepted && store.getBytes("map", &readback, sizeof(readback)) == sizeof(readback)
                       && readback.valid() && !memcmp(&candidate, &readback, sizeof(candidate));
            store.end();
            if (!accepted) number_storage_healthy = false;
          }
          if (accepted) { sensor_numbers = candidate; target->discovery = 0; }
        }
        if (xSemaphoreTake(usb_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
          Serial.printf("{\"v\":1,\"event\":\"number_result\",\"ieee\":\"%s\",\"number\":%u,\"accepted\":%s}\n",
                        request.ieee, request.number, accepted ? "true" : "false");
          xSemaphoreGive(usb_mutex);
        }
      }
    }
    Event event;
    for (unsigned count = 0; count < 32 && xQueueReceive(gateway_events, &event, 0) == pdTRUE; ++count) {
      if (event.endpoint != 1 && event.kind != ANNOUNCE) continue;
      char ieee[17]; for (unsigned i = 0; i < 8; ++i) snprintf(ieee + i*2, 3, "%02x", event.ieee[7-i]);
      auto *node = fleet.find(ieee); if (!node) continue;
      node->address = event.address;
      node->seen = true; node->last_seen_ms = event.uptime;
      if ((event.kind == ANNOUNCE || event.kind == ATTRIBUTE) && event.status == 0) {
        time_t clock = time(nullptr);
        uint32_t age = static_cast<uint32_t>(now-event.uptime);
        if (clock > 1735689600 && age < gateway::MAX_SEND_AGE_MS) {
          node->signal_seen = true; node->signal_pending = true;
          node->last_signal_ms = event.uptime;
          node->last_signal_epoch = static_cast<uint32_t>(clock-age/1000);
          node->status_sent = false;
        }
      }
      if (event.kind == ANNOUNCE) {
        node->refresh = true; node->power.requested = true;
        node->power.configured = node->power.unsupported = false; node->power.config_attempts = 0;
        node->power.last_config_status = 0xffff;
        continue;
      }
      if (event.kind == POWER_CONFIG_RESULT) {
        node->power.last_config_status = event.status;
        if (!event.status) { node->power.configured = true; ++power_config_successes; }
        else {
          ++power_config_failures;
          node->power.unsupported = event.status == ESP_ZB_ZCL_STATUS_UNSUP_ATTRIB
                                   || event.status == ESP_ZB_ZCL_STATUS_UNREPORTABLE_ATTRIB;
        }
        continue;
      }
      if (event.kind != ATTRIBUTE || event.status || event.truncated) continue;
      ++received_attributes;
      if (event.cluster == 0 && (event.attribute == 4 || event.attribute == 5) && event.type == 0x42
          && event.size && event.raw[0] && event.raw[0] <= 32 && event.raw[0] < event.size) {
        char value[33] = {}; memcpy(value, event.raw+1, event.raw[0]);
        char *target = event.attribute == 4 ? node->identity.manufacturer : node->identity.model;
        if (strcmp(value, target)) { strcpy(target, value); dirty_at = now ? now : 1; node->discovery = 0; }
      }
      gateway::Kind kind; int32_t encoded;
      if (gateway::decode(event.cluster, event.attribute, event.type, event.raw, event.size, kind, encoded)) {
        auto &metric = node->metrics[kind];
        metric.encoded = encoded; metric.received_ms = event.uptime; metric.valid = metric.pending = true;
      }
    }
    if (dirty_at && static_cast<uint32_t>(now - dirty_at) > 10000) { gw_store(); dirty_at = 0; }
    int ack;
    while (xQueueReceive(gateway_acks, &ack, 0) == pdTRUE) {
      for (auto &f : in_flight) if (f.id == ack && f.metric) {
        if (f.metric->received_ms == f.received) f.metric->pending = false;
        f = InFlight{}; break;
      }
    }
    for (auto &node : fleet.nodes) for (auto &metric : node.metrics) {
      if (metric.pending && !gateway::fresh(now, metric)) {
        metric.pending = false; ++stale_drops;
        // Also clear an unacknowledged SDK outbox item rather than replaying it late.
        for (auto &f : in_flight) if (f.metric == &metric) mqtt_reset = true;
      }
    }
    if (mqtt_reset || (WiFi.status() != WL_CONNECTED && mqtt)) { gw_reset_client(); last_connect = now; }
    if (WiFi.status() != WL_CONNECTED && static_cast<uint32_t>(now-last_wifi) > 30000) {
      WiFi.reconnect(); last_wifi = now;
    }
    // Certificate and hostname verification stay enabled. A valid clock is mandatory.
    if (WiFi.status() == WL_CONNECTED && time(nullptr) > 1735689600 && !mqtt
        && static_cast<uint32_t>(now-last_connect) > 5000) { gw_connect(); last_connect = now; }
    if (mqtt_connected && discovery_reset.exchange(false)) {
      for (auto &node : fleet.nodes) { node.discovery = 0; node.refresh = true; node.power.requested = true; node.status_sent = false; }
      button_discovered = false;
      esp_mqtt_client_subscribe(mqtt, JOIN_TOPIC, 1);
      esp_mqtt_client_subscribe(mqtt, "homeassistant/status", 1);
      gw_publish(GW_AVAIL, "online", true);
      gw_log("mqtt_connected");
    }
    if (join_requested.exchange(false) && network_ready) {
      esp_zb_lock_acquire(portMAX_DELAY); esp_zb_bdb_open_network(180); esp_zb_lock_release();
      gw_log("joining_open_180_seconds");
    }
    if (mqtt_connected) {
      if (power_refresh_requested.exchange(false)) for (auto &node : fleet.nodes) node.power.requested = true;
      gw_refresh_power(now);
      if (!button_discovered) button_discovered = gw_button_discovery();
      for (auto &node : fleet.nodes) {
        if (!gateway::known(node.identity)) continue;
        if (!(node.discovery & (1U << gateway::METRICS)) && gw_signal_discovery(node, true))
          node.discovery |= (1U << gateway::METRICS);
        if (!(node.discovery & (1U << (gateway::METRICS+1))) && gw_signal_discovery(node, false))
          node.discovery |= (1U << (gateway::METRICS+1));
        bool status_due = !node.status_sent || static_cast<uint32_t>(now-node.last_status_ms) >= 60000;
        if (node.signal_pending || (node.signal_seen && status_due)) {
          time_t epoch = node.last_signal_epoch;
          struct tm utc = {};
          char timestamp[24];
          if (gmtime_r(&epoch, &utc) && strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%SZ", &utc)) {
            String topic = String(ROOT_TOPIC) + "/" + node.identity.ieee + "/last_seen/state";
            if (gw_publish(topic.c_str(), timestamp, true) >= 0) node.signal_pending = false;
          }
        }
        if (status_due) {
          time_t clock = time(nullptr);
          const uint32_t safe_clock = clock > 1735689600 ? static_cast<uint32_t>(clock) : 0;
          const char *status = gateway::reception_status(node.signal_seen, safe_clock, node.last_signal_epoch);
          String topic = String(ROOT_TOPIC) + "/" + node.identity.ieee + "/reception/state";
          if (gw_publish(topic.c_str(), status, true) >= 0) { node.status_sent = true; node.last_status_ms = now; }
        }
        if (node.refresh && node.address < 0xfff8 && uxQueueSpacesAvailable(jobs) >= 4) {
          // A newly started HA must receive NEW reads, rather than an old cached state.
          schedule(READ_ATTRIBUTES, node.address, 1, 0x0402);
          schedule(READ_ATTRIBUTES, node.address, 1, 0x0405);
          node.refresh = false;
        }
        for (unsigned k = 0; k < gateway::METRICS; ++k) {
          if (!(node.discovery & (1U << k)) && gw_discovery(node, k)) node.discovery |= 1U << k;
          auto &metric = node.metrics[k];
          if (!metric.pending) continue;
          if (!gateway::fresh(now, metric)) { metric.pending = false; ++stale_drops; continue; }
          bool busy = false; InFlight *slot = nullptr;
          for (auto &f : in_flight) { if (f.metric == &metric) busy = true; if (!f.metric && !slot) slot = &f; }
          if (busy || !slot) continue;
          double value = static_cast<double>(metric.encoded) / gateway::divisor(node.identity, static_cast<gateway::Kind>(k));
          if (k == gateway::HUMIDITY && (value < 0 || value > 100)) { metric.pending = false; continue; }
          String topic = String(ROOT_TOPIC) + "/" + node.identity.ieee + "/" + METRIC_NAMES[k] + "/state";
          cJSON *j = cJSON_CreateObject();
          cJSON_AddNumberToObject(j, "value", value);
          cJSON_AddNumberToObject(j, "received_at", time(nullptr) - static_cast<uint32_t>(now-metric.received_ms)/1000);
          cJSON_AddNumberToObject(j, "received_uptime_ms", metric.received_ms);
          int id = gw_json(topic.c_str(), j); // Measurement messages are NEVER retained.
          if (id >= 0) { slot->id = id; slot->metric = &metric; slot->received = metric.received_ms; }
        }
      }
      if (static_cast<uint32_t>(now-last_telemetry) > 60000) {
        cJSON *j = cJSON_CreateObject();
        cJSON_AddNumberToObject(j, "event_drops", event_drops);
        cJSON_AddNumberToObject(j, "job_drops", job_drops);
        cJSON_AddNumberToObject(j, "gateway_drops", gateway_drops.load());
        cJSON_AddNumberToObject(j, "stale_drops", stale_drops);
        cJSON_AddNumberToObject(j, "unacked_retries", unacked_retries);
        cJSON_AddNumberToObject(j, "device_overflow", fleet.overflow);
        cJSON_AddNumberToObject(j, "received_attributes", received_attributes);
        cJSON_AddNumberToObject(j, "free_heap", ESP.getFreeHeap());
        cJSON_AddNumberToObject(j, "uptime_ms", now);
        cJSON_AddStringToObject(j, "firmware", FIRMWARE_VERSION);
        cJSON_AddNumberToObject(j, "power_read_requests", power_reads);
        cJSON_AddNumberToObject(j, "power_config_requests", power_config_requests);
        cJSON_AddNumberToObject(j, "power_config_successes", power_config_successes);
        cJSON_AddNumberToObject(j, "power_config_failures", power_config_failures);
        cJSON *configuration = cJSON_AddObjectToObject(j, "power_configuration");
        for (const auto &node : fleet.nodes) if (gateway::known(node.identity)) {
          cJSON *item = cJSON_AddObjectToObject(configuration, node.identity.ieee);
          cJSON_AddBoolToObject(item, "configured", node.power.configured);
          cJSON_AddBoolToObject(item, "unsupported", node.power.unsupported);
          cJSON_AddNumberToObject(item, "attempts", node.power.config_attempts);
          cJSON_AddNumberToObject(item, "status", node.power.last_config_status);
        }
        gw_json("smarthome/nanoc6/gateway/telemetry", j, false, 0); last_telemetry = now;
      }
    }
    vTaskDelay(pdMS_TO_TICKS(20));
  }
}
static void gateway_start() {
  gateway_events = xQueueCreate(128, sizeof(Event)); gateway_acks = xQueueCreate(256, sizeof(int));
  number_requests = xQueueCreate(4, sizeof(NumberRequest));
  if (!gateway_events || !gateway_acks || !number_requests) abort();
  if (xTaskCreate(gw_worker, "gateway", 12288, nullptr, 2, nullptr) != pdPASS) abort();
}
static void gateway_accept(const Event &event) {
  if ((event.kind == ATTRIBUTE || event.kind == POWER_CONFIG_RESULT || event.kind == ANNOUNCE)
      && xQueueSend(gateway_events, &event, 0) != pdTRUE) ++gateway_drops;
}
static bool gateway_command(const char *command) {
  if (!strcmp(command, "refresh-battery")) {
    power_refresh_requested = true; gw_log("battery_refresh_requested"); return true;
  }
  if (!strcmp(command, "gateway-status")) {
    xSemaphoreTake(usb_mutex, portMAX_DELAY);
    Serial.printf("{\"v\":1,\"event\":\"gateway_status\",\"wifi\":%s,\"mqtt\":%s,\"clock\":%s,\"gateway_drops\":%lu,\"firmware\":\"%s\"}\n",
                  WiFi.status() == WL_CONNECTED ? "true" : "false", mqtt_connected ? "true" : "false",
                  time(nullptr) > 1735689600 ? "true" : "false", static_cast<unsigned long>(gateway_drops.load()), FIRMWARE_VERSION);
    xSemaphoreGive(usb_mutex);
    return true;
  }
  if (command[0] != '{') return false;
  cJSON *j = cJSON_Parse(command);
  if (!j) { gw_log("invalid_config"); return true; }
  if (!strcmp(json_string(j, "command"), "assign-number") || !strcmp(json_string(j, "command"), "get-number")) {
    const char *ieee = json_string(j, "ieee");
    cJSON *number = cJSON_GetObjectItemCaseSensitive(j, "number");
    bool query = !strcmp(json_string(j, "command"), "get-number");
    if (gateway::SensorNumbers::valid_ieee(ieee) && (query || (cJSON_IsNumber(number)
        && number->valuedouble == number->valueint && number->valueint >= 1 && number->valueint <= 10))) {
      NumberRequest request = {};
      memcpy(request.ieee, ieee, 17); request.query = query; request.number = query ? 0 : number->valueint;
      if (xQueueSend(number_requests, &request, 0) != pdTRUE) gw_log("number_queue_full");
    } else gw_log("invalid_number_request");
    cJSON_Delete(j);
    return true;
  }
  bool valid = !strcmp(json_string(j, "command"), "configure")
      && strlen(json_string(j, "wifi_ssid")) > 0 && strlen(json_string(j, "wifi_ssid")) <= 32
      && strlen(json_string(j, "wifi_password")) <= 63
      && strlen(json_string(j, "mqtt_host")) > 0 && strlen(json_string(j, "mqtt_host")) < 128
      && strlen(json_string(j, "mqtt_user")) > 0 && strlen(json_string(j, "mqtt_password")) >= 16
      && strstr(json_string(j, "ca_pem"), "-----BEGIN CERTIFICATE-----") && strlen(command) <= 5500;
  if (valid) {
    Preferences prefs; valid = prefs.begin("gwconfig", false);
    if (valid) valid = prefs.putString("json", command) == strlen(command);
    prefs.end();
  }
  cJSON_Delete(j);
  if (valid) { gw_log("configured"); delay(300); ESP.restart(); }
  else gw_log("invalid_config");
  return true;
}
