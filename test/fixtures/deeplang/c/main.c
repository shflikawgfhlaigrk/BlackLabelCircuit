#include <stdio.h>
#include <string.h>
#include "util.h"

int main(int argc, char **argv) {
  char buf[8];
  strcpy(buf, argv[1]);
  printf("%d\n", add(2, 3));
  return 0;
}
