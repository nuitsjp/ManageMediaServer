#pragma once
#include <stdint.h>
#include <string.h>

namespace gateway {
constexpr unsigned CAPACITY = 32;
constexpr uint32_t MAX_SEND_AGE_MS = 120000;
enum Kind { TEMPERATURE, HUMIDITY, BATTERY, VOLTAGE, METRICS };
struct Metric {
  int32_t encoded = 0;
  uint32_t received_ms = 0;
  bool valid = false, pending = false;
};
struct Identity {
  char ieee[17] = {}, manufacturer[33] = {}, model[33] = {};
};
struct Node {
  Identity identity;
  Metric metrics[METRICS];
  unsigned discovery = 0;
  uint16_t address = 0xffff;
  bool refresh = false;
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
