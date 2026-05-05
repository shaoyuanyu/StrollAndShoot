#ifndef PTP_ENGINE_H
#define PTP_ENGINE_H

#include <cstdint>
#include <string>
#include <vector>
#include <functional>

// ============================================================
// PTP Engine — ported from libgphoto2 camlibs/ptp2/
// ============================================================

// ---- USB Container (ptp.h:126) ----
static constexpr uint32_t PTP_USB_BULK_HDR_LEN  = 12;
static constexpr uint32_t PTP_USB_BULK_REQ_LEN  = PTP_USB_BULK_HDR_LEN + 5*sizeof(uint32_t); // 32
static constexpr uint32_t PTP_USB_BULK_PAYLOAD_LEN_READ  = 1024 - PTP_USB_BULK_HDR_LEN; // 1012
static constexpr uint32_t PTP_USB_BULK_PAYLOAD_LEN_WRITE = 1024 - PTP_USB_BULK_HDR_LEN;

// Container types (ptp.h:160)
static constexpr uint16_t PTP_USB_CONTAINER_UNDEFINED = 0x0000;
static constexpr uint16_t PTP_USB_CONTAINER_COMMAND   = 0x0001;
static constexpr uint16_t PTP_USB_CONTAINER_DATA      = 0x0002;
static constexpr uint16_t PTP_USB_CONTAINER_RESPONSE  = 0x0003;
static constexpr uint16_t PTP_USB_CONTAINER_EVENT     = 0x0004;

// PTP Operation Codes (ptp.h)
static constexpr uint16_t PTP_OC_GetDeviceInfo       = 0x1001;
static constexpr uint16_t PTP_OC_OpenSession         = 0x1002;
static constexpr uint16_t PTP_OC_CloseSession        = 0x1003;
static constexpr uint16_t PTP_OC_GetStorageIDs       = 0x1004;
static constexpr uint16_t PTP_OC_GetStorageInfo      = 0x1005;
static constexpr uint16_t PTP_OC_GetNumObjects       = 0x1006;
static constexpr uint16_t PTP_OC_GetObjectHandles    = 0x1007;
static constexpr uint16_t PTP_OC_GetObjectInfo       = 0x1008;
static constexpr uint16_t PTP_OC_GetObject           = 0x1009;
static constexpr uint16_t PTP_OC_GetThumb            = 0x100A;

// PTP Response Codes (ptp.h)
static constexpr uint16_t PTP_RC_OK                  = 0x2001;
static constexpr uint16_t PTP_RC_SessionNotOpen      = 0x2003;
static constexpr uint16_t PTP_RC_InvalidStorageID    = 0x200B;
static constexpr uint16_t PTP_RC_InvalidObjectHandle = 0x2009;
static constexpr uint16_t PTP_RC_DeviceBusy          = 0x201F;
static constexpr uint16_t PTP_RC_InvalidParameter    = 0x201D;
static constexpr uint16_t PTP_RC_AccessDenied        = 0x200F;
static constexpr uint16_t PTP_RC_StoreFull           = 0x200C;

// Data phase flags (ptp.h)
static constexpr uint16_t PTP_DP_NODATA   = 0x0000;
static constexpr uint16_t PTP_DP_SENDDATA = 0x0001;
static constexpr uint16_t PTP_DP_GETDATA  = 0x0002;
static constexpr uint16_t PTP_DP_DATA_MASK = 0x0003;

// Vendor IDs (ptp.h:190)
static constexpr uint32_t PTP_VENDOR_NIKON     = 0x0000000A;
static constexpr uint32_t PTP_VENDOR_CANON     = 0x0000000B;
static constexpr uint32_t PTP_VENDOR_SONY      = 0x00000011;
static constexpr uint32_t PTP_VENDOR_MICROSOFT = 0x00000006;
static constexpr uint32_t PTP_VENDOR_MTP       = 0xFFFFFFFF;

// USB VID/PID
static constexpr uint16_t USB_VID_NIKON = 0x04B0;

// ---- Packed container structures ----

#pragma pack(push, 1)
struct PTPUSBBulkContainer {
    uint32_t length;
    uint16_t type;
    uint16_t code;
    uint32_t trans_id;
    union {
        struct { uint32_t param1, param2, param3, param4, param5; } params;
        unsigned char data[PTP_USB_BULK_PAYLOAD_LEN_READ];
    } payload;
};

struct PTPUSBEventContainer {
    uint32_t length;
    uint16_t type;
    uint16_t code;
    uint32_t trans_id;
    uint32_t param1;
    uint32_t param2;
    uint32_t param3;
};
#pragma pack(pop)

// ---- PTP Container (ptp.h: PTPContainer) ----
struct PTPContainer {
    uint16_t Code;
    uint32_t SessionID;
    uint32_t Transaction_ID;
    uint32_t Param1, Param2, Param3, Param4, Param5;
    uint8_t  Nparam;
};

// ---- PTP Device Info ----
struct PTPDeviceInfo {
    uint16_t StandardVersion;
    uint32_t VendorExtensionID;
    uint16_t VendorExtensionVersion;
    std::string VendorExtensionDesc;
    uint16_t FunctionalMode;
    std::vector<uint32_t> OperationsSupported;
    std::vector<uint32_t> EventsSupported;
    std::vector<uint32_t> DevicePropertiesSupported;
    std::vector<uint32_t> CaptureFormats;
    std::vector<uint32_t> ImageFormats;
    std::string Manufacturer;
    std::string Model;
    std::string DeviceVersion;
    std::string SerialNumber;
};

// ---- PTP Object Info ----
struct PTPObjectInfo {
    uint32_t StorageID;
    uint16_t ObjectFormat;
    uint16_t ProtectionStatus;
    uint32_t ObjectCompressedSize;
    uint16_t ThumbFormat;
    uint32_t ThumbCompressedSize;
    uint32_t ThumbPixWidth;
    uint32_t ThumbPixHeight;
    uint32_t ImagePixWidth;
    uint32_t ImagePixHeight;
    uint32_t ImageBitDepth;
    uint32_t ParentObject;
    uint16_t AssociationType;
    uint32_t AssociationDesc;
    uint32_t SequenceNumber;
    std::string Filename;
    std::string CaptureDate;
    std::string ModificationDate;
    std::string Keywords;
};

// ---- PTP Storage Info ----
struct PTPStorageInfo {
    uint16_t StorageType;
    uint16_t FilesystemType;
    uint16_t AccessCapability;
    uint64_t MaxCapacity;
    uint64_t FreeSpaceInBytes;
    uint32_t FreeSpaceInImages;
    std::string StorageDescription;
    std::string VolumeLabel;
};

// ============================================================
// PTP Engine state (from PTPParams in ptp.h)
// ============================================================

struct PTPParams {
    // Session state
    uint32_t session_id = 0;
    uint32_t transaction_id = 0;

    // Device info cache
    PTPDeviceInfo deviceinfo;

    // Transaction retry
    int max_retries = 3;

    // Buffered response packet (Samsung/MTP workaround)
    std::vector<uint8_t> response_packet;
    uint32_t response_packet_size = 0;

    // Split header-data flag (MTP devices)
    int split_header_data = 0;

    // Device quirks
    uint32_t device_flags = 0;
};

// ============================================================
// Engine API
// ============================================================

class PTPEngine {
public:
    PTPEngine();

    // ---- Session management ----
    std::vector<uint8_t> buildOpenSession(uint32_t sessionId);
    std::vector<uint8_t> buildCloseSession();

    // ---- Operations ----
    std::vector<uint8_t> buildGetDeviceInfo();
    std::vector<uint8_t> buildGetStorageIDs();
    std::vector<uint8_t> buildGetObjectHandles(uint32_t storageId,
                                                uint32_t formatCode = 0,
                                                uint32_t associationHandle = 0xFFFFFFFF);
    std::vector<uint8_t> buildGetObjectInfo(uint32_t objectHandle);
    std::vector<uint8_t> buildGetThumb(uint32_t objectHandle);
    std::vector<uint8_t> buildGetObject(uint32_t objectHandle);

    // ---- Response handling ----
    // Process a raw USB IN transfer. Returns:
    //   action=0: need more data (caller reads again)
    //   action=1: data phase available (data returned)
    //   action=2: response available (response code in result)
    //   action=-1: error
    struct TransferResult {
        int action;           // 0=need more, 1=data ready, 2=response ready, -1=error
        uint16_t respCode;    // valid when action==2
        std::vector<uint8_t> data;  // valid when action==1
    };

    TransferResult processIncoming(const uint8_t* rawData, size_t len, bool expectData);

    // ---- Helpers ----
    uint32_t currentTid() const { return params.transaction_id; }
    uint16_t lastResponseCode() const { return lastRespCode; }
    const PTPDeviceInfo& getDeviceInfoCache() const { return params.deviceinfo; }

    // ---- Parsing ----
    static PTPDeviceInfo parseDeviceInfo(const uint8_t* data, size_t len);
    static PTPObjectInfo parseObjectInfo(const uint8_t* data, size_t len, uint32_t handle);
    static std::vector<uint32_t> parseU32Array(const uint8_t* data, size_t len);
    static std::string parseUCS2String(const uint8_t* data, size_t maxLen);

private:
    PTPParams params;
    uint16_t lastRespCode = 0;

    // Large data accumulation state
    bool dataPhaseActive = false;
    size_t dataRemaining = 0;
    std::vector<uint8_t> dataAccumulator;
    bool hasPendingResponse = false;
    uint16_t pendingResponseCode = 0;

    void initSendReq(PTPUSBBulkContainer& usbreq, uint16_t code, uint32_t transId,
                     uint32_t p1, uint32_t p2, uint32_t p3, uint32_t p4, uint32_t p5,
                     uint8_t nparam);
    uint16_t getResp(const uint8_t* data, size_t len, PTPContainer& resp);
    std::vector<uint8_t> buildCommand(uint16_t code, const std::vector<uint32_t>& p);
};

// ---- Endian helpers (libgphoto2 htod32/dtoh32) ----

inline uint32_t le32(uint32_t x) {
    // HarmonyOS/ARM is little-endian; these are no-ops but kept for clarity
    return x;
}
inline uint16_t le16(uint16_t x) { return x; }

#endif // PTP_ENGINE_H
