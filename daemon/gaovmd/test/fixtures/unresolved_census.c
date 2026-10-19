#include <stdio.h>
#include <unistd.h>

int main(void) {
  if (puts("native-fixture-ready") == EOF || fflush(stdout) == EOF) return 1;
  for (;;) pause();
}
