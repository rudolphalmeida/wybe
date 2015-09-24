/* cbits
$ gcc -fPIC -shared cbits.c -o cbits.so
$ clang -fPIC -shared cbits.c -o cbits.so
*/

#include <stdio.h>
#include <stdlib.h>

// putchard - putchar that takes a double and returns 0.
void print_int(int X) {
  printf("%d\n", X);
  fflush(stdout);
}

void print_float(double X) {
  printf("%f\n", X);
  fflush(stdout);
}

void print_string(char *str) {
  int i;
  for (i = 0; i < 10; i++) {
    printf("%c\n", str[0]);
  }
  printf("Test\n");
  // printf("%s\n", str);
  fflush(stdout);
}
