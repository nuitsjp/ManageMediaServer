#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace gateway {
// Separate from the existing Identity NVS blob so a firmware update can keep
// reading existing manufacturer/model identities without migration.
struct SensorNumbers {
  static constexpr unsigned COUNT = 10;
  char ieee[COUNT][17] = {};

  static bool valid_ieee(const char *value) {
    if (!value || strlen(value) != 16 || !strcmp(value, "0000000000000000")) return false;
    for (const char *p = value; *p; ++p)
      if (!(*p >= '0' && *p <= '9') && !(*p >= 'a' && *p <= 'f')) return false;
    return true;
  }

  // Reassignment requires explicit removal; never silently swap two sensors.
  bool assign(unsigned number, const char *value) {
    if (number < 1 || number > COUNT || !valid_ieee(value)) return false;
    for (unsigned i = 0; i < COUNT; ++i) {
      if (!strcmp(ieee[i], value)) return i == number-1;
    }
    if (ieee[number-1][0]) return false;
    memcpy(ieee[number-1], value, 17);
    return true;
  }

  unsigned number_for(const char *value) const {
    if (!valid_ieee(value)) return 0;
    for (unsigned i = 0; i < COUNT; ++i) if (!strcmp(ieee[i], value)) return i+1;
    return 0;
  }

  bool valid() const {
    SensorNumbers checked;
    for (unsigned i = 0; i < COUNT; ++i) {
      if (!memchr(ieee[i], 0, sizeof(ieee[i]))) return false;
      if (!ieee[i][0]) {
        for (char byte : ieee[i]) if (byte) return false;
      } else if (!checked.assign(i+1, ieee[i])) return false;
    }
    return true;
  }
};
}
