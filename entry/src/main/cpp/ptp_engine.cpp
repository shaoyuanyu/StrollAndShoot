#include "ptp_engine.h"
#include <cstring>
#include <algorithm>

// ============================================================
// PTPEngine implementation — ported from libgphoto2
// ============================================================

PTPEngine::PTPEngine() {
    params.session_id = 0;
    params.transaction_id = 0;
    params.response_packet_size = 0;
    params.split_header_data = 0;
    params.device_flags = 0;
}

// ---- initSendReq: build USB container (usb.c:52) ----
void PTPEngine::initSendReq(PTPUSBBulkContainer& usbreq, uint16_t code, uint32_t transId,
                             uint32_t p1, uint32_t p2, uint32_t p3, uint32_t p4, uint32_t p5,
                             uint8_t nparam) {
    std::memset(&usbreq, 0, sizeof(usbreq));
    usbreq.length   = le32(PTP_USB_BULK_REQ_LEN - sizeof(uint32_t)*(5 - nparam));
    usbreq.type     = le16(PTP_USB_CONTAINER_COMMAND);
    usbreq.code     = le16(code);
    usbreq.trans_id = le32(transId);
    usbreq.payload.params.param1 = le32(p1);
    usbreq.payload.params.param2 = le32(p2);
    usbreq.payload.params.param3 = le32(p3);
    usbreq.payload.params.param4 = le32(p4);
    usbreq.payload.params.param5 = le32(p5);
}

std::vector<uint8_t> PTPEngine::buildCommand(uint16_t code, const std::vector<uint32_t>& p) {
    // Reset large data accumulation for new transaction
    dataPhaseActive = false;
    dataRemaining = 0;
    dataAccumulator.clear();
    hasPendingResponse = false;

    PTPUSBBulkContainer usbreq;
    uint32_t p1=0, p2=0, p3=0, p4=0, p5=0;
    uint8_t np = static_cast<uint8_t>(std::min(p.size(), size_t(5)));
    if (np > 0) p1 = p[0];
    if (np > 1) p2 = p[1];
    if (np > 2) p3 = p[2];
    if (np > 3) p4 = p[3];
    if (np > 4) p5 = p[4];
    initSendReq(usbreq, code, params.transaction_id++, p1, p2, p3, p4, p5, np);

    uint32_t towrite = PTP_USB_BULK_REQ_LEN - sizeof(uint32_t)*(5 - np);
    std::vector<uint8_t> buf(towrite);
    std::memcpy(buf.data(), &usbreq, towrite);
    return buf;
}

// ---- Session management (ptp.c:1923) ----
std::vector<uint8_t> PTPEngine::buildOpenSession(uint32_t sessionId) {
    // Reset state (ptp_opensession)
    params.session_id = 0;
    params.transaction_id = 0;
    params.response_packet.clear();
    params.response_packet_size = 0;
    params.split_header_data = 0;

    // Build OpenSession command with sessionId as param1
    std::vector<uint8_t> cmd = buildCommand(PTP_OC_OpenSession, {sessionId});

    // On success, the caller will call completeOpenSession()
    // but we don't have callbacks, so caller handles it
    return cmd;
}

void completeOpenSession(PTPEngine& eng, uint32_t sessionId) {
    // Called after successful OpenSession response
    // In libgphoto2 this sets params->session_id = session
    // We access via public method
}

std::vector<uint8_t> PTPEngine::buildCloseSession() {
    return buildCommand(PTP_OC_CloseSession, {});
}

std::vector<uint8_t> PTPEngine::buildGetDeviceInfo() {
    return buildCommand(PTP_OC_GetDeviceInfo, {});
}

std::vector<uint8_t> PTPEngine::buildGetStorageIDs() {
    return buildCommand(PTP_OC_GetStorageIDs, {});
}

std::vector<uint8_t> PTPEngine::buildGetObjectHandles(uint32_t storageId,
                                                       uint32_t formatCode,
                                                       uint32_t associationHandle) {
    return buildCommand(PTP_OC_GetObjectHandles, {storageId, formatCode, associationHandle});
}

std::vector<uint8_t> PTPEngine::buildGetObjectInfo(uint32_t objectHandle) {
    return buildCommand(PTP_OC_GetObjectInfo, {objectHandle});
}

std::vector<uint8_t> PTPEngine::buildGetThumb(uint32_t objectHandle) {
    return buildCommand(PTP_OC_GetThumb, {objectHandle});
}

std::vector<uint8_t> PTPEngine::buildGetObject(uint32_t objectHandle) {
    return buildCommand(PTP_OC_GetObject, {objectHandle});
}

std::vector<uint8_t> PTPEngine::buildGetPartialObject(uint32_t objectHandle,
                                                       uint32_t offset,
                                                       uint32_t maxBytes) {
    return buildCommand(PTP_OC_GetPartialObject, {objectHandle, offset, maxBytes});
}

// ---- getResp: parse response container (usb.c:466) ----
uint16_t PTPEngine::getResp(const uint8_t* data, size_t len, PTPContainer& resp) {
    if (len < 12) return 0xFFFF; // error

    const auto* usbresp = reinterpret_cast<const PTPUSBBulkContainer*>(data);
    uint32_t rlen_u32 = static_cast<uint32_t>(len);

    if (rlen_u32 != le32(usbresp->length)) return 0xFFFF;
    if (le16(usbresp->type) != PTP_USB_CONTAINER_RESPONSE) return 0xFFFF;

    resp.Code = le16(usbresp->code);
    resp.SessionID = params.session_id;
    resp.Transaction_ID = le32(usbresp->trans_id);
    resp.Nparam = static_cast<uint8_t>((rlen_u32 - 12) / 4);
    resp.Param1 = le32(usbresp->payload.params.param1);
    resp.Param2 = le32(usbresp->payload.params.param2);
    resp.Param3 = le32(usbresp->payload.params.param3);
    resp.Param4 = le32(usbresp->payload.params.param4);
    resp.Param5 = le32(usbresp->payload.params.param5);

    return resp.Code;
}

// ---- processIncoming: handle USB IN data (response, data phase, or data continuation) ----
PTPEngine::TransferResult PTPEngine::processIncoming(const uint8_t* rawData, size_t len,
                                                      bool expectData) {
    TransferResult result;
    result.action = -1;
    result.respCode = 0;

    if (len == 0) {
        result.action = 0;
        return result;
    }

    // Check for pending response from previous large-data completion
    if (hasPendingResponse) {
        hasPendingResponse = false;
        result.action = 2;
        result.respCode = pendingResponseCode;
        lastRespCode = pendingResponseCode;
        return result;
    }

    // If we're in a large data phase, accumulate raw bytes
    if (dataPhaseActive) {
        size_t copyLen = std::min(len, dataRemaining);
        dataAccumulator.insert(dataAccumulator.end(), rawData, rawData + copyLen);
        dataRemaining -= copyLen;

        if (dataRemaining == 0) {
            result.data = std::move(dataAccumulator);
            result.action = 1;
            dataPhaseActive = false;
            dataAccumulator.clear();

            // Check if leftover bytes form a response (merged in same USB read)
            size_t leftover = len - copyLen;
            if (leftover >= PTP_USB_BULK_HDR_LEN) {
                const auto* tail = reinterpret_cast<const PTPUSBBulkContainer*>(rawData + copyLen);
                if (le16(tail->type) == PTP_USB_CONTAINER_RESPONSE) {
                    PTPContainer resp;
                    pendingResponseCode = getResp(rawData + copyLen, leftover, resp);
                    hasPendingResponse = true;
                }
            }
            return result;
        }
        result.action = 0;
        return result;
    }

    if (len < PTP_USB_BULK_HDR_LEN) {
        result.action = 0;
        return result;
    }

    const auto* container = reinterpret_cast<const PTPUSBBulkContainer*>(rawData);
    uint16_t type = le16(container->type);

    if (type == PTP_USB_CONTAINER_RESPONSE) {
        PTPContainer resp;
        uint16_t code = getResp(rawData, len, resp);
        result.action = 2;
        result.respCode = code;
        lastRespCode = code;
        return result;
    }

    if (type == PTP_USB_CONTAINER_DATA && expectData) {
        uint32_t totalLen = le32(container->length);
        (void)le16(container->code);

        size_t payloadLen = (totalLen > PTP_USB_BULK_HDR_LEN)
                            ? (totalLen - PTP_USB_BULK_HDR_LEN) : 0;

        if (payloadLen == 0) {
            result.action = 1;
            return result;
        }

        size_t dataOffset = PTP_USB_BULK_HDR_LEN;
        size_t firstChunkLen = std::min(len - dataOffset, payloadLen);

        if (firstChunkLen >= payloadLen) {
            result.data.assign(rawData + dataOffset, rawData + dataOffset + payloadLen);
            result.action = 1;
        } else {
            dataAccumulator.assign(rawData + dataOffset, rawData + dataOffset + firstChunkLen);
            dataRemaining = payloadLen - firstChunkLen;
            dataPhaseActive = true;
            result.action = 0;
        }
        return result;
    }

    // Unknown type, might be raw data continuation
    result.action = 0;
    return result;
}

// ---- Device Info parsing (ptp.c: ptp_unpack_DI, simplified) ----

// Read UCS-2LE null-terminated string WITHOUT count byte prefix
// (used for VendorExtensionDesc in DeviceInfo)
static std::string readUCS2Raw(const uint8_t* data, size_t dataLen, size_t* offset) {
    if (*offset >= dataLen) return "";
    std::string out;
    while (*offset + 1 < dataLen) {
        uint16_t ch = static_cast<uint16_t>(data[*offset])
                    | (static_cast<uint16_t>(data[*offset + 1]) << 8);
        *offset += 2;
        if (ch == 0) break;
        if (ch < 0x80) out += static_cast<char>(ch);
        else if (ch < 0x800) {
            out += static_cast<char>(0xC0 | (ch >> 6));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        } else {
            out += static_cast<char>(0xE0 | (ch >> 12));
            out += static_cast<char>(0x80 | ((ch >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        }
    }
    return out;
}

// Read PTP string with 1-byte character count prefix
// (used for Manufacturer, Model, DeviceVersion, SerialNumber)
static std::string readPtpString(const uint8_t* data, size_t dataLen, size_t* offset) {
    if (*offset >= dataLen) return "";
    uint8_t charCount = data[*offset];
    *offset += 1;

    // Read exactly charCount UCS-2LE characters
    std::string out;
    for (uint8_t i = 0; i < charCount && *offset + 1 < dataLen; i++) {
        uint16_t ch = static_cast<uint16_t>(data[*offset])
                    | (static_cast<uint16_t>(data[*offset + 1]) << 8);
        *offset += 2;
        if (ch == 0) continue; // skip nulls embedded in string
        if (ch < 0x80) out += static_cast<char>(ch);
        else if (ch < 0x800) {
            out += static_cast<char>(0xC0 | (ch >> 6));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        } else {
            out += static_cast<char>(0xE0 | (ch >> 12));
            out += static_cast<char>(0x80 | ((ch >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        }
    }
    return out;
}

static std::vector<uint32_t> readU32Array(const uint8_t* data, size_t dataLen, size_t* offset) {
    std::vector<uint32_t> out;
    if (*offset + 4 > dataLen) return out;
    uint32_t count = *reinterpret_cast<const uint32_t*>(data + *offset);
    *offset += 4;
    if (count == 0 || *offset + count * 4 > dataLen) return out;
    for (uint32_t i = 0; i < count; i++) {
        out.push_back(reinterpret_cast<const uint32_t*>(data + *offset)[i]);
    }
    *offset += count * 4;
    return out;
}

PTPDeviceInfo PTPEngine::parseDeviceInfo(const uint8_t* data, size_t len) {
    PTPDeviceInfo di;
    size_t off = 0;

    auto readU16 = [&]() -> uint16_t {
        if (off + 2 > len) return 0;
        uint16_t v = data[off] | (static_cast<uint16_t>(data[off+1]) << 8);
        off += 2;
        return v;
    };
    auto readU32 = [&]() -> uint32_t {
        if (off + 4 > len) return 0;
        uint32_t v = *reinterpret_cast<const uint32_t*>(data + off);
        off += 4;
        return v;
    };

    di.StandardVersion = readU16();
    di.VendorExtensionID = readU32();
    di.VendorExtensionVersion = readU16();
    di.VendorExtensionDesc = readUCS2Raw(data, len, &off); // no count byte
    di.FunctionalMode = readU16();
    di.OperationsSupported = readU32Array(data, len, &off);
    di.EventsSupported = readU32Array(data, len, &off);
    di.DevicePropertiesSupported = readU32Array(data, len, &off);
    di.CaptureFormats = readU32Array(data, len, &off);
    di.ImageFormats = readU32Array(data, len, &off);
    // MTP devices (VendorExtensionID == 0xFFFFFFFF) have an extra
    // PlaybackFormats array between ImageFormats and the string fields
    if (di.VendorExtensionID == 0xFFFFFFFF || di.VendorExtensionID == 0x00000006) {
        readU32Array(data, len, &off); // PlaybackFormats (skip)
    }
    di.Manufacturer = readPtpString(data, len, &off);
    di.Model = readPtpString(data, len, &off);
    di.DeviceVersion = readPtpString(data, len, &off);
    di.SerialNumber = readPtpString(data, len, &off);

    return di;
}

PTPObjectInfo PTPEngine::parseObjectInfo(const uint8_t* data, size_t len, uint32_t handle) {
    PTPObjectInfo obj;
    size_t off = 0;
    auto readU16 = [&]() -> uint16_t {
        if (off + 2 > len) return 0;
        uint16_t v = data[off] | (static_cast<uint16_t>(data[off+1]) << 8);
        off += 2; return v;
    };
    auto readU32 = [&]() -> uint32_t {
        if (off + 4 > len) return 0;
        uint32_t v = *reinterpret_cast<const uint32_t*>(data + off);
        off += 4; return v;
    };

    obj.StorageID = readU32();
    obj.ObjectFormat = readU16();
    obj.ProtectionStatus = readU16();
    obj.ObjectCompressedSize = readU32();
    obj.ThumbFormat = readU16();
    obj.ThumbCompressedSize = readU32();
    obj.ThumbPixWidth = readU32();
    obj.ThumbPixHeight = readU32();
    obj.ImagePixWidth = readU32();
    obj.ImagePixHeight = readU32();
    obj.ImageBitDepth = readU32();
    obj.ParentObject = readU32();
    obj.AssociationType = readU16();
    obj.AssociationDesc = readU32();
    obj.SequenceNumber = readU32();
    obj.Filename = readPtpString(data, len, &off);
    obj.CaptureDate = readPtpString(data, len, &off);
    obj.ModificationDate = readUCS2Raw(data, len, &off);

    // Set handle since it doesn't come in the ObjectInfo dataset
    (void)handle; // The handle is passed in separately

    return obj;
}

std::vector<uint32_t> PTPEngine::parseU32Array(const uint8_t* data, size_t len) {
    std::vector<uint32_t> out;
    if (len < 4) return out;
    size_t count = len / 4;
    for (size_t i = 0; i < count; i++) {
        out.push_back(reinterpret_cast<const uint32_t*>(data)[i]);
    }
    return out;
}

std::string PTPEngine::parseUCS2String(const uint8_t* data, size_t maxLen) {
    std::string out;
    for (size_t i = 0; i + 1 < maxLen; i += 2) {
        uint16_t ch = static_cast<uint16_t>(data[i])
                    | (static_cast<uint16_t>(data[i + 1]) << 8);
        if (ch == 0) break;
        if (ch < 0x80) out += static_cast<char>(ch);
        else if (ch < 0x800) {
            out += static_cast<char>(0xC0 | (ch >> 6));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        } else {
            out += static_cast<char>(0xE0 | (ch >> 12));
            out += static_cast<char>(0x80 | ((ch >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (ch & 0x3F));
        }
    }
    return out;
}
