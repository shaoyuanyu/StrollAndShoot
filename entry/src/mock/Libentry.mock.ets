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
  'processResponse': (_data: Uint8Array, _expect: boolean) => ({
    action: 2, responseCode: 0x2001
  }),
  'parseDeviceInfo': (_data: Uint8Array) => ({
    manufacturer: 'MockCam', model: 'Mock PTP', deviceVersion: '1.0',
    serialNumber: 'MOCK', vendorExtensionID: 0, standardVersion: 100,
    vendorExtensionVersion: 0, vendorExtensionDesc: '', functionalMode: 0
  }),
  'parseStorageIDs': (_data: Uint8Array) => [0x00010001],
  'parseObjectHandles': (_data: Uint8Array) => [1,2,3,4,5],
  'parseObjectInfo': (_data: Uint8Array, _h: number) => ({
    filename: 'IMG_0001.JPG', objectCompressedSize: 1048576,
    objectFormat: 0x3800, storageId: 1, imagePixWidth: 6000, imagePixHeight: 4000,
    captureDate: '20250101T000000'
  }),
};
export default NativeMock;
