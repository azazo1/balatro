import type { Mode } from './types';

interface Autosave { format_version: 1; file: string; updated_at: number }
let database: Promise<IDBDatabase> | null = null;
function open() {
  database ??= new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open('balatro-engine-lab', 1);
    request.onupgradeneeded = () => { request.result.createObjectStore('sessions'); };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => { database = null; reject(request.error); };
  });
  return database;
}
/** 旧构建存档在当前引擎重放丢了节点时, 原文件另存在这个键下, 防止被自动存档覆盖. */
export const backupKey = (mode: Mode) => `${mode}:before-rebuild`;
export async function readAutosave(key: string): Promise<Autosave | undefined> {
  const db = await open();
  return new Promise((resolve, reject) => {
    const request = db.transaction('sessions', 'readonly').objectStore('sessions').get(key);
    request.onsuccess = () => {
      const value = request.result as Autosave | undefined;
      if (value && value.format_version !== 1) reject(new Error('不支持的自动存档格式'));
      else resolve(value);
    };
    request.onerror = () => reject(request.error);
  });
}
export async function writeAutosave(key: string, file: string) {
  const db = await open();
  return new Promise<void>((resolve, reject) => {
    const transaction = db.transaction('sessions', 'readwrite');
    transaction.objectStore('sessions').put({ format_version: 1, file, updated_at: Date.now() } satisfies Autosave, key);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error ?? new Error('自动存档事务中止'));
  });
}
export function download(name: string, text: string, type = 'application/json') {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const link = document.createElement('a');
  link.href = url; link.download = name; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
