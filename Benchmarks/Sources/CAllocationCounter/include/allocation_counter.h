#ifndef TELEMETRY_ALLOCATION_COUNTER_H
#define TELEMETRY_ALLOCATION_COUNTER_H

#include <stdint.h>

/// Whether allocations can be counted on this platform.
int telemetry_allocations_supported(void);

/// Starts counting allocations made by the calling thread.
void telemetry_allocations_begin(void);

/// Stops counting and returns how many were made since `begin`.
uint64_t telemetry_allocations_end(void);

#endif
