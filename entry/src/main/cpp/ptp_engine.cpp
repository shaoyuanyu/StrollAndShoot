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

// MTP GetObjectPropList 的 5 个参数固定为
// (ObjectHandle, ObjectFormat, PropertyCode, PropertyGroupCode, Depth)，
// 0xFFFFFFFF 表示“全部/不递归限制”。
std::vector<uint8_t> PTPEngine::buildGetObjectPropList(uint32_t objectHandle,
                                                       uint32_t formatCode,
                                                       uint32_t propertyCode,
                                                       uint32_t groupCode,
                                                       uint32_t depth) {
    return buildCommand(PTP_OC_GetObjectPropList,
                        {objectHandle, formatCode, propertyCode, groupCode, depth});
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
            // 一次大图有 6–16MB，按 payloadLen 预留，避免每包 append 时反复扩容拷贝。
            dataAccumulator.reserve(payloadLen);
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

/** Read a uint32 array: 4-byte count + count × uint32 elements. */
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

/**
 * Read a uint16 array (PTP DeviceInfo uses uint16 arrays).
 * Wire format: uint32 count (4 bytes) + count × uint16 elements (2 bytes each).
 * Values are stored as uint32 in the result for simplicity.
 */
static std::vector<uint32_t> readU16Array(const uint8_t* data, size_t dataLen, size_t* offset) {
    std::vector<uint32_t> out;
    if (*offset + 4 > dataLen) return out;
    uint32_t count = *reinterpret_cast<const uint32_t*>(data + *offset);
    *offset += 4;
    if (count == 0 || *offset + count * 2 > dataLen) return out;
    for (uint32_t i = 0; i < count; i++) {
        uint16_t val = static_cast<uint16_t>(data[*offset])
                     | (static_cast<uint16_t>(data[*offset + 1]) << 8);
        out.push_back(val);
        *offset += 2;
    }
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
    // VendorExtensionDesc is a standard PTP string with 1-byte char count
    // prefix, NOT a raw null-terminated UCS-2. Use readPtpString.
    // libgphoto2 confirms: ptp_unpack_string() reads count byte.
    di.VendorExtensionDesc = readPtpString(data, len, &off);
    di.FunctionalMode = readU16();
    // Per PTP spec (ISO 15740) all 5 DeviceInfo arrays are AUINT16
    // (uint32 count + uint16 elements). libgphoto2 confirms this.
    di.OperationsSupported = readU16Array(data, len, &off);
    di.EventsSupported = readU16Array(data, len, &off);
    di.DevicePropertiesSupported = readU16Array(data, len, &off);
    di.CaptureFormats = readU16Array(data, len, &off);
    di.ImageFormats = readU16Array(data, len, &off);
    // Per PTP spec (ISO 15740), the 4 strings follow immediately:
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
    obj.ModificationDate = readPtpString(data, len, &off);

    // Set handle since it doesn't come in the ObjectInfo dataset
    (void)handle; // The handle is passed in separately

    return obj;
}

// ---- GetObjectPropList 数据集解析（MTP 1.1） ----
//
// 数据段布局：UINT32 NumberOfElements，随后每个元素：
//   UINT32 ObjectHandle | UINT16 PropertyCode | UINT16 DataType | 变长 Value
// 同一对象的多个属性连续排列，所以按 handle 合并成一条记录。
// 相机实现千奇百怪，这里遇到不认识的 DataType 就整体放弃（Complete=false），
// 由上层决定要不要用这批数据。

static uint16_t rdU16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

static uint32_t rdU32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

static bool propFixedSize(uint16_t datatype, size_t* size) {
    switch (datatype) {
        case 0x0001: case 0x0002: *size = 1; return true;   // INT8 / UINT8
        case 0x0003: case 0x0004: *size = 2; return true;   // INT16 / UINT16
        case 0x0005: case 0x0006: *size = 4; return true;   // INT32 / UINT32
        case 0x0007: case 0x0008: *size = 8; return true;   // INT64 / UINT64
        case 0x0009: case 0x000A: *size = 16; return true;  // INT128 / UINT128
        default: return false;
    }
}

PTPObjectPropList PTPEngine::parseObjectPropList(const uint8_t* data, size_t len) {
    PTPObjectPropList out;
    if (data == nullptr || len < 4) return out;
    out.Declared = rdU32(data);
    size_t off = 4;
    bool ok = true;

    while (off + 8 <= len) {
        const uint32_t handle = rdU32(data + off);
        const uint16_t code = rdU16(data + off + 4);
        const uint16_t datatype = rdU16(data + off + 6);
        off += 8;

        bool hasFormat = false;
        bool hasSize = false;
        bool hasParent = false;
        uint16_t format = 0;
        uint32_t size = 0;
        uint32_t parent = 0;
        std::string strVal;

        if (datatype == 0xFFFF) {
            strVal = readPtpString(data, len, &off);
            if (off > len) { ok = false; break; }
        } else {
            size_t sz = 0;
            if (!propFixedSize(datatype, &sz) || off + sz > len) { ok = false; break; }
            if (code == 0xDC02 && sz >= 2) {
                format = rdU16(data + off);
                hasFormat = true;
            } else if (code == 0xDC04) {
                if (sz == 8) {
                    const uint64_t v = static_cast<uint64_t>(rdU32(data + off)) |
                                       (static_cast<uint64_t>(rdU32(data + off + 4)) << 32);
                    size = v > 0xFFFFFFFFull ? 0xFFFFFFFFu : static_cast<uint32_t>(v);
                } else if (sz == 4) {
                    size = rdU32(data + off);
                }
                hasSize = true;
            } else if (code == 0xDC0B && sz >= 4) {
                parent = rdU32(data + off);
                hasParent = true;
            }
            off += sz;
        }

        bool seen = false;
        for (size_t i = 0; i < out.PropCodes.size(); i++) {
            if (out.PropCodes[i] == code) { seen = true; break; }
        }
        if (!seen && out.PropCodes.size() < 64) {
            out.PropCodes.push_back(code);
        }

        if (out.Objects.empty() || out.Objects.back().Handle != handle) {
            PTPObjectPropEntry fresh;
            fresh.Handle = handle;
            out.Objects.push_back(fresh);
        }
        PTPObjectPropEntry& cur = out.Objects.back();
        if (hasFormat) cur.Format = format;
        if (hasSize) cur.Size = size;
        if (hasParent) cur.Parent = parent;
        if (!strVal.empty()) {
            if (code == 0xDC07) cur.Filename = strVal;
            else if (code == 0xDC08) cur.DateCreated = strVal;
            else if (code == 0xDC09) cur.DateModified = strVal;
        }
    }

    out.Complete = ok && off == len &&
        (out.Declared == 0 || out.Objects.size() == out.Declared);
    return out;
}

// PTP 规范：GetStorageIDs / GetObjectHandles 的数据阶段是//   NumberOfElements (UINT32) + Elements[] (UINT32 各一)
// 旧实现把整段按 4 字节切开，于是 count 本身被当成第一个元素，凭空多出一个
// 伪 storage / 伪句柄（Nikon 实测：StorageIDs count 2、ObjectHandles 1289，
// 每次扫描多出 10 次 0x2008 与 6 次 0x2009）。
std::vector<uint32_t> PTPEngine::parseCountedU32Array(const uint8_t* data, size_t len) {
    std::vector<uint32_t> out;
    if (data == nullptr || len < 4) return out;
    uint32_t declared = 0;
    std::memcpy(&declared, data, 4);
    size_t available = (len - 4) / 4;
    size_t count = declared < available ? static_cast<size_t>(declared) : available;
    out.reserve(count);
    for (size_t i = 0; i < count; i++) {
        uint32_t v = 0;
        std::memcpy(&v, data + 4 + i * 4, 4);
        out.push_back(v);
    }
    return out;
}

std::vector<uint32_t> PTPEngine::parseU32Array(const uint8_t* data, size_t len) {
    std::vector<uint32_t> out;
    if (data == nullptr || len < 4) return out;
    size_t count = len / 4;
    out.reserve(count);
    for (size_t i = 0; i < count; i++) {
        uint32_t v = 0;
        std::memcpy(&v, data + i * 4, 4);
        out.push_back(v);
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
