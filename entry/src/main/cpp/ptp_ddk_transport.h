#ifndef PTP_DDK_TRANSPORT_H
#define PTP_DDK_TRANSPORT_H

#include <cstdint>
#include <vector>

// Initialize USB DDK
int ptp_ddk_init();

// Initialize device: get descriptors, claim interface, find endpoints
bool ptp_ddk_init_device(uint64_t deviceId);

// Release device and DDK resources
void ptp_ddk_release_device();

// Send raw command bytes on bulk OUT endpoint, return success
bool ptp_ddk_send_command(const std::vector<uint8_t>& cmd);

// Read data from bulk IN endpoint using DMA buffer
// Returns the raw response/data bytes
std::vector<uint8_t> ptp_ddk_read_data(int timeoutMs, bool expectData);

#endif // PTP_DDK_TRANSPORT_H
