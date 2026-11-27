import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { devToolsLogLevelCode, formatDevToolsLogTime } from './DevToolsLogFilter';
import { DevToolsLogEntry } from './DevToolsLogSource';

export type DevToolsLogSaveResult = 'saved' | 'canceled' | 'failed';

function formatEntry(entry: DevToolsLogEntry): string {
  return `${formatDevToolsLogTime(entry.time)}\t${entry.pid}\t${entry.bundleName}\t${entry.processName}\t` +
    `${devToolsLogLevelCode(entry.level)}/${entry.tag}\t${entry.message}\n`;
}

export async function saveDevToolsLogFile(context: common.Context, entries: DevToolsLogEntry[]): Promise<DevToolsLogSaveResult> {
  try {
    const options: picker.DocumentSaveOptions = { newFileNames: [`devtools-${Date.now()}.log`] };
    const uris = await new picker.DocumentViewPicker(context).save(options);
    if (!uris.length) {
      return 'canceled';
    }
    const file = await fileIo.open(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      const encoder = util.TextEncoder.create('utf-8');
      const batchSize = 64;
      for (let index = 0; index < entries.length; index += batchSize) {
        const batch = entries.slice(index, index + batchSize).map(formatEntry).join('');
        const bytes = encoder.encodeInto(batch);
        let written = 0;
        while (written < bytes.byteLength) {
          const buffer = bytes.buffer.slice(bytes.byteOffset + written, bytes.byteOffset + bytes.byteLength);
          const count = await fileIo.write(file.fd, buffer);
          if (count <= 0) {
            return 'failed';
          }
          written += count;
        }
      }
      await fileIo.fsync(file.fd);
    } finally {
      await fileIo.close(file.fd);
    }
    return 'saved';
  } catch {
    return 'failed';
  }
}
