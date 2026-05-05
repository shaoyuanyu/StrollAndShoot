#ifndef PTP_CLIENT_H
#define PTP_CLIENT_H

#include <cstdint>
#include <string>
#include <vector>

// PTP operation codes
constexpr uint16_t PTP_OC_OpenSession       = 0x1002;
constexpr uint16_t PTP_OC_CloseSession      = 0x1003;
constexpr uint16_t PTP_OC_GetDeviceInfo     = 0x1001;
constexpr uint16_t PTP_OC_GetStorageIDs     = 0x1004;
constexpr uint16_t PTP_OC_GetStorageInfo    = 0x1005;
constexpr uint16_t PTP_OC_GetNumObjects     = 0x1006;
constexpr uint16_t PTP_OC_GetObjectHandles  = 0x1007;
constexpr uint16_t PTP_OC_GetObjectInfo     = 0x1008;

// Container types
constexpr uint16_t PTP_TYPE_COMMAND   = 1;
constexpr uint16_t PTP_TYPE_DATA      = 2;
constexpr uint16_t PTP_TYPE_RESPONSE  = 3;

// Response codes
constexpr uint16_t PTP_RC_OK                  = 0x2001;
constexpr uint16_t PTP_RC_SessionNotOpen      = 0x2003;
constexpr uint16_t PTP_RC_InvalidStorageID    = 0x200B;
constexpr uint16_t PTP_RC_DeviceBusy          = 0x201F;

// Packed container header (12 bytes)
#pragma pack(push, 1)
struct PtpContainer {
    uint32_t length;
    uint16_t type;
    uint16_t code;
    uint32_t transactionId;
    // params follow after header in command/response containers
};
#pragma pack(pop)

static constexpr size_t PTP_CONTAINER_HEADER_SIZE = 12;
static constexpr size_t PTP_MAX_PARAMS = 5;

// Parsed response
struct PtpResponse {
    uint16_t code;
    uint32_t transactionId;
    uint32_t params[PTP_MAX_PARAMS];
    uint8_t  paramCount;
};

// Device info (subset of what we care about)
struct PtpDeviceInfo {
    std::string manufacturer;
    std::string model;
    std::string deviceVersion;
    std::string serialNumber;
};

// Object info (file metadata)
struct PtpObjectInfo {
    uint32_t handle;
    uint16_t format;
    uint32_t size;
    std::string filename;
};

// ---- Builder functions: return raw command bytes ----

// Build a PTP command container as Uint8Array bytes
std::vector<uint8_t> ptpBuildCommand(uint16_t opCode, uint32_t transactionId,
                                     const std::vector<uint32_t>& params = {});

// Convenience builders (all accept transactionId)
std::vector<uint8_t> ptpBuildOpenSession(uint32_t sessionId, uint32_t transactionId = 1);
std::vector<uint8_t> ptpBuildCloseSession(uint32_t transactionId = 0);
std::vector<uint8_t> ptpBuildGetDeviceInfo(uint32_t transactionId = 1);
std::vector<uint8_t> ptpBuildGetStorageIDs(uint32_t transactionId = 1);
std::vector<uint8_t> ptpBuildGetObjectHandles(uint32_t storageId, uint32_t transactionId = 1,
                                              uint32_t formatCode = 0,
                                              uint32_t associationHandle = 0xFFFFFFFF);
std::vector<uint8_t> ptpBuildGetObjectInfo(uint32_t objectHandle, uint32_t transactionId = 1);

// ---- Parser functions: interpret response/data payloads ----

// Parse a response container (12 bytes)
PtpResponse ptpParseResponse(const uint8_t* data, size_t len);

// Parse a GetDeviceInfo data payload
PtpDeviceInfo ptpParseDeviceInfo(const uint8_t* data, size_t len);

// Parse a GetStorageIDs data payload
std::vector<uint32_t> ptpParseStorageIDs(const uint8_t* data, size_t len);

// Parse a GetObjectHandles data payload
std::vector<uint32_t> ptpParseObjectHandles(const uint8_t* data, size_t len);

// Parse a GetObjectInfo data payload
PtpObjectInfo ptpParseObjectInfo(const uint8_t* data, size_t len);

// Helper: read UCS-2 (UTF-16LE) string at offset, returns UTF-8
std::string readUcs2String(const uint8_t* data, size_t maxLen);

#endif // PTP_CLIENT_H
