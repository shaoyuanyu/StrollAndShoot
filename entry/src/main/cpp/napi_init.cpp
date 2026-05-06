#include "napi/native_api.h"
#include "ptp_engine.h"
#include "ptp_ddk_transport.h"
#include <cstring>
#include <vector>

// ============================================================
// NAPI helpers
// ============================================================

static napi_value MakeUint8Array(napi_env env, const std::vector<uint8_t>& data) {
    void* ptr = nullptr;
    napi_value buf;
    napi_create_arraybuffer(env, data.size(), &ptr, &buf);
    std::memcpy(ptr, data.data(), data.size());
    napi_value result;
    napi_create_typedarray(env, napi_uint8_array, data.size(), buf, 0, &result);
    return result;
}

static napi_value MakeEmptyUint8Array(napi_env env) {
    napi_value result;
    void* ptr = nullptr;
    napi_value buf;
    napi_create_arraybuffer(env, 0, &ptr, &buf);
    napi_create_typedarray(env, napi_uint8_array, 0, buf, 0, &result);
    return result;
}

static std::vector<uint8_t> GetUint8Array(napi_env env, napi_value val) {
    std::vector<uint8_t> out;
    bool isTypedArray = false;
    napi_is_typedarray(env, val, &isTypedArray);
    if (!isTypedArray) return out;
    napi_typedarray_type type;
    size_t len = 0;
    void* data = nullptr;
    napi_value buf;
    size_t offset = 0;
    napi_get_typedarray_info(env, val, &type, &len, &data, &buf, &offset);
    if (type == napi_uint8_array && data != nullptr) {
        out.assign(static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + len);
    }
    return out;
}

static napi_value MakeDeviceInfoObj(napi_env env, const PTPDeviceInfo& di) {
    napi_value obj;
    napi_create_object(env, &obj);

    auto setStr = [&](const char* key, const std::string& val) {
        napi_value v;
        napi_create_string_utf8(env, val.c_str(), NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, obj, key, v);
    };
    auto setU32 = [&](const char* key, uint32_t val) {
        napi_value v;
        napi_create_uint32(env, val, &v);
        napi_set_named_property(env, obj, key, v);
    };

    setU32("standardVersion", di.StandardVersion);
    setU32("vendorExtensionID", di.VendorExtensionID);
    setU32("vendorExtensionVersion", di.VendorExtensionVersion);
    setStr("vendorExtensionDesc", di.VendorExtensionDesc);
    setU32("functionalMode", di.FunctionalMode);
    setStr("manufacturer", di.Manufacturer);
    setStr("model", di.Model);
    setStr("deviceVersion", di.DeviceVersion);
    setStr("serialNumber", di.SerialNumber);
    return obj;
}

static napi_value MakeU32Array(napi_env env, const std::vector<uint32_t>& vals) {
    napi_value arr;
    napi_create_array_with_length(env, vals.size(), &arr);
    for (size_t i = 0; i < vals.size(); i++) {
        napi_value v;
        napi_create_uint32(env, vals[i], &v);
        napi_set_element(env, arr, i, v);
    }
    return arr;
}

static napi_value MakeObjectInfoObj(napi_env env, const PTPObjectInfo& obj) {
    napi_value o;
    napi_create_object(env, &o);
    auto setU32 = [&](const char* key, uint32_t val) {
        napi_value v;
        napi_create_uint32(env, val, &v);
        napi_set_named_property(env, o, key, v);
    };
    auto setStr = [&](const char* key, const std::string& val) {
        napi_value v;
        napi_create_string_utf8(env, val.c_str(), NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, o, key, v);
    };
    setU32("storageId", obj.StorageID);
    setU32("objectFormat", obj.ObjectFormat);
    setU32("objectCompressedSize", obj.ObjectCompressedSize);
    setU32("imagePixWidth", obj.ImagePixWidth);
    setU32("imagePixHeight", obj.ImagePixHeight);
    setStr("filename", obj.Filename);
    setStr("captureDate", obj.CaptureDate);
    return o;
}

// ============================================================
// Global engine singleton
// ============================================================

static PTPEngine g_engine;

// ============================================================
// Exported NAPI functions
// ============================================================

// ---- Command builders (return Uint8Array to send via USB) ----

static napi_value BuildOpenSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t sessionId = 1;
    if (argc > 0) napi_get_value_uint32(env, args[0], &sessionId);
    auto data = g_engine.buildOpenSession(sessionId);
    return MakeUint8Array(env, data);
}

static napi_value BuildCloseSession(napi_env env, napi_callback_info info) {
    auto data = g_engine.buildCloseSession();
    return MakeUint8Array(env, data);
}

static napi_value BuildGetDeviceInfo(napi_env env, napi_callback_info info) {
    auto data = g_engine.buildGetDeviceInfo();
    return MakeUint8Array(env, data);
}

static napi_value BuildGetStorageIDs(napi_env env, napi_callback_info info) {
    auto data = g_engine.buildGetStorageIDs();
    return MakeUint8Array(env, data);
}

static napi_value BuildGetObjectHandles(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t storageId = 0, formatCode = 0, associationHandle = 0xFFFFFFFF;
    if (argc > 0) napi_get_value_uint32(env, args[0], &storageId);
    if (argc > 1) napi_get_value_uint32(env, args[1], &formatCode);
    if (argc > 2) napi_get_value_uint32(env, args[2], &associationHandle);
    auto data = g_engine.buildGetObjectHandles(storageId, formatCode, associationHandle);
    return MakeUint8Array(env, data);
}

static napi_value BuildGetObjectInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t objectHandle = 0;
    if (argc > 0) napi_get_value_uint32(env, args[0], &objectHandle);
    auto data = g_engine.buildGetObjectInfo(objectHandle);
    return MakeUint8Array(env, data);
}

static napi_value BuildGetThumb(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t objectHandle = 0;
    if (argc > 0) napi_get_value_uint32(env, args[0], &objectHandle);
    auto data = g_engine.buildGetThumb(objectHandle);
    return MakeUint8Array(env, data);
}

static napi_value BuildGetObject(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t objectHandle = 0;
    if (argc > 0) napi_get_value_uint32(env, args[0], &objectHandle);
    auto data = g_engine.buildGetObject(objectHandle);
    return MakeUint8Array(env, data);
}

// ---- Response processor ----

static napi_value ProcessResponse(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto raw = GetUint8Array(env, args[0]);
    bool expectData = false;
    if (argc > 1) {
        napi_get_value_bool(env, args[1], &expectData);
    }

    // Handle zero-length packet
    if (raw.empty()) {
        napi_value result;
        napi_create_object(env, &result);
        napi_value act;
        napi_create_int32(env, 0, &act); // action=0: read again
        napi_set_named_property(env, result, "action", act);
        return result;
    }

    auto tr = g_engine.processIncoming(raw.data(), raw.size(), expectData);

    napi_value result;
    napi_create_object(env, &result);

    napi_value act;
    napi_create_int32(env, tr.action, &act);
    napi_set_named_property(env, result, "action", act);

    if (tr.action == 2) { // response
        napi_value code;
        napi_create_uint32(env, tr.respCode, &code);
        napi_set_named_property(env, result, "responseCode", code);
    }

    if (tr.action == 1 && !tr.data.empty()) { // data
        napi_value dataArr = MakeUint8Array(env, tr.data);
        napi_set_named_property(env, result, "data", dataArr);
    } else if (tr.action == 1) { // data but empty, need to read more
        napi_value dataArr = MakeEmptyUint8Array(env);
        napi_set_named_property(env, result, "data", dataArr);
    }

    return result;
}

// ---- Parsers ----

static napi_value ParseDeviceInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto raw = GetUint8Array(env, args[0]);
    auto di = PTPEngine::parseDeviceInfo(raw.data(), raw.size());
    return MakeDeviceInfoObj(env, di);
}

static napi_value ParseStorageIDs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto raw = GetUint8Array(env, args[0]);
    auto ids = PTPEngine::parseU32Array(raw.data(), raw.size());
    return MakeU32Array(env, ids);
}

static napi_value ParseObjectHandles(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto raw = GetUint8Array(env, args[0]);
    auto handles = PTPEngine::parseU32Array(raw.data(), raw.size());
    return MakeU32Array(env, handles);
}

static napi_value ParseObjectInfo(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto raw = GetUint8Array(env, args[0]);
    uint32_t handle = 0;
    if (argc > 1) napi_get_value_uint32(env, args[1], &handle);
    auto obj = PTPEngine::parseObjectInfo(raw.data(), raw.size(), handle);
    return MakeObjectInfoObj(env, obj);
}

// ---- DDK Driver NAPI functions ----

static napi_value PtpDriverInit(napi_env env, napi_callback_info info) {
    int ret = ptp_ddk_init();
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static napi_value PtpDriverInitDevice(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t deviceId = 0;
    if (argc > 0) napi_get_value_int64(env, args[0], &deviceId);
    bool ok = ptp_ddk_init_device(static_cast<uint64_t>(deviceId));
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

static napi_value PtpDriverReleaseDevice(napi_env env, napi_callback_info info) {
    ptp_ddk_release_device();
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// Helper: do a full PTP transaction (command → data → response)
// Returns raw data phase bytes, or empty on error.
static std::vector<uint8_t> doPtpTransaction(const std::vector<uint8_t>& cmd, bool expectData) {
    if (!ptp_ddk_send_command(cmd)) return {};

    std::vector<uint8_t> dataResult;

    for (int attempt = 0; attempt < 20; attempt++) {
        auto raw = ptp_ddk_read_data(expectData ? 3000 : 5000, expectData);
        if (raw.empty()) continue;

        auto result = g_engine.processIncoming(raw.data(), raw.size(), expectData);

        if (result.action == 1 && !result.data.empty()) {
            dataResult = std::move(result.data);
        }
        if (result.action == 2) {
            if (result.respCode == 0x2001) {
                return expectData ? dataResult : std::vector<uint8_t>{1};
            }
            return {};
        }
        if (result.action == -1) return {};
    }
    return {};
}

// execute(cmd: string, arg: number) -> Uint8Array
// For no-data commands (openSession, closeSession): returns [1] on success, [] on error
// For data commands: returns raw data phase bytes, or [] on error
static napi_value PtpDriverExecute(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t cmdLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &cmdLen);
    std::string cmd(cmdLen, '\0');
    napi_get_value_string_utf8(env, args[0], &cmd[0], cmdLen + 1, &cmdLen);

    uint32_t arg = 0;
    if (argc > 1) napi_get_value_uint32(env, args[1], &arg);

    std::vector<uint8_t> ptpCmd;
    bool expectData = false;

    if (cmd == "openSession") {
        ptpCmd = g_engine.buildOpenSession(arg > 0 ? arg : 1);
    } else if (cmd == "closeSession") {
        ptpCmd = g_engine.buildCloseSession();
    } else if (cmd == "getDeviceInfo") {
        ptpCmd = g_engine.buildGetDeviceInfo();
        expectData = true;
    } else if (cmd == "getStorageIDs") {
        ptpCmd = g_engine.buildGetStorageIDs();
        expectData = true;
    } else if (cmd == "getObjectHandles") {
        ptpCmd = g_engine.buildGetObjectHandles(arg);
        expectData = true;
    } else if (cmd == "getObjectInfo") {
        ptpCmd = g_engine.buildGetObjectInfo(arg);
        expectData = true;
    } else if (cmd == "getThumb") {
        ptpCmd = g_engine.buildGetThumb(arg);
        expectData = true;
    } else {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return MakeEmptyUint8Array(env);
    }

    std::vector<uint8_t> result = doPtpTransaction(ptpCmd, expectData);
    return MakeUint8Array(env, result);
}

// getLargeData(handle: number) -> Uint8Array | null
static napi_value PtpDriverGetLargeData(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t handle = 0;
    if (argc > 0) napi_get_value_uint32(env, args[0], &handle);

    auto cmd = g_engine.buildGetObject(handle);
    if (!ptp_ddk_send_command(cmd)) return MakeEmptyUint8Array(env);

    // Read data phase using DMA buffer
    auto data = ptp_ddk_read_data(10000, true);
    // Read response
    ptp_ddk_read_data(5000, false);

    return MakeUint8Array(env, data);
}

// ---- Module init ----

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"buildOpenSession",   nullptr, BuildOpenSession,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildCloseSession",  nullptr, BuildCloseSession,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildGetDeviceInfo", nullptr, BuildGetDeviceInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildGetStorageIDs", nullptr, BuildGetStorageIDs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildGetObjectHandles", nullptr, BuildGetObjectHandles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildGetObjectInfo", nullptr, BuildGetObjectInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildGetThumb",    nullptr, BuildGetThumb,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildGetObject",   nullptr, BuildGetObject,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"processResponse",    nullptr, ProcessResponse,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseDeviceInfo",    nullptr, ParseDeviceInfo,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseStorageIDs",    nullptr, ParseStorageIDs,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseObjectHandles", nullptr, ParseObjectHandles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseObjectInfo",    nullptr, ParseObjectInfo,    nullptr, nullptr, nullptr, napi_default, nullptr},
        // DDK driver functions
        {"init",               nullptr, PtpDriverInit,        nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initDevice",         nullptr, PtpDriverInitDevice,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseDevice",      nullptr, PtpDriverReleaseDevice, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execute",            nullptr, PtpDriverExecute,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLargeData",       nullptr, PtpDriverGetLargeData, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&demoModule);
}
