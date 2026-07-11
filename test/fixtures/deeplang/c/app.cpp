#include "util.h"

int compute() {
  try {
    return add(1, 2);
  } catch (...) {}
  return 0;
}
