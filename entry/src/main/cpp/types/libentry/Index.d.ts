export interface ProcessResult {
  action: number;       // 0=read more, 1=data ready, 2=response ready
  responseCode?: number; // valid when action==2
  data?: Uint8Array;     // valid when action==1
}

export interface PtpDeviceInfo {
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

export interface PtpObjectInfo {
  storageId: number;
  objectFormat: number;
  objectCompressedSize: number;
  imagePixWidth: number;
  imagePixHeight: number;
  filename: string;
  captureDate: string;
  modificationDate: string;
}

export const buildOpenSession: (sessionId: number) => Uint8Array;
export const buildCloseSession: () => Uint8Array;
export const buildGetDeviceInfo: () => Uint8Array;
export const buildGetStorageIDs: () => Uint8Array;
export const buildGetObjectHandles: (storageId: number, formatCode?: number, parentHandle?: number) => Uint8Array;
export const buildGetObjectInfo: (objectHandle: number) => Uint8Array;
export const buildGetThumb: (objectHandle: number) => Uint8Array;
export const buildGetObject: (objectHandle: number) => Uint8Array;
export const buildGetPartialObject: (objectHandle: number, offset: number, maxBytes: number) => Uint8Array;
export const processResponse: (data: Uint8Array, expectData: boolean) => ProcessResult;
export const parseDeviceInfo: (data: Uint8Array) => PtpDeviceInfo;
export const parseStorageIDs: (data: Uint8Array) => number[];
export const parseObjectHandles: (data: Uint8Array) => number[];
export const parseObjectInfo: (data: Uint8Array, handle: number) => PtpObjectInfo;
