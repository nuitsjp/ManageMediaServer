#pragma once
#include <stdint.h>
#include <string.h>

namespace gateway {
constexpr unsigned CAPACITY = 32;
constexpr uint32_t MAX_SEND_AGE_MS = 120000;
constexpr uint32_t POWER_REFRESH_MS = 6U * 60 * 60 * 1000;
constexpr uint32_t POWER_RETRY_MS = 5U * 60 * 1000;
constexpr uint32_t POWER_BATCH_GAP_MS = 2000;
constexpr uint16_t POWER_REPORT_MIN_S = 3600, POWER_REPORT_MAX_S = 21600;
inline const char *reception_status(bool seen, uint32_t now_epoch, uint32_t seen_epoch) {
  if (!seen || now_epoch < seen_epoch) return "未確認";
  return now_epoch-seen_epoch < 10800U ? "3時間以内に受信" : "3時間以上受信なし";
}
enum Kind { TEMPERATURE, HUMIDITY, BATTERY, VOLTAGE, METRICS };
struct Metric {
  int32_t encoded = 0;
  uint32_t received_ms = 0;
  bool valid = false, pending = false;
};
struct Identity {
  char ieee[17] = {}, manufacturer[33] = {}, model[33] = {};
};
struct PowerRefresh {
  bool requested = true, attempted = false, configured = false, unsupported = false;
  uint8_t config_attempts = 0;
  uint16_t last_config_status = 0xffff;
  uint32_t last_attempt_ms = 0;
  bool needs_configuration() const { return !configured && !unsupported && config_attempts < 3; }
  bool due(uint32_t now, const Metric &battery, const Metric &voltage, bool recently_awake) const {
    bool missing = !battery.valid || !voltage.valid;
    bool old = (battery.valid && static_cast<uint32_t>(now-battery.received_ms) >= POWER_REFRESH_MS)
            || (voltage.valid && static_cast<uint32_t>(now-voltage.received_ms) >= POWER_REFRESH_MS);
    if (!requested && !missing && !old && !needs_configuration()) return false;
    if (attempted && static_cast<uint32_t>(now-last_attempt_ms) < POWER_RETRY_MS) return false;
    // Retry soon after the sensor talks to us; an idle/sleeping sensor is probed at most every six hours.
    return requested || !attempted || recently_awake || static_cast<uint32_t>(now-last_attempt_ms) >= POWER_REFRESH_MS;
  }
  void scheduled(uint32_t now, bool configure) {
    attempted = true; requested = false; last_attempt_ms = now;
    if (configure) ++config_attempts;
  }
};
struct PowerBudget {
  bool used = false;
  uint32_t last_batch_ms = 0;
  bool ready(uint32_t now) const { return !used || static_cast<uint32_t>(now-last_batch_ms) >= POWER_BATCH_GAP_MS; }
  void sent(uint32_t now) { used = true; last_batch_ms = now; }
};
struct Node {
  Identity identity;
  Metric metrics[METRICS];
  unsigned discovery = 0;
  uint16_t address = 0xffff;
  bool refresh = false;
  bool seen = false;
  uint32_t last_seen_ms = 0;
  // Only a successful device event is evidence of reception. NVS and MQTT
  // reconnects must never make an old reading appear new.
  bool signal_seen = false, signal_pending = false, status_sent = false;
  uint32_t last_signal_ms = 0, last_signal_epoch = 0, last_status_ms = 0;
  PowerRefresh power;
};
inline bool known(const Identity &id) {
  return (!strcmp(id.model, "TH01") && !strcmp(id.manufacturer, "Zbeacon")) ||
         (!strcmp(id.model, "TS0201") &&
          (!strcmp(id.manufacturer, "_TZ3000_itnrsufe") || !strcmp(id.manufacturer, "_TZ3000_bguser20") ||
           !strcmp(id.manufacturer, "_TZ3000_xr3htd96")));
}
inline int divisor(const Identity &id, Kind kind) {
  if (kind == BATTERY) return 2;
  if (kind == VOLTAGE) return 10;
  if (kind == HUMIDITY && !strcmp(id.manufacturer, "_TZ3000_itnrsufe")) return 10;
  return 100;
}
inline bool decode(uint16_t cluster, uint16_t attr, uint8_t type, const uint8_t *raw,
                   unsigned size, Kind &kind, int32_t &encoded) {
  if ((cluster == 0x0402 || cluster == 0x0405) && attr == 0 && size == 2) {
    uint16_t word = raw[0] | (static_cast<uint16_t>(raw[1]) << 8);
    if (cluster == 0x0402 && type == 0x29) {
      if (word == 0x8000) return false;
      encoded = static_cast<int16_t>(word); kind = TEMPERATURE; return true;
    }
    if (cluster == 0x0405 && type == 0x21 && word != 0xffff) {
      encoded = word; kind = HUMIDITY; return true;
    }
  }
  if (cluster == 1 && size == 1 && type == 0x20) {
    if (attr == 0x20 && raw[0] != 0xff) { encoded = raw[0]; kind = VOLTAGE; return true; }
    if (attr == 0x21 && raw[0] <= 200) { encoded = raw[0]; kind = BATTERY; return true; }
  }
  return false;
}
inline bool fresh(uint32_t now, const Metric &metric) {
  return metric.valid && static_cast<uint32_t>(now - metric.received_ms) <= MAX_SEND_AGE_MS;
}
class Fleet {
 public:
  Node nodes[CAPACITY];
  unsigned overflow = 0;
  Node *find(const char *ieee) {
    if (strlen(ieee) != 16 || !strcmp(ieee, "0000000000000000")) return nullptr;
    for (const char *p = ieee; *p; ++p) if (!(*p >= '0' && *p <= '9') && !(*p >= 'a' && *p <= 'f')) return nullptr;
    for (auto &n : nodes) if (!strcmp(n.identity.ieee, ieee)) return &n;
    for (auto &n : nodes) if (!n.identity.ieee[0]) { strcpy(n.identity.ieee, ieee); return &n; }
    ++overflow; return nullptr;
  }
};
}
