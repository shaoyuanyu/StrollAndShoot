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
  /** 相机自报支持的操作码（如 0x9805 = GetObjectPropList）。 */
  operationsSupported: number[];
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

export interface PtpObjectPropEntry {
  handle: number;
  format: number;
  size: number;
  parent: number;
  filename: string;
  dateCreated: string;
  dateModified: string;
}

export interface PtpObjectPropList {
  objects: PtpObjectPropEntry[];
  /** 实际出现的属性码（去重）。 */
  codes: number[];
  /** 数据段声明的元素个数。 */
  declared: number;
  /** 整个数据段解析完整且数量对得上。 */
  complete: boolean;
  /** 数据段字节数。 */
  bytes: number;
  /** 数据段开头 32 字节的 hex，解析失败时用来判断相机回了什么。 */
  head: string;
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
export const buildGetObjectPropList: (objectHandle: number, formatCode: number, propertyCode: number, groupCode: number, depth: number) => Uint8Array;
export const processResponse: (data: Uint8Array, expectData: boolean) => ProcessResult;
export const parseDeviceInfo: (data: Uint8Array) => PtpDeviceInfo;
export const parseStorageIDs: (data: Uint8Array) => number[];
export const parseObjectHandles: (data: Uint8Array) => number[];
export const parseObjectInfo: (data: Uint8Array, handle: number) => PtpObjectInfo;
export const parseObjectPropList: (data: Uint8Array) => PtpObjectPropList;
