#include "sensor_numbers.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
using gateway::SensorNumbers;

int main() {
  SensorNumbers numbers;
  assert(numbers.valid());
  for (unsigned n = 1; n <= 10; ++n) {
    char id[17]; snprintf(id, sizeof(id), "a4c138%010x", n);
    assert(numbers.assign(n, id));
    assert(numbers.number_for(id) == n);
    assert(numbers.assign(n, id));
    assert(!numbers.assign(n % 10 + 1, id));
  }
  assert(numbers.valid());
  assert(!numbers.assign(1, "a4c1380000000063"));
  assert(!numbers.assign(0, "a4c1380000000063"));
  assert(!numbers.assign(11, "a4c1380000000063"));
  assert(!numbers.assign(1, "0000000000000000"));
  SensorNumbers restored;
  memcpy(&restored, &numbers, sizeof(numbers));
  assert(restored.valid() && restored.number_for("a4c138000000000a") == 10);
  memcpy(restored.ieee[1], restored.ieee[0], 17);
  assert(!restored.valid());
  memset(restored.ieee[1], 'x', 17);
  assert(!restored.valid());
}
