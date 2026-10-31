// minimaler d-bus-client: genau so viel wire-protokoll, wie der secret service
// braucht (marshalling, EXTERNAL-auth, method calls, signale).
//
// vendored aus attek-orga/lib/dbus.js. bis auf import/export unveraendert, damit
// sich beide seiten weiter gegeneinander diffen lassen. bewusst ohne npm-paket
// und ohne natives modul: reines js, damit tools/ dependency-frei kopierbar
// bleibt und kein prebuild pro plattform noetig ist.
//
// wire-format kurz: little endian, jeder typ auf seine groesse ausgerichtet,
// arrays mit vorangestellter byte-laenge, structs und dict-entries auf 8.

import net from "node:net";
import os from "node:os";

const MESSAGE_TYPE = { METHOD_CALL: 1, METHOD_RETURN: 2, ERROR: 3, SIGNAL: 4 };
const FIELD = {
  PATH: 1,
  INTERFACE: 2,
  MEMBER: 3,
  ERROR_NAME: 4,
  REPLY_SERIAL: 5,
  DESTINATION: 6,
  SENDER: 7,
  SIGNATURE: 8,
};
const CALL_TIMEOUT_MS = 15000;

// --- signaturen ---

// "a{sv}(oayays)b" -> [{ code: "a", ... }, { code: "r", fields: [...] }, { code: "b" }]
function parseSignature(signature) {
  let pos = 0;

  function one() {
    const code = signature[pos++];
    if (code === "a") {
      if (signature[pos] === "{") {
        pos++; // {
        const key = one();
        const value = one();
        pos++; // }
        return { code: "a", entry: { code: "e", key, value } };
      }
      return { code: "a", element: one() };
    }
    if (code === "(") {
      const fields = [];
      while (signature[pos] !== ")") fields.push(one());
      pos++; // )
      return { code: "r", fields };
    }
    return { code };
  }

  const types = [];
  while (pos < signature.length) types.push(one());
  return types;
}

function alignmentOf(type) {
  switch (type.code) {
    case "y":
    case "g":
    case "v":
      return 1;
    case "n":
    case "q":
      return 2;
    case "x":
    case "t":
    case "d":
    case "r":
    case "e":
      return 8;
    default:
      return 4; // b i u s o a
  }
}

function alignUp(offset, boundary) {
  return offset + ((boundary - (offset % boundary)) % boundary);
}

// --- schreiben ---

class Writer {
  constructor(base = 0) {
    this.base = base;
    this.chunks = [];
    this.length = 0;
  }

  get offset() {
    return this.base + this.length;
  }

  raw(buffer) {
    this.chunks.push(buffer);
    this.length += buffer.length;
  }

  align(boundary) {
    const pad = alignUp(this.offset, boundary) - this.offset;
    if (pad) this.raw(Buffer.alloc(pad));
  }

  byte(value) {
    this.raw(Buffer.from([value & 0xff]));
  }

  uint32(value) {
    this.align(4);
    const buffer = Buffer.alloc(4);
    buffer.writeUInt32LE(value >>> 0);
    this.raw(buffer);
  }

  text(value) {
    const bytes = Buffer.from(String(value), "utf8");
    this.uint32(bytes.length);
    this.raw(bytes);
    this.byte(0);
  }

  sig(value) {
    const bytes = Buffer.from(String(value), "ascii");
    this.byte(bytes.length);
    this.raw(bytes);
    this.byte(0);
  }

  toBuffer() {
    return Buffer.concat(this.chunks, this.length);
  }
}

function writeValue(writer, type, value) {
  switch (type.code) {
    case "y":
      return writer.byte(value);
    case "b":
      return writer.uint32(value ? 1 : 0);
    case "u":
      return writer.uint32(value);
    case "s":
    case "o":
      return writer.text(value);
    case "g":
      return writer.sig(value);
    case "v": {
      // variant: { signature, value }
      writer.sig(value.signature);
      const [inner] = parseSignature(value.signature);
      return writeValue(writer, inner, value.value);
    }
    case "r": {
      writer.align(8);
      type.fields.forEach((field, i) => writeValue(writer, field, value[i]));
      return undefined;
    }
    case "e": {
      writer.align(8);
      writeValue(writer, type.key, value[0]);
      return writeValue(writer, type.value, value[1]);
    }
    case "a": {
      const element = type.element || type.entry;
      // byte-arrays kommen als Buffer, alles andere als js-array
      const items = Buffer.isBuffer(value) ? [...value] : value;
      writer.align(4);
      const dataStart = alignUp(writer.offset + 4, alignmentOf(element));
      const sub = new Writer(dataStart);
      for (const item of items) writeValue(sub, element, item);
      const data = sub.toBuffer();
      writer.uint32(data.length);
      writer.align(alignmentOf(element)); // padding zaehlt nicht zur laenge
      return writer.raw(data);
    }
    default:
      throw new Error(`d-bus: typ "${type.code}" wird nicht unterstuetzt`);
  }
}

// --- lesen ---

class Reader {
  constructor(buffer, offset = 0) {
    this.buffer = buffer;
    this.offset = offset;
  }

  align(boundary) {
    this.offset = alignUp(this.offset, boundary);
  }

  byte() {
    return this.buffer[this.offset++];
  }

  uint32() {
    this.align(4);
    const value = this.buffer.readUInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  text() {
    const length = this.uint32();
    const value = this.buffer.toString("utf8", this.offset, this.offset + length);
    this.offset += length + 1; // NUL
    return value;
  }

  sig() {
    const length = this.byte();
    const value = this.buffer.toString("ascii", this.offset, this.offset + length);
    this.offset += length + 1; // NUL
    return value;
  }
}

function readValue(reader, type) {
  switch (type.code) {
    case "y":
      return reader.byte();
    case "b":
      return reader.uint32() === 1;
    case "u":
      return reader.uint32();
    case "s":
    case "o":
      return reader.text();
    case "g":
      return reader.sig();
    case "v": {
      const signature = reader.sig();
      const [inner] = parseSignature(signature);
      return { signature, value: readValue(reader, inner) };
    }
    case "r": {
      reader.align(8);
      return type.fields.map((field) => readValue(reader, field));
    }
    case "e": {
      reader.align(8);
      const key = readValue(reader, type.key);
      return [key, readValue(reader, type.value)];
    }
    case "a": {
      const element = type.element || type.entry;
      const byteLength = reader.uint32();
      reader.align(alignmentOf(element));
      const end = reader.offset + byteLength;
      // ay wird als Buffer zurueckgegeben, das ist die form die geheimnisse haben
      if (element.code === "y") {
        const bytes = reader.buffer.subarray(reader.offset, end);
        reader.offset = end;
        return Buffer.from(bytes);
      }
      const items = [];
      while (reader.offset < end) items.push(readValue(reader, element));
      return items;
    }
    default:
      throw new Error(`d-bus: typ "${type.code}" wird nicht unterstuetzt`);
  }
}

function readBody(buffer, offset, signature) {
  if (!signature) return [];
  const reader = new Reader(buffer, offset);
  return parseSignature(signature).map((type) => readValue(reader, type));
}

// --- nachrichten ---

function encodeMessage({ type, serial, path, iface, member, destination, signature, body }) {
  const bodyWriter = new Writer(0);
  if (signature) {
    const types = parseSignature(signature);
    types.forEach((t, i) => writeValue(bodyWriter, t, body[i]));
  }
  const bodyBuffer = bodyWriter.toBuffer();

  const fields = [];
  if (path) fields.push([FIELD.PATH, { signature: "o", value: path }]);
  if (iface) fields.push([FIELD.INTERFACE, { signature: "s", value: iface }]);
  if (member) fields.push([FIELD.MEMBER, { signature: "s", value: member }]);
  if (destination) fields.push([FIELD.DESTINATION, { signature: "s", value: destination }]);
  if (signature) fields.push([FIELD.SIGNATURE, { signature: "g", value: signature }]);

  const header = new Writer(0);
  header.byte(0x6c); // little endian
  header.byte(type);
  header.byte(0); // flags
  header.byte(1); // protocol version
  header.uint32(bodyBuffer.length);
  header.uint32(serial);
  const [fieldsType] = parseSignature("a(yv)");
  writeValue(header, fieldsType, fields);
  header.align(8); // body beginnt immer auf 8

  return Buffer.concat([header.toBuffer(), bodyBuffer]);
}

// laenge der naechsten vollstaendigen nachricht im puffer, sonst 0
function messageLength(buffer) {
  if (buffer.length < 16) return 0;
  const bodyLength = buffer.readUInt32LE(4);
  const fieldsLength = buffer.readUInt32LE(12);
  const total = alignUp(16 + fieldsLength, 8) + bodyLength;
  return buffer.length >= total ? total : 0;
}

function decodeMessage(buffer) {
  const type = buffer[1];
  const bodyLength = buffer.readUInt32LE(4);
  const serial = buffer.readUInt32LE(8);
  const reader = new Reader(buffer, 12);
  const [fieldsType] = parseSignature("a(yv)");
  const fields = readValue(reader, fieldsType);

  const header = {};
  for (const [code, variant] of fields) header[code] = variant.value;

  const bodyStart = alignUp(reader.offset, 8);
  const signature = header[FIELD.SIGNATURE] || "";
  return {
    type,
    serial,
    replySerial: header[FIELD.REPLY_SERIAL],
    errorName: header[FIELD.ERROR_NAME],
    member: header[FIELD.MEMBER],
    path: header[FIELD.PATH],
    signature,
    body: bodyLength ? readBody(buffer, bodyStart, signature) : [],
  };
}

// --- verbindung ---

class Connection {
  constructor(socket) {
    this.socket = socket;
    this.serial = 1;
    this.pending = new Map();
    this.signalHandlers = new Set();
    this.buffer = Buffer.alloc(0);
    this.closed = false;

    socket.on("data", (chunk) => this.onData(chunk));
    socket.on("error", (err) => this.failAll(err));
    socket.on("close", () => this.failAll(new Error("d-bus: Verbindung geschlossen")));
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const length = messageLength(this.buffer);
      if (!length) return;
      const raw = this.buffer.subarray(0, length);
      this.buffer = this.buffer.subarray(length);
      let message;
      try {
        message = decodeMessage(raw);
      } catch (e) {
        this.failAll(e);
        return;
      }
      this.dispatch(message);
    }
  }

  dispatch(message) {
    if (message.type === MESSAGE_TYPE.SIGNAL) {
      for (const handler of this.signalHandlers) handler(message);
      return;
    }
    const waiter = this.pending.get(message.replySerial);
    if (!waiter) return;
    this.pending.delete(message.replySerial);
    clearTimeout(waiter.timer);
    if (message.type === MESSAGE_TYPE.ERROR) {
      const detail = message.body && message.body[0] ? `: ${message.body[0]}` : "";
      waiter.reject(new Error(`${message.errorName}${detail}`));
    } else {
      waiter.resolve(message.body);
    }
  }

  failAll(error) {
    this.closed = true;
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.pending.clear();
  }

  call({ destination, path, iface, member, signature = "", body = [] }) {
    if (this.closed) return Promise.reject(new Error("d-bus: Verbindung ist zu"));
    const serial = this.serial++;
    const message = encodeMessage({
      type: MESSAGE_TYPE.METHOD_CALL,
      serial,
      destination,
      path,
      iface,
      member,
      signature,
      body,
    });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(serial);
        reject(new Error(`d-bus: keine Antwort auf ${member}`));
      }, CALL_TIMEOUT_MS);
      this.pending.set(serial, { resolve, reject, timer });
      this.socket.write(message);
    });
  }

  onSignal(handler) {
    this.signalHandlers.add(handler);
    return () => this.signalHandlers.delete(handler);
  }

  close() {
    this.closed = true;
    this.socket.destroy();
  }
}

function socketPath() {
  const address = process.env.DBUS_SESSION_BUS_ADDRESS;
  if (address) {
    const match = address.match(/unix:(?:.*,)?path=([^,]+)/);
    if (match) return match[1];
    const abstract = address.match(/unix:(?:.*,)?abstract=([^,]+)/);
    if (abstract) return `\0${abstract[1]}`;
  }
  const runtime = process.env.XDG_RUNTIME_DIR;
  if (runtime) return `${runtime}/bus`;
  return null;
}

// EXTERNAL-auth: nullbyte, uid als hex, dann BEGIN
function authenticate(socket) {
  return new Promise((resolve, reject) => {
    let received = "";
    const onData = (chunk) => {
      received += chunk.toString("ascii");
      if (!received.includes("\r\n")) return;
      const line = received.slice(0, received.indexOf("\r\n"));
      socket.off("data", onData);
      if (!line.startsWith("OK")) {
        reject(new Error(`d-bus: Anmeldung am Bus abgelehnt (${line})`));
        return;
      }
      socket.write("BEGIN\r\n");
      resolve();
    };
    socket.on("data", onData);
    const uid = Buffer.from(String(os.userInfo().uid), "ascii").toString("hex");
    socket.write(`\0AUTH EXTERNAL ${uid}\r\n`);
  });
}

async function connect() {
  const path = socketPath();
  if (!path) throw new Error("d-bus: kein Session-Bus gefunden (DBUS_SESSION_BUS_ADDRESS fehlt)");

  const socket = await new Promise((resolve, reject) => {
    const s = net.createConnection({ path });
    s.once("connect", () => resolve(s));
    s.once("error", reject);
  });

  await authenticate(socket);
  const connection = new Connection(socket);
  await connection.call({
    destination: "org.freedesktop.DBus",
    path: "/org/freedesktop/DBus",
    iface: "org.freedesktop.DBus",
    member: "Hello",
  });
  return connection;
}

export { connect };
