// Local Test 用的 NAPI 桩实现，由 src/mock/mock-config.json5 注册。
//
// ArkTS 不允许无类型对象字面量（arkts-no-untyped-obj-literals），
// 所以返回结构必须先用 interface 声明再赋值，不能直接写成 `=> ({ ... })`。

interface MockProcessResult {
  action: number;
  responseCode?: number;
}

interface MockDeviceInfo {
  standardVersion: number;
  vendorExtensionID: number;
  vendorExtensionVersion: number;
  vendorExtensionDesc: string;
  functionalMode: number;
  manufacturer: string;
  model: string;
  deviceVersion: string;
  serialNumber: string;
}

interface MockObjectInfo {
  storageId: number;
  objectFormat: number;
  objectCompressedSize: number;
  imagePixWidth: number;
  imagePixHeight: number;
  filename: string;
  captureDate: string;
  modificationDate: string;
}

const NativeMock: Record<string, Object> = {
  'buildOpenSession': (_id: number): Uint8Array =>
    new Uint8Array([16,0,0,0, 1,0, 2,0x10, 1,0,0,0, 1,0,0,0]),
  'buildCloseSession': (): Uint8Array =>
    new Uint8Array([12,0,0,0, 1,0, 3,0x10, 0,0,0,0]),
  'buildGetDeviceInfo': (): Uint8Array =>
    new Uint8Array([12,0,0,0, 1,0, 1,0x10, 0,0,0,0]),
  'buildGetStorageIDs': (): Uint8Array =>
    new Uint8Array([12,0,0,0, 1,0, 4,0x10, 0,0,0,0]),
  'buildGetObjectHandles': (_sid: number): Uint8Array =>
    new Uint8Array([24,0,0,0, 1,0, 7,0x10, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0]),
  'buildGetObjectInfo': (_h: number): Uint8Array =>
    new Uint8Array([16,0,0,0, 1,0, 8,0x10, 0,0,0,0, 0,0,0,0]),
  'buildGetThumb': (_h: number): Uint8Array =>
    new Uint8Array([16,0,0,0, 1,0, 0x0A,0x10, 0,0,0,0, 0,0,0,0]),
  'buildGetObject': (_h: number): Uint8Array =>
    new Uint8Array([16,0,0,0, 1,0, 9,0x10, 0,0,0,0, 0,0,0,0]),
  'processResponse': (_data: Uint8Array, _expect: boolean): MockProcessResult => {
    const ok: MockProcessResult = { action: 2, responseCode: 0x2001 };
    return ok;
  },
  'parseDeviceInfo': (_data: Uint8Array): MockDeviceInfo => {
    const info: MockDeviceInfo = {
      manufacturer: 'MockCam', model: 'Mock PTP', deviceVersion: '1.0',
      serialNumber: 'MOCK', vendorExtensionID: 0, standardVersion: 100,
      vendorExtensionVersion: 0, vendorExtensionDesc: '', functionalMode: 0
    };
    return info;
  },
  'parseStorageIDs': (_data: Uint8Array): number[] => [0x00010001],
  'parseObjectHandles': (_data: Uint8Array): number[] => [1,2,3,4,5],
  'parseObjectInfo': (_data: Uint8Array, _h: number): MockObjectInfo => {
    const obj: MockObjectInfo = {
      filename: 'IMG_0001.JPG', objectCompressedSize: 1048576,
      objectFormat: 0x3801, storageId: 1, imagePixWidth: 6000, imagePixHeight: 4000,
      captureDate: '20250101T000000', modificationDate: '20250101T000000'
    };
    return obj;
  },
};
export default NativeMock;
