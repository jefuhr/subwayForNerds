import protobuf from 'protobufjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = path.join(path.dirname(fileURLToPath(import.meta.url)), 'proto');
function schema(extension: string) {
  const root = new protobuf.Root();
  root.resolvePath = (_origin, target) => path.join(directory, path.basename(target));
  root.loadSync(path.join(directory, extension), { keepCase: true });
  root.resolveAll();
  return root.lookupType('transit_realtime.FeedMessage');
}
// Both extensions occupy field 1001. They must not share a protobuf registry.
const nyct = schema('gtfs-realtime-NYCT.proto');
const mercury = schema('gtfs-realtime-service-status.proto');
export function decode(bytes: Uint8Array, alerts = false): any {
  const type = alerts ? mercury : nyct;
  return type.toObject(type.decode(bytes), { longs: Number, enums: String, defaults: false });
}
export function extension(object: any, name: string): any {
  return object?.[`.transit_realtime.${name}`] ?? object?.[`[transit_realtime.${name}]`] ?? {};
}
