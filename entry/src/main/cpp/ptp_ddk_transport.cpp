#include "ptp_ddk_transport.h"
#include <usb/usb_ddk_api.h>
#include <usb/usb_ddk_types.h>
#include <hilog/log.h>
#include <cstring>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "PtpDdk"

static uint64_t g_interfaceHandle = 0;
static uint64_t g_deviceId = 0;
static uint8_t g_bulkOutEp = 0;
static uint8_t g_bulkInEp = 0;
static uint16_t g_maxPacketSize = 512;
static UsbDeviceMemMap* g_devMmap = nullptr;
static size_t g_mmapSize = 4 * 1024 * 1024;
static bool g_initialized = false;

int ptp_ddk_init() {
    int ret = OH_Usb_Init();
    OH_LOG_INFO(LOG_APP, "OH_Usb_Init: %{public}d", ret);
    if (ret == USB_DDK_SUCCESS) {
        g_initialized = true;
    }
    return ret;
}

bool ptp_ddk_init_device(uint64_t deviceId) {
    if (!g_initialized) return false;
    g_deviceId = deviceId;

    UsbDeviceDescriptor devDesc;
    int ret = OH_Usb_GetDeviceDescriptor(deviceId, &devDesc);
    OH_LOG_INFO(LOG_APP, "GetDeviceDescriptor: %{public}d", ret);
    if (ret != USB_DDK_SUCCESS) return false;

    UsbDdkConfigDescriptor* config = nullptr;
    ret = OH_Usb_GetConfigDescriptor(deviceId, 0, &config);
    OH_LOG_INFO(LOG_APP, "GetConfigDescriptor: %{public}d", ret);
    if (ret != USB_DDK_SUCCESS || !config) return false;

    uint8_t ptpInterface = 0xFF;
    for (uint8_t i = 0; i < config->configDescriptor.bNumInterfaces; i++) {
        const auto& ifaceDesc = config->interface[i].altsetting[0].interfaceDescriptor;
        if (ifaceDesc.bInterfaceClass == 0x06 &&
            ifaceDesc.bInterfaceSubClass == 0x01 &&
            ifaceDesc.bInterfaceProtocol == 0x01) {
            ptpInterface = i;
            for (uint8_t j = 0; j < ifaceDesc.bNumEndpoints; j++) {
                const auto& epDesc = config->interface[i].altsetting[0].endPoint[j].endpointDescriptor;
                uint8_t addr = epDesc.bEndpointAddress;
                if ((epDesc.bmAttributes & 0x03) == 0x02) {
                    if (addr & 0x80) {
                        g_bulkInEp = addr;
                        g_maxPacketSize = epDesc.wMaxPacketSize;
                    } else {
                        g_bulkOutEp = addr;
                    }
                }
            }
            break;
        }
    }

    OH_Usb_FreeConfigDescriptor(config);

    if (ptpInterface == 0xFF || g_bulkInEp == 0 || g_bulkOutEp == 0) {
        OH_LOG_ERROR(LOG_APP, "PTP interface not found");
        return false;
    }
    OH_LOG_INFO(LOG_APP, "IF=%{public}d IN=0x%{public}x OUT=0x%{public}x",
                ptpInterface, g_bulkInEp, g_bulkOutEp);

    ret = OH_Usb_ClaimInterface(deviceId, ptpInterface, &g_interfaceHandle);
    OH_LOG_INFO(LOG_APP, "ClaimInterface: %{public}d", ret);
    if (ret != USB_DDK_SUCCESS) return false;

    ret = OH_Usb_CreateDeviceMemMap(deviceId, g_mmapSize, &g_devMmap);
    OH_LOG_INFO(LOG_APP, "CreateDeviceMemMap(%{public}zu): %{public}d", g_mmapSize, ret);
    if (ret != USB_DDK_SUCCESS) {
        g_devMmap = nullptr;
    }

    return true;
}

void ptp_ddk_release_device() {
    if (g_devMmap) {
        OH_Usb_DestroyDeviceMemMap(g_devMmap);
        g_devMmap = nullptr;
    }
    if (g_interfaceHandle) {
        OH_Usb_ReleaseInterface(g_interfaceHandle);
        g_interfaceHandle = 0;
    }
    g_bulkInEp = 0;
    g_bulkOutEp = 0;
    if (g_initialized) {
        OH_Usb_Release();
        g_initialized = false;
    }
}

bool ptp_ddk_send_command(const std::vector<uint8_t>& cmd) {
    if (!g_interfaceHandle || g_bulkOutEp == 0) return false;

    UsbRequestPipe pipe;
    pipe.interfaceHandle = g_interfaceHandle;
    pipe.endpoint = g_bulkOutEp;
    pipe.timeout = 5000;

    UsbDeviceMemMap* cmdMmap = nullptr;
    int ret = OH_Usb_CreateDeviceMemMap(g_deviceId, cmd.size(), &cmdMmap);
    if (ret != USB_DDK_SUCCESS || !cmdMmap) return false;

    std::memcpy(cmdMmap->address, cmd.data(), cmd.size());

    ret = OH_Usb_SendPipeRequest(&pipe, cmdMmap);
    OH_Usb_DestroyDeviceMemMap(cmdMmap);

    return ret == USB_DDK_SUCCESS;
}

std::vector<uint8_t> ptp_ddk_read_data(int timeoutMs, bool expectData) {
    std::vector<uint8_t> result;
    if (!g_interfaceHandle || g_bulkInEp == 0) return result;

    if (!g_devMmap) {
        int ret = OH_Usb_CreateDeviceMemMap(g_deviceId, g_mmapSize, &g_devMmap);
        if (ret != USB_DDK_SUCCESS) return result;
    }

    UsbRequestPipe pipe;
    pipe.interfaceHandle = g_interfaceHandle;
    pipe.endpoint = g_bulkInEp;
    pipe.timeout = static_cast<uint32_t>(timeoutMs);

    int ret = OH_Usb_SendPipeRequest(&pipe, g_devMmap);
    if (ret == USB_DDK_SUCCESS) {
        uint32_t actualLen = g_devMmap->transferedLength;
        if (actualLen > 0 && actualLen <= g_mmapSize) {
            result.assign(g_devMmap->address, g_devMmap->address + actualLen);
        }
    } else {
        OH_LOG_WARN(LOG_APP, "SendPipeRequest IN failed: %{public}d", ret);
    }

    return result;
}
