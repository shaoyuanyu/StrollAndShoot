#include "napi/native_api.h"
#include "ptp_engine.h"
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
    setStr("modificationDate", obj.ModificationDate);
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

static napi_value BuildGetPartialObject(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t objectHandle = 0, offset = 0, maxBytes = 16384;
    if (argc > 0) napi_get_value_uint32(env, args[0], &objectHandle);
    if (argc > 1) napi_get_value_uint32(env, args[1], &offset);
    if (argc > 2) napi_get_value_uint32(env, args[2], &maxBytes);
    auto data = g_engine.buildGetPartialObject(objectHandle, offset, maxBytes);
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
        {"buildGetPartialObject", nullptr, BuildGetPartialObject, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"processResponse",    nullptr, ProcessResponse,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseDeviceInfo",    nullptr, ParseDeviceInfo,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseStorageIDs",    nullptr, ParseStorageIDs,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseObjectHandles", nullptr, ParseObjectHandles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseObjectInfo",    nullptr, ParseObjectInfo,    nullptr, nullptr, nullptr, napi_default, nullptr},
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
