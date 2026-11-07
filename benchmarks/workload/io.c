/* Development benchmark I/O only. The MoonFST library has no C dependency. */
#include <moonbit.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *operation) {
  fprintf(stderr, "MoonFST workload: %s: %s\n", operation, strerror(errno));
  abort();
}

static const char *required_env(const char *name) {
  const char *value = getenv(name);
  if (value == NULL || value[0] == '\0') {
    fprintf(stderr, "MoonFST workload: missing environment variable %s\n", name);
    abort();
  }
  return value;
}

static moonbit_bytes_t read_file(const char *name) {
  FILE *file = fopen(required_env(name), "rb");
  if (file == NULL) fail("fopen input");
  if (fseek(file, 0, SEEK_END) != 0) fail("fseek input end");
  long length = ftell(file);
  if (length < 0) fail("ftell input");
  if (length > INT32_MAX) {
    fprintf(stderr, "MoonFST workload: file exceeds MoonBit Bytes length limit\n");
    abort();
  }
  if (fseek(file, 0, SEEK_SET) != 0) fail("fseek input start");
  moonbit_bytes_t bytes = moonbit_make_bytes_raw((int32_t)length);
  if (fread(bytes, 1, (size_t)length, file) != (size_t)length) {
    if (ferror(file)) fail("fread input");
    fprintf(stderr, "MoonFST workload: input changed or ended during read\n");
    abort();
  }
  if (fgetc(file) != EOF || ferror(file)) {
    fprintf(stderr, "MoonFST workload: input changed during read\n");
    abort();
  }
  if (fclose(file) != 0) fail("fclose input");
  return bytes;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonfst_workload_read_input(void) {
  return read_file("MOONFST_WORKLOAD_INPUT");
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonfst_workload_read_fst(void) {
  return read_file("MOONFST_WORKLOAD_FST_PATH");
}

/* The MoonBit declaration explicitly borrows bytes. */
MOONBIT_FFI_EXPORT void moonfst_workload_write_fst(moonbit_bytes_t bytes,
                                                 int32_t length) {
  const char *path = getenv("MOONFST_WORKLOAD_WRITE_FST");
  if (path == NULL || path[0] == '\0') return;
  FILE *file = fopen(path, "wb");
  if (file == NULL) fail("fopen output");
  if (fwrite(bytes, 1, (size_t)length, file) != (size_t)length) fail("fwrite output");
  if (fclose(file) != 0) fail("fclose output");
}

/* Both runners use the same Linux process counters. VmHWM is a process high
 * water mark, not the memory uniquely attributable to an individual operation. */
static int64_t status_kib(const char *field) {
  FILE *file = fopen("/proc/self/status", "r");
  if (file == NULL) fail("fopen /proc/self/status");
  char line[512];
  const size_t length = strlen(field);
  while (fgets(line, sizeof line, file) != NULL) {
    if (strncmp(line, field, length) == 0 && line[length] == ':') {
      long long kib = -1;
      char unit[8];
      if (sscanf(line + length + 1, "%lld %7s", &kib, unit) != 2 ||
          kib < 0 || strcmp(unit, "kB") != 0) {
        fprintf(stderr, "MoonFST workload: malformed Linux %s counter\n", field);
        abort();
      }
      if (fclose(file) != 0) fail("fclose /proc/self/status");
      return (int64_t)kib;
    }
  }
  fprintf(stderr, "MoonFST workload: unavailable Linux %s counter\n", field);
  abort();
}

MOONBIT_FFI_EXPORT int64_t moonfst_workload_rss_kib(void) {
  return status_kib("VmRSS");
}

MOONBIT_FFI_EXPORT int64_t moonfst_workload_peak_rss_kib(void) {
  return status_kib("VmHWM");
}
