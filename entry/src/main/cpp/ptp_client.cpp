#include "ptp_client.h"
#include <cstring>
#include <algorithm>

// ---- Build command ----

std::vector<uint8_t> ptpBuildCommand(uint16_t opCode, uint32_t transactionId,
                                     const std::vector<uint32_t>& params) {
    size_t paramCount = std::min(params.size(), static_cast<size_t>(PTP_MAX_PARAMS));
    size_t totalLen = PTP_CONTAINER_HEADER_SIZE + paramCount * sizeof(uint32_t);
    std::vector<uint8_t> buf(totalLen);

    auto* hdr = reinterpret_cast<PtpContainer*>(buf.data());
    hdr->length        = static_cast<uint32_t>(totalLen);
    hdr->type          = PTP_TYPE_COMMAND;
    hdr->code          = opCode;
    hdr->transactionId = transactionId;

    auto* p = reinterpret_cast<uint32_t*>(buf.data() + PTP_CONTAINER_HEADER_SIZE);
    for (size_t i = 0; i < paramCount; i++) {
        p[i] = params[i];
    }
    return buf;
}

std::vector<uint8_t> ptpBuildOpenSession(uint32_t sessionId, uint32_t transactionId) {
    return ptpBuildCommand(PTP_OC_OpenSession, transactionId, {sessionId});
}

std::vector<uint8_t> ptpBuildCloseSession(uint32_t transactionId) {
    return ptpBuildCommand(PTP_OC_CloseSession, transactionId);
}

std::vector<uint8_t> ptpBuildGetDeviceInfo(uint32_t transactionId) {
    return ptpBuildCommand(PTP_OC_GetDeviceInfo, transactionId);
}

std::vector<uint8_t> ptpBuildGetStorageIDs(uint32_t transactionId) {
    return ptpBuildCommand(PTP_OC_GetStorageIDs, transactionId);
}

std::vector<uint8_t> ptpBuildGetObjectHandles(uint32_t storageId, uint32_t transactionId,
                                              uint32_t formatCode,
                                              uint32_t associationHandle) {
    return ptpBuildCommand(PTP_OC_GetObjectHandles, transactionId,
                           {storageId, formatCode, associationHandle});
}

std::vector<uint8_t> ptpBuildGetObjectInfo(uint32_t objectHandle, uint32_t transactionId) {
    return ptpBuildCommand(PTP_OC_GetObjectInfo, transactionId, {objectHandle});
}

// ---- Parse response ----

PtpResponse ptpParseResponse(const uint8_t* data, size_t len) {
    PtpResponse resp{};
    resp.code      = 0;
    resp.paramCount = 0;
    std::memset(resp.params, 0, sizeof(resp.params));

    if (len < PTP_CONTAINER_HEADER_SIZE) return resp;

    const auto* hdr = reinterpret_cast<const PtpContainer*>(data);
    resp.code          = hdr->code;
    resp.transactionId = hdr->transactionId;

    size_t paramLen = len - PTP_CONTAINER_HEADER_SIZE;
    resp.paramCount = static_cast<uint8_t>(std::min(paramLen / sizeof(uint32_t),
                                                    static_cast<size_t>(PTP_MAX_PARAMS)));
    const auto* src = reinterpret_cast<const uint32_t*>(data + PTP_CONTAINER_HEADER_SIZE);
    for (uint8_t i = 0; i < resp.paramCount; i++) {
        resp.params[i] = src[i];
    }
    return resp;
}

// ---- UCS-2 helper ----

std::string readUcs2String(const uint8_t* data, size_t maxLen) {
    std::string out;
    out.reserve(128);
    size_t i = 0;
    while (i + 1 < maxLen) {
        uint8_t lo = data[i];
        uint8_t hi = data[i + 1];
        if (lo == 0 && hi == 0) break;
        uint16_t ch = static_cast<uint16_t>(lo) | (static_cast<uint16_t>(hi) << 8);
        if (ch < 0x80) {
            out += static_cast<char>(ch);
        } else if (ch < 0x800) {
            out += static_cast<char>(0xC0 | (ch >> 6));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        } else {
            out += static_cast<char>(0xE0 | (ch >> 12));
            out += static_cast<char>(0x80 | ((ch >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        }
        i += 2;
    }
    return out;
}

// Helper: read a UCS-2 string field from a PTP dataset at the current offset.
// Advances *offset past the null-terminated string (aligned to even).
static std::string readUcs2Field(const uint8_t* data, size_t dataLen, size_t* offset) {
    if (*offset >= dataLen) return "";
    std::string s = readUcs2String(data + *offset, dataLen - *offset);
    *offset += (s.length() + 1) * 2; // skip string + null terminator (UCS-2)
    return s;
}

// Helper: read a uint32 array field from a PTP dataset.
// Advances *offset past the array (array length stored as uint32 prefix).
static std::vector<uint32_t> readU32ArrayField(const uint8_t* data, size_t dataLen,
                                               size_t* offset) {
    std::vector<uint32_t> out;
    if (*offset + 4 > dataLen) return out;
    uint32_t count = *reinterpret_cast<const uint32_t*>(data + *offset);
    *offset += 4;
    if (*offset + count * 4 > dataLen) return out;
    const auto* p = reinterpret_cast<const uint32_t*>(data + *offset);
    for (uint32_t i = 0; i < count; i++) {
        out.push_back(p[i]);
    }
    *offset += count * 4;
    return out;
}

// ---- Parse DeviceInfo dataset ----
//
// DeviceInfo dataset layout (PTP spec):
//   uint16 StandardVersion
//   uint32 VendorExtensionID
//   uint16 VendorExtensionVersion
//   string VendorExtensionDesc (UCS-2, null-term)
//   uint16 FunctionalMode
//   uint32[] OperationsSupported
//   uint32[] EventsSupported
//   uint32[] DevicePropertiesSupported
//   uint32[] CaptureFormats
//   uint32[] ImageFormats    (or uint32[] PlaybackFormats before them...)
//   string Manufacturer (UCS-2)
//   string Model (UCS-2)
//   string DeviceVersion (UCS-2)
//   string SerialNumber (UCS-2)

PtpDeviceInfo ptpParseDeviceInfo(const uint8_t* data, size_t len) {
    PtpDeviceInfo info{};
    size_t off = 0;

    // StandardVersion (2 bytes)
    if (off + 2 > len) return info;
    off += 2;

    // VendorExtensionID (4 bytes)
    if (off + 4 > len) return info;
    off += 4;

    // VendorExtensionVersion (2 bytes)
    if (off + 2 > len) return info;
    off += 2;

    // VendorExtensionDesc (UCS-2 string)
    readUcs2Field(data, len, &off);

    // FunctionalMode (2 bytes)
    if (off + 2 > len) return info;
    off += 2;

    // OperationsSupported[] (uint32 array)
    readU32ArrayField(data, len, &off);

    // EventsSupported[] (uint32 array)
    readU32ArrayField(data, len, &off);

    // DevicePropertiesSupported[] (uint32 array)
    readU32ArrayField(data, len, &off);

    // CaptureFormats[] (uint32 array)
    readU32ArrayField(data, len, &off);

    // ImageFormats[] or PlaybackFormats[] or similar (uint32 array)
    // Some cameras have ImageFormats, some have PlaybackFormats, some have both.
    // For now, read one more array (this is a simplified heuristic).
    readU32ArrayField(data, len, &off);

    // Now the strings: Manufacturer, Model, DeviceVersion, SerialNumber
    info.manufacturer  = readUcs2Field(data, len, &off);
    info.model         = readUcs2Field(data, len, &off);
    info.deviceVersion = readUcs2Field(data, len, &off);
    info.serialNumber  = readUcs2Field(data, len, &off);

    return info;
}

// ---- Parse StorageIDs ----

std::vector<uint32_t> ptpParseStorageIDs(const uint8_t* data, size_t len) {
    std::vector<uint32_t> out;
    size_t count = len / sizeof(uint32_t);
    const auto* p = reinterpret_cast<const uint32_t*>(data);
    for (size_t i = 0; i < count; i++) {
        out.push_back(p[i]);
    }
    return out;
}

// ---- Parse ObjectHandles ----

std::vector<uint32_t> ptpParseObjectHandles(const uint8_t* data, size_t len) {
    std::vector<uint32_t> out;
    size_t count = len / sizeof(uint32_t);
    const auto* p = reinterpret_cast<const uint32_t*>(data);
    for (size_t i = 0; i < count; i++) {
        out.push_back(p[i]);
    }
    return out;
}

// ---- Parse ObjectInfo dataset ----
//
// ObjectInfo dataset:
//   uint32 StorageID
//   uint16 ObjectFormatCode
//   uint16 ProtectionStatus
//   uint32 ObjectCompressedSize
//   uint16 ThumbFormat
//   uint32 ThumbCompressedSize
//   uint32 ThumbPixWidth
//   uint32 ThumbPixHeight
//   uint32 ImagePixWidth
//   uint32 ImagePixHeight
//   uint32 ImageBitDepth
//   uint32 ParentObject
//   uint16 AssociationType
//   uint32 AssociationDesc
//   uint32 SequenceNumber
//   string Filename (UCS-2)
//   string CaptureDate (UCS-2)
//   string ModificationDate (UCS-2)
//   string Keywords (UCS-2)

PtpObjectInfo ptpParseObjectInfo(const uint8_t* data, size_t len) {
    PtpObjectInfo obj{};
    size_t off = 0;

    if (off + 4 > len) return obj;
    obj.handle = *reinterpret_cast<const uint32_t*>(data + off);
    off += 4; // StorageID (we override with the handle passed in)

    if (off + 2 > len) return obj;
    obj.format = *reinterpret_cast<const uint16_t*>(data + off);
    off += 2;

    // ProtectionStatus (2)
    if (off + 2 > len) return obj;
    off += 2;

    // ObjectCompressedSize (4)
    if (off + 4 > len) return obj;
    obj.size = *reinterpret_cast<const uint32_t*>(data + off);
    off += 4;

    // ThumbFormat (2) + ThumbCompressedSize (4) + ThumbPixWidth (4) + ThumbPixHeight (4)
    off += 2 + 4 + 4 + 4;

    // ImagePixWidth (4) + ImagePixHeight (4) + ImageBitDepth (4)
    off += 4 + 4 + 4;

    // ParentObject (4) + AssociationType (2) + AssociationDesc (4) + SequenceNumber (4)
    off += 4 + 2 + 4 + 4;

    // Filename (UCS-2)
    obj.filename = readUcs2Field(data, len, &off);

    return obj;
}
