// 黄豆短剧 · 模块运行时入口（由 gzip + crypto + main-core 合并生成，勿直接编辑）
(function () {

// ===== gzip.js =====

// DEFLATE 解压（RFC 1951）+ gzip 封装（RFC 1952）——纯 JS，无依赖。
// 模块运行时没有 zlib，黄豆接口的请求/响应都是 gzip，必须自带。

const LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

function huffman(lengths) {
  const counts = new Uint16Array(16);
  for (let i = 0; i < lengths.length; i++) counts[lengths[i]]++;
  counts[0] = 0;
  const offsets = new Uint16Array(16);
  for (let i = 1; i < 16; i++) offsets[i] = offsets[i - 1] + counts[i - 1];
  const symbols = new Uint16Array(lengths.length);
  for (let i = 0; i < lengths.length; i++) {
    if (lengths[i] !== 0) symbols[offsets[lengths[i]]++] = i;
  }
  return { counts, symbols };
}

function inflateRaw(data, start) {
  let pos = start || 0;
  let bitBuf = 0;
  let bitCnt = 0;
  const out = [];
  let outLen = 0;

  function bits(n) {
    while (bitCnt < n) {
      if (pos >= data.length) throw new Error('deflate 数据不完整');
      bitBuf |= data[pos++] << bitCnt;
      bitCnt += 8;
    }
    const value = bitBuf & ((1 << n) - 1);
    bitBuf >>>= n;
    bitCnt -= n;
    return value;
  }

  function decode(table) {
    let code = 0;
    let first = 0;
    let index = 0;
    for (let len = 1; len < 16; len++) {
      code |= bits(1);
      const count = table.counts[len];
      if (code - first < count) return table.symbols[index + (code - first)];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw new Error('deflate 哈夫曼码无效');
  }

  let fixedLit = null;
  let fixedDist = null;
  function fixedTables() {
    if (fixedLit !== null) return;
    const lit = new Uint8Array(288);
    for (let i = 0; i < 144; i++) lit[i] = 8;
    for (let i = 144; i < 256; i++) lit[i] = 9;
    for (let i = 256; i < 280; i++) lit[i] = 7;
    for (let i = 280; i < 288; i++) lit[i] = 8;
    fixedLit = huffman(lit);
    const dist = new Uint8Array(30);
    for (let i = 0; i < 30; i++) dist[i] = 5;
    fixedDist = huffman(dist);
  }

  function push(byte) {
    out.push(byte);
    outLen++;
  }

  let final = 0;
  while (final === 0) {
    final = bits(1);
    const type = bits(2);
    if (type === 0) {
      bitBuf = 0;
      bitCnt = 0;
      if (pos + 4 > data.length) throw new Error('deflate stored 块头不完整');
      const len = data[pos] | (data[pos + 1] << 8);
      const nlen = data[pos + 2] | (data[pos + 3] << 8);
      pos += 4;
      if ((len ^ 0xffff) !== nlen) throw new Error('deflate stored 块长度校验失败');
      if (pos + len > data.length) throw new Error('deflate stored 块数据不完整');
      for (let i = 0; i < len; i++) push(data[pos + i]);
      pos += len;
      continue;
    }
    let litTable;
    let distTable;
    if (type === 1) {
      fixedTables();
      litTable = fixedLit;
      distTable = fixedDist;
    } else if (type === 2) {
      const hlit = bits(5) + 257;
      const hdist = bits(5) + 1;
      const hclen = bits(4) + 4;
      const clens = new Uint8Array(19);
      for (let i = 0; i < hclen; i++) clens[CLEN_ORDER[i]] = bits(3);
      const clTable = huffman(clens);
      const lengths = new Uint8Array(hlit + hdist);
      let index = 0;
      while (index < hlit + hdist) {
        const sym = decode(clTable);
        if (sym < 16) {
          lengths[index++] = sym;
        } else if (sym === 16) {
          if (index === 0) throw new Error('deflate 重复长度缺少前值');
          const prev = lengths[index - 1];
          let repeat = 3 + bits(2);
          while (repeat-- > 0 && index < lengths.length) lengths[index++] = prev;
        } else if (sym === 17) {
          let repeat = 3 + bits(3);
          while (repeat-- > 0 && index < lengths.length) lengths[index++] = 0;
        } else {
          let repeat = 11 + bits(7);
          while (repeat-- > 0 && index < lengths.length) lengths[index++] = 0;
        }
      }
      litTable = huffman(lengths.subarray(0, hlit));
      distTable = huffman(lengths.subarray(hlit));
    } else {
      throw new Error('deflate 块类型无效');
    }
    for (;;) {
      const sym = decode(litTable);
      if (sym < 256) {
        push(sym);
      } else if (sym === 256) {
        break;
      } else {
        const lenIdx = sym - 257;
        if (lenIdx >= LEN_BASE.length) throw new Error('deflate 长度码无效');
        const length = LEN_BASE[lenIdx] + bits(LEN_EXTRA[lenIdx]);
        const distSym = decode(distTable);
        if (distSym >= DIST_BASE.length) throw new Error('deflate 距离码无效');
        const distance = DIST_BASE[distSym] + bits(DIST_EXTRA[distSym]);
        if (distance > outLen) throw new Error('deflate 回溯距离越界');
        for (let i = 0; i < length; i++) push(out[outLen - distance]);
      }
    }
  }
  return (function (src) { var out = new Uint8Array(src.length); for (var i = 0; i < src.length; i++) out[i] = src[i] & 0xff; return out; })(out);
}

function gzipInflate(data) {
  if (data.length < 18 || data[0] !== 0x1f || data[1] !== 0x8b) {
    throw new Error('gzip 头无效');
  }
  if (data[2] !== 8) throw new Error('gzip 压缩方法无效');
  const flags = data[3];
  let pos = 10;
  if (flags & 4) {
    if (pos + 2 > data.length) throw new Error('gzip 头不完整');
    pos += 2 + (data[pos] | (data[pos + 1] << 8));
  }
  if (flags & 8) {
    while (pos < data.length && data[pos] !== 0) pos++;
    pos++;
  }
  if (flags & 16) {
    while (pos < data.length && data[pos] !== 0) pos++;
    pos++;
  }
  if (flags & 2) pos += 2;
  if (pos > data.length) throw new Error('gzip 头越界');
  return inflateRaw(data, pos);
}

// ---- gzip 压缩（只用 stored 块：不压缩但格式合法，服务端已验证接受）----
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[i] = c >>> 0;
  }
  return table;
})();

function crc32(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function gzipStored(bytes) {
  const chunks = [];
  chunks.push(0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff);
  let index = 0;
  do {
    const size = Math.min(65535, bytes.length - index);
    const final = index + size >= bytes.length ? 1 : 0;
    chunks.push(final, size & 0xff, (size >>> 8) & 0xff,
      (~size) & 0xff, ((~size) >>> 8) & 0xff);
    for (let i = 0; i < size; i++) chunks.push(bytes[index + i]);
    index += size;
  } while (index < bytes.length);
  const crc = crc32(bytes);
  const size = bytes.length >>> 0;
  chunks.push(crc & 0xff, (crc >>> 8) & 0xff, (crc >>> 16) & 0xff, (crc >>> 24) & 0xff,
    size & 0xff, (size >>> 8) & 0xff, (size >>> 16) & 0xff, (size >>> 24) & 0xff);
  return (function (src) { var out = new Uint8Array(src.length); for (var i = 0; i < src.length; i++) out[i] = src[i] & 0xff; return out; })(chunks);
}

var ZLIB = { gzipInflate: gzipInflate, gzipStored: gzipStored };


// ===== crypto.js =====

// MD5 / SHA-256 / HMAC-SHA256 纯 JS 实现。
// 模块运行时虽有 host.md5 / host.sha256，但 HMAC 未必暴露，
// 这里全部自带，行为与 Go/标准实现一致（已对着 Node crypto 校验）。

function cryptToBytes(value) {
  if (value instanceof Uint8Array) return value;
  if (Array.isArray(value)) return (function (src) { var out = new Uint8Array(src.length); for (var i = 0; i < src.length; i++) out[i] = src[i] & 0xff; return out; })(value);
  if (value && typeof value.length === 'number') {
    const out = new Uint8Array(value.length);
    for (let i = 0; i < value.length; i++) out[i] = value[i] & 0xff;
    return out;
  }
  throw new Error('需要字节数组');
}

// ---------------- MD5 ----------------
const MD5_S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
const MD5_K = (() => {
  const table = new Int32Array(64);
  for (let i = 0; i < 64; i++) table[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) | 0;
  return table;
})();

function md5(input) {
  const data = cryptToBytes(input);
  const bitLen = data.length * 8;
  const padded = new Uint8Array(((data.length + 8) >>> 6) * 64 + 64);
  padded.set(data);
  padded[data.length] = 0x80;
  const tail = padded.length - 8;
  padded[tail] = bitLen & 0xff;
  padded[tail + 1] = (bitLen >>> 8) & 0xff;
  padded[tail + 2] = (bitLen >>> 16) & 0xff;
  padded[tail + 3] = (bitLen >>> 24) & 0xff;
  // 64 位长度在这里不会超过 2^32，高位保持 0

  let a0 = 0x67452301;
  let b0 = 0xefcdab89 | 0;
  let c0 = 0x98badcfe | 0;
  let d0 = 0x10325476;

  const m = new Int32Array(16);
  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let i = 0; i < 16; i++) {
      const p = offset + i * 4;
      m[i] = padded[p] | (padded[p + 1] << 8) | (padded[p + 2] << 16) | (padded[p + 3] << 24);
    }
    let a = a0;
    let b = b0;
    let c = c0;
    let d = d0;
    for (let i = 0; i < 64; i++) {
      let f;
      let g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) & 15;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) & 15;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) & 15;
      }
      const sum = (a + f + MD5_K[i] + m[g]) | 0;
      const rotated = (sum << MD5_S[(i >>> 4) * 4 + (i & 3)]) | (sum >>> (32 - MD5_S[(i >>> 4) * 4 + (i & 3)]));
      a = d;
      d = c;
      c = b;
      b = (b + rotated) | 0;
    }
    a0 = (a0 + a) | 0;
    b0 = (b0 + b) | 0;
    c0 = (c0 + c) | 0;
    d0 = (d0 + d) | 0;
  }

  const out = new Uint8Array(16);
  const words = [a0, b0, c0, d0];
  for (let i = 0; i < 4; i++) {
    const w = words[i];
    out[i * 4] = w & 0xff;
    out[i * 4 + 1] = (w >>> 8) & 0xff;
    out[i * 4 + 2] = (w >>> 16) & 0xff;
    out[i * 4 + 3] = (w >>> 24) & 0xff;
  }
  return out;
}

// ---------------- SHA-256 ----------------
const SHA256_K = new Int32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]);

function sha256(input) {
  const data = cryptToBytes(input);
  const bitLen = data.length * 8;
  const padded = new Uint8Array(((data.length + 8) >>> 6) * 64 + 64);
  padded.set(data);
  padded[data.length] = 0x80;
  const tail = padded.length - 8;
  const hi = Math.floor(bitLen / 4294967296);
  padded[tail] = (hi >>> 24) & 0xff;
  padded[tail + 1] = (hi >>> 16) & 0xff;
  padded[tail + 2] = (hi >>> 8) & 0xff;
  padded[tail + 3] = hi & 0xff;
  padded[tail + 4] = (bitLen >>> 24) & 0xff;
  padded[tail + 5] = (bitLen >>> 16) & 0xff;
  padded[tail + 6] = (bitLen >>> 8) & 0xff;
  padded[tail + 7] = bitLen & 0xff;

  const h = new Int32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const w = new Int32Array(64);

  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let i = 0; i < 16; i++) {
      const p = offset + i * 4;
      w[i] = (padded[p] << 24) | (padded[p + 1] << 16) | (padded[p + 2] << 8) | padded[p + 3];
    }
    for (let i = 16; i < 64; i++) {
      const a = w[i - 15];
      const b = w[i - 2];
      const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
      const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let a = h[0];
    let b = h[1];
    let c = h[2];
    let d = h[3];
    let e = h[4];
    let f = h[5];
    let g = h[6];
    let hh = h[7];
    for (let i = 0; i < 64; i++) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const temp1 = (hh + S1 + ch + SHA256_K[i] + w[i]) | 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) | 0;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) | 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) | 0;
    }
    h[0] = (h[0] + a) | 0;
    h[1] = (h[1] + b) | 0;
    h[2] = (h[2] + c) | 0;
    h[3] = (h[3] + d) | 0;
    h[4] = (h[4] + e) | 0;
    h[5] = (h[5] + f) | 0;
    h[6] = (h[6] + g) | 0;
    h[7] = (h[7] + hh) | 0;
  }

  const out = new Uint8Array(32);
  for (let i = 0; i < 8; i++) {
    const v = h[i];
    out[i * 4] = (v >>> 24) & 0xff;
    out[i * 4 + 1] = (v >>> 16) & 0xff;
    out[i * 4 + 2] = (v >>> 8) & 0xff;
    out[i * 4 + 3] = v & 0xff;
  }
  return out;
}

// ---------------- HMAC-SHA256 ----------------
function hmacSha256(key, message) {
  let k = cryptToBytes(key);
  const msg = cryptToBytes(message);
  if (k.length > 64) k = sha256(k);
  const block = new Uint8Array(64);
  block.set(k);
  const inner = new Uint8Array(64 + msg.length);
  const outer = new Uint8Array(64 + 32);
  for (let i = 0; i < 64; i++) {
    inner[i] = block[i] ^ 0x36;
    outer[i] = block[i] ^ 0x5c;
  }
  inner.set(msg, 64);
  outer.set(sha256(inner), 64);
  return sha256(outer);
}

var CRYPT = { md5: md5, sha256: sha256, hmacSha256: hmacSha256 };

// ===== main-core.js =====

// 黄豆短剧 · H5 站协议实现
//
// 站点把接口体加密后再 gzip，具体是：
//   明文 = gzip(JSON { token, deviceId, data })
//   key  = HMAC-SHA256(ASCII(headerKey) 32B, hexDecode(requestId 去横线) 16B) → AES-256
//   body = IV(16) + AES-128/256-CBC-PKCS7(明文)
//   响应同样 AES-CBC 解密 + gunzip
// 请求头 version/deviceType/time/sign/requestId/sessionId 由服务端校验，
// 其中 sign = md5("Dart|sessionId|requestId|ts|url去掉scheme") + "-" + ts。

var HEADER_KEY = '7961beb44246e3012ce228d6b5ced05a';
var API_VERSION = '2.0.0';
var PAGE_SIZE = 20;
var MAX_PAGE = 100;
var USER_AGENT = 'Mozilla/5.0 (Linux; Android 15; 23127PN0CC) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var RELEASE_HOST = 'vtqzwlyffd.cc';
var FALLBACK_HOSTS = [
  'lltxuzil.cc',
  'hooqkujp.cc',
  'pmihlvee.cc',
  'iwgsqufx.cc',
  'eyeonneb.cc',
];
var CHANNEL = '黄豆短剧';
var CACHE_BASE = 'hd.base';
var CACHE_DEVICE = 'hd.device';
var STATE_NAV = 'hd.nav';

// ---------------------------------------------------------------- 基础工具

function manifestOf() {
  try {
    var value = host.manifest();
    return value && typeof value === 'object' ? value : {};
  } catch (error) {
    return {};
  }
}

function toBytes(value) {
  if (value === null || value === undefined) return new Uint8Array(0);
  if (value instanceof Uint8Array) return value;
  if (typeof value === 'string') {
    var text = new Uint8Array(value.length);
    for (var i = 0; i < value.length; i++) text[i] = value.charCodeAt(i) & 0xff;
    return text;
  }
  if (typeof value.length === 'number') {
    var out = new Uint8Array(value.length);
    for (var j = 0; j < value.length; j++) out[j] = value[j] & 0xff;
    return out;
  }
  throw new Error('黄豆需要字节数据');
}

function concatBytes() {
  var total = 0;
  var index;
  for (index = 0; index < arguments.length; index++) total += arguments[index].length;
  var out = new Uint8Array(total);
  var offset = 0;
  for (index = 0; index < arguments.length; index++) {
    out.set(arguments[index], offset);
    offset += arguments[index].length;
  }
  return out;
}

function utf8Encode(text) {
  try {
    return toBytes(host.utf8Encode(text));
  } catch (error) {
    // 兜底：手写 UTF-8 编码
    var out = [];
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i);
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        var next = text.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          var full = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          out.push(0xf0 | (full >> 18), 0x80 | ((full >> 12) & 63),
            0x80 | ((full >> 6) & 63), 0x80 | (full & 63));
          i++;
        } else {
          out.push(0xef, 0xbf, 0xbd);
        }
      } else {
        out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      }
    }
    return (function (src) { var out = new Uint8Array(src.length); for (var i = 0; i < src.length; i++) out[i] = src[i] & 0xff; return out; })(out);
  }
}

function utf8Decode(bytes) {
  try {
    return host.utf8Decode(bytes);
  } catch (error) {
    var out = '';
    for (var i = 0; i < bytes.length;) {
      var b = bytes[i];
      var code;
      if (b < 0x80) {
        code = b;
        i++;
      } else if (b < 0xe0) {
        code = ((b & 31) << 6) | (bytes[i + 1] & 63);
        i += 2;
      } else if (b < 0xf0) {
        code = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
        i += 3;
      } else {
        code = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) |
          ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63);
        i += 4;
        code -= 0x10000;
        out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 1023));
        continue;
      }
      out += String.fromCharCode(code);
    }
    return out;
  }
}

function hexEncode(bytes) {
  var text = '';
  for (var i = 0; i < bytes.length; i++) {
    var value = bytes[i] & 0xff;
    text += (value < 16 ? '0' : '') + value.toString(16);
  }
  return text;
}

function hexDecode(text) {
  var clean = String(text || '').replace(/[^0-9a-fA-F]/g, '');
  if (clean.length % 2 !== 0) throw new Error('黄豆密钥格式无效');
  var out = new Uint8Array(clean.length / 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substr(i * 2, 2), 16);
  }
  return out;
}

function randomBytes(size) {
  try {
    if (host && typeof host.randomBytes === 'function') {
      return toBytes(host.randomBytes(size));
    }
  } catch (error) {
    /* 落到 Math.random */
  }
  var out = new Uint8Array(size);
  for (var i = 0; i < size; i++) out[i] = Math.floor(Math.random() * 256);
  return out;
}

function newUUID() {
  var bytes = randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  var hex = hexEncode(bytes);
  return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) +
    '-' + hex.slice(16, 20) + '-' + hex.slice(20);
}

function textOf(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return '';
}

function intOf(value) {
  var text = textOf(value);
  if (!/^\d+$/.test(text)) return 0;
  var number = parseInt(text, 10);
  return number > 2147483647 ? 0 : number;
}

function truncate(text, limit) {
  var chars = Array.from(String(text || ''));
  return chars.length <= limit ? chars.join('') : chars.slice(0, limit).join('') + '...';
}

function pad7(bytes) {
  var pad = 16 - (bytes.length % 16);
  var out = new Uint8Array(bytes.length + pad);
  out.set(bytes);
  for (var i = bytes.length; i < out.length; i++) out[i] = pad;
  return out;
}

function unpad7(bytes) {
  if (bytes.length === 0 || bytes.length % 16 !== 0) return bytes;
  var pad = bytes[bytes.length - 1];
  if (pad === 0 || pad > 16 || pad > bytes.length) return bytes;
  for (var i = bytes.length - pad; i < bytes.length; i++) {
    if (bytes[i] !== pad) return bytes;
  }
  return bytes.subarray(0, bytes.length - pad);
}

// ---------------------------------------------------------------- 加密通道

// host.aesCbcEncrypt 是否自带 PKCS7 由实现决定，这里探测一次并记住结论。
var aesPadsItself = null;

function aesEncrypt(key, iv, data) {
  if (aesPadsItself === null) {
    var probe = pad7(data);
    var first = toBytes(host.aesCbcEncrypt(key, iv, probe));
    if (first.length === probe.length) {
      aesPadsItself = false;
      return first;
    }
    if (first.length === probe.length + 16) {
      aesPadsItself = true;
      return toBytes(host.aesCbcEncrypt(key, iv, data));
    }
    aesPadsItself = false;
    return first;
  }
  return toBytes(host.aesCbcEncrypt(key, iv, aesPadsItself ? data : pad7(data)));
}

function aesDecrypt(key, iv, cipher) {
  var plain = toBytes(host.aesCbcDecrypt(key, iv, cipher));
  return unpad7(plain);
}

function keyFor(requestId) {
  var secret = utf8Encode(HEADER_KEY);
  var message = hexDecode(requestId.replace(/-/g, ''));
  return CRYPT.hmacSha256(secret, message);
}

// ---------------------------------------------------------------- 站点地址

function baseCandidates() {
  var list = [];
  var manifest = manifestOf();
  var configured = textOf(manifest.baseUrl) || textOf(manifest.base);
  if (configured !== '') list.push(configured.replace(/\/+$/, ''));
  var cached = host.cacheGet(CACHE_BASE);
  if (typeof cached === 'string' && /^https?:\/\//.test(cached)) list.push(cached);
  for (var i = 0; i < FALLBACK_HOSTS.length; i++) list.push('https://' + FALLBACK_HOSTS[i]);
  return list;
}

function originOf(base) {
  return String(base || '').replace(/\/+$/, '');
}

// 发布页是明文接口，用来补充 H5 线路（域名换得比较勤）。
function releaseHosts() {
  var hosts = [];
  try {
    var response = host.fetch({
      method: 'GET',
      url: 'https://' + RELEASE_HOST + '/api/site-config',
      headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' },
      limit: 256 * 1024,
      timeoutMs: 8000,
      followRedirects: true,
      anyStatus: true
    });
    var text = typeof response.body === 'string' ? response.body : '';
    if (text.charAt(0) !== '{') return hosts;
    var parsed = JSON.parse(text);
    var page = parsed && parsed.data ? parsed.data.releasePage : null;
    var entries = page && page.entries ? page.entries : [];
    for (var i = 0; i < entries.length && hosts.length < 8; i++) {
      var entry = entries[i];
      if (!entry || entry.kind !== 'h5') continue;
      var url = textOf(entry.url);
      if (/^https?:\/\//.test(url)) hosts.push(url.replace(/\/+$/, ''));
    }
  } catch (error) {
    /* 发布页不可用时只用内置线路 */
  }
  return hosts;
}

function utf8BytesOfString(text) {
  return utf8Encode(text);
}

// ---------------------------------------------------------------- 请求通道

function deviceId() {
  var cached = host.cacheGet(CACHE_DEVICE);
  if (typeof cached === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(cached)) {
    return cached;
  }
  var id = newUUID();
  try {
    host.cacheSet(CACHE_DEVICE, id, 0);
  } catch (error) {
    /* 缓存不可用不影响请求 */
  }
  return id;
}

function signOf(sessionId, requestId, stamp, url) {
  var hostPart = String(url).replace(/^https?:\/\//, '');
  var plain = 'Dart|' + sessionId + '|' + requestId + '|' + stamp + '|' + hostPart;
  return hexEncode(CRYPT.md5(utf8Encode(plain))) + '-' + stamp;
}

// 响应体可能是字符串（按 latin1 还原）或字节数组。
function responseBytes(response) {
  var fields = ['bytes', 'bodyBytes', 'raw', 'body'];
  for (var i = 0; i < fields.length; i++) {
    var value = response ? response[fields[i]] : null;
    if (value === null || value === undefined) continue;
    if (value instanceof Uint8Array || typeof value === 'string' || typeof value.length === 'number') {
      if (typeof value === 'string' && value.length === 0) continue;
      return toBytes(value);
    }
  }
  return null;
}

function decodeEnvelope(raw, key) {
  raw = toBytes(raw);
  var attempts = [];
  if (raw && raw.length > 16) {
    attempts.push(function () {
      var plain = aesDecrypt(key, raw.subarray(0, 16), raw.subarray(16));
      if (plain.length > 2 && plain[0] === 0x1f && plain[1] === 0x8b) {
        return ZLIB.gzipInflate(plain);
      }
      return plain;
    });
  }
  attempts.push(function () {
    return raw;
  });
  for (var i = 0; i < attempts.length; i++) {
    var payload;
    try {
      payload = attempts[i]();
    } catch (error) {
      continue;
    }
    if (payload === null || payload === undefined || payload.length === 0) continue;
    var text;
    try {
      text = utf8Decode(payload);
    } catch (error) {
      continue;
    }
    if (text.charAt(0) !== '{' && text.charAt(0) !== '[') continue;
    try {
      var parsed = JSON.parse(host.preserveIntegers ? host.preserveIntegers(text) : text);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch (error) {
      /* 试下一种 */
    }
  }
  return null;
}


// ---------------------------------------------------------------- 传输层
// 黄豆接口要求 iv+AES 密文的原始字节，两种走法：
//   1. 直连（首选）：App 的 host.fetch 支持 body 传 Uint8Array，
//      响应回 bodyBase64（jsFetchRequest.Body 为 []byte 的版本才有）。
//   2. 中转（回退）：老版 App 会把 Uint8Array 字符串化，只能走 127.0.0.1 上的
//      hd-proxy，用纯 ASCII 的 JSON + base64 承载二进制。
// 首请求直连，看响应里有没有 bodyBase64 字段即可判定 App 能力，之后固定走该路线。
var PROXY_URL = 'http://127.0.0.1:8799/proxy';
var BINARY_MODE = null; // null=未判定，true=直连，false=中转

function proxyPost(url, headers, body) {
  var doc = {
    url: url,
    method: 'POST',
    headers: headers,
    body: host.base64Encode(body)
  };
  var text;
  try {
    text = JSON.stringify(doc);
  } catch (error) {
    throw new Error('黄豆中转请求构造失败');
  }
  var response;
  try {
    response = host.fetch({
      method: 'POST',
      url: PROXY_URL,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      body: text,
      limit: 16 << 20,
      timeoutMs: 30000,
      anyStatus: true
    });
  } catch (error) {
    throw new Error('黄豆中转连不上（先在手机上启动中转服务）：' +
      (error && error.message ? error.message : error));
  }
  var incoming = '';
  if (response && typeof response.body === 'string') {
    incoming = response.body;
  } else {
    var bytesIn = responseBytes(response);
    if (bytesIn !== null) incoming = utf8Decode(bytesIn);
  }
  if (incoming === '') throw new Error('黄豆中转没有返回内容（中转服务是否还在运行？）');
  var parsed = null;
  try {
    parsed = JSON.parse(incoming);
  } catch (error) {
    parsed = null;
  }
  if (parsed === null || parsed.ok !== true) {
    throw new Error('黄豆中转失败：' + (parsed !== null && parsed.error ? parsed.error : '返回格式异常'));
  }
  var bytes = null;
  try {
    bytes = host.base64Decode(parsed.body);
  } catch (error) {
    bytes = null;
  }
  if (bytes === null || bytes.length === 0) throw new Error('黄豆中转返回空响应');
  return { status: parsed.status, raw: bytes };
}

// 直连：body 直接交 Uint8Array，响应从 bodyBase64 还原原始字节。
// 返回 null 表示这个 App 版本不支持（响应里没有 bodyBase64 字段）。
function directPost(url, headers, body) {
  var response = host.fetch({
    method: 'POST',
    url: url,
    headers: headers,
    body: body,
    limit: 16 << 20,
    timeoutMs: 30000,
    anyStatus: true,
    followRedirects: true
  });
  if (!response || typeof response.bodyBase64 !== 'string') return null;
  var raw = response.bodyBase64 === ''
    ? new Uint8Array(0)
    : toBytes(host.base64Decode(response.bodyBase64));
  return { status: response.status, raw: raw };
}

function binaryPost(url, headers, body) {
  if (BINARY_MODE !== false) {
    var direct = null;
    try {
      direct = directPost(url, headers, body);
    } catch (error) {
      // 已确认支持直连时，这是真实错误，往上抛；
      // 未判定时可能是网络故障，不急着钉死路线，交给下面的中转兜底。
      if (BINARY_MODE === true) throw error;
    }
    if (direct !== null) {
      BINARY_MODE = true;
      return direct;
    }
    BINARY_MODE = false;
  }
  return proxyPost(url, headers, body);
}

function apiPost(base, route, payload) {
  var dev = deviceId();
  var session = dev;
  var requestId = newUUID();
  var stamp = Math.floor(Date.now() / 1000);
  var url = originOf(base) + '/api' + route;
  var key = keyFor(requestId);
  var envelope = { token: '', deviceId: dev, data: payload === undefined ? {} : payload };
  var plain = ZLIB.gzipStored(utf8Encode(JSON.stringify(envelope)));
  var iv = randomBytes(16);
  var body = concatBytes(iv, aesEncrypt(key, iv, plain));
  var headers = {
    'User-Agent': USER_AGENT,
    Accept: '*/*',
    'Content-Type': 'application/json',
    Origin: originOf(base),
    Referer: originOf(base) + '/',
    version: API_VERSION,
    deviceType: 'web',
    time: String(stamp),
    sign: signOf(session, requestId, stamp, url),
    requestId: requestId,
    sessionId: session,
    deviceBrand: '',
    deviceModel: '',
    systemName: '',
    systemVersion: '',
    'X-Lang': 'zh'
  };
  var sent = binaryPost(url, headers, body);
  var envelopeOut = decodeEnvelope(sent.raw, key);
  if (envelopeOut === null) {
    throw new Error('黄豆接口返回无法解码（HTTP ' + sent.status + '）');
  }
  if (textOf(envelopeOut.status) === 'y') return envelopeOut;
  var message = textOf(envelopeOut.error);
  var code = intOf(envelopeOut.errorCode);
  throw new Error('黄豆接口返回错误' + (code > 0 ? '（' + code + '）' : '') +
    (message !== '' ? '：' + message : ''));
}

// 带域名回退的请求：一个线路不通就换个线路重试一次。
function apiCall(route, payload) {
  var candidates = baseCandidates();
  var lastError = null;
  for (var i = 0; i < candidates.length; i++) {
    try {
      var result = apiPost(candidates[i], route, payload);
      try {
        host.cacheSet(CACHE_BASE, originOf(candidates[i]), 0);
      } catch (error) {
        /* 忽略缓存失败 */
      }
      return result;
    } catch (error) {
      lastError = error;
    }
  }
  var extra = [];
  try {
    extra = releaseHosts();
  } catch (error) {
    extra = [];
  }
  for (var j = 0; j < extra.length; j++) {
    try {
      var second = apiPost(extra[j], route, payload);
      try {
        host.cacheSet(CACHE_BASE, originOf(extra[j]), 0);
      } catch (error) {
        /* 忽略 */
      }
      return second;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError !== null ? lastError : new Error('黄豆没有可用线路');
}

function listPayload(page, options) {
  var values = {
    page: String(page),
    page_size: String(PAGE_SIZE),
    order: '',
    cat_id: '',
    tag_id: '',
    source: '',
    canvas: '',
    keywords: '',
    update_status: '',
    pay_type: ''
  };
  if (options) {
    if (options.order) values.order = options.order;
    if (options.cat_id) values.cat_id = options.cat_id;
    if (options.source) values.source = options.source;
    if (options.keywords) values.keywords = options.keywords;
  }
  return values;
}

function rowsOf(response) {
  var data = response ? response.data : null;
  var rows = data && Array.isArray(data.list) ? data.list : null;
  if (rows === null) throw new Error('黄豆列表数据格式无效');
  if (rows.length > 200) throw new Error('黄豆列表返回过多条目');
  return rows;
}

// ---------------------------------------------------------------- 数据映射

function dramaFromRow(row) {
  var sourceId = textOf(row.id);
  if (sourceId === '') throw new Error('黄豆剧集缺少标识');
  var cover = textOf(row.img_y) || textOf(row.img_x) || textOf(row.img);
  var title = truncate(textOf(row.name), 200);
  var description = truncate(textOf(row.description), 8000);
  var episodes = intOf(row.episode_count);
  var tags = [];
  var honors = Array.isArray(row.honor_tags) ? row.honor_tags : [];
  for (var i = 0; i < honors.length && tags.length < 6; i++) {
    var honor = honors[i] || {};
    var type = textOf(honor.type);
    if (type === 'rank') tags.push('榜单');
    else if (type === 'like') tags.push('高赞');
    else if (type !== '') tags.push(type);
  }
  var corner = textOf(row.corner);
  if (corner !== '') tags.push(corner);
  return {
    id: host.dramaId(sourceId),
    source: host.source,
    sourceId: sourceId,
    title: title,
    name: title,
    desc: description,
    intro: description,
    cover: cover,
    coverUrl: cover,
    category: textOf(row.category) === '' ? CHANNEL : textOf(row.category),
    categoryName: textOf(row.category),
    remark: truncate(textOf(row.update_label), 120),
    releaseStatus: '',
    episodeCount: episodes,
    totalEpisode: episodes,
    score: '',
    tags: tags,
    channelName: CHANNEL,
    vip: textOf(row.pay_type) !== 'free'
  };
}

// ---------------------------------------------------------------- 对外接口

function validCategory(category) {
  var key = textOf(category);
  if (key === '') return true;
  if (key.length > 128) return false;
  if (key === '@new' || key === '@hot') return true;
  if (key.indexOf('f|') !== 0) return false;
  var parts = key.split('|');
  if (parts.length !== 4) return false;
  if (!/^[0-9]{1,10}$/.test(parts[1])) return false;
  if (!/^[a-z:._-]{0,32}$/.test(parts[2])) return false;
  if (!/^[a-z0-9:._-]{0,32}$/.test(parts[3])) return false;
  return true;
}

module.exports = {
  validCategory: validCategory,

  categories: function () {
    var list = [];
    var response = apiCall('/drama/navList', { position: '', with_filters: '1' });
    var groups = response.data && Array.isArray(response.data.list) ? response.data.list : [];
    var seen = { '': true, '@new': true, '@hot': true };
    var labels = { '全部': true, '最新': true, '热门': true };
    list.push({ id: '', name: '全部' });
    list.push({ id: '@new', name: '最新' });
    list.push({ id: '@hot', name: '热门' });
    for (var i = 0; i < groups.length; i++) {
      var group = groups[i] || {};
      var filters = Array.isArray(group.filters) ? group.filters : [];
      var groupName = truncate(textOf(group.name), 24);
      for (var j = 0; j < filters.length && list.length < 60; j++) {
        var filter = filters[j] || {};
        var spec = filter.filter || {};
        var catId = textOf(spec.cat_id);
        var order = textOf(spec.order);
        var source = textOf(spec.source);
        var id = 'f|' + catId + '|' + order + '|' + source;
        if (seen[id] === true) continue;
        seen[id] = true;
        var name = truncate(textOf(filter.name), 40);
        if (name === '') name = groupName !== '' ? groupName : '分类';
        // 站点多个分组会用同名筛选（最新/推荐/全部），同名的补上分组名区分。
        var label = name;
        if (labels[label] === true) {
          if (groupName !== '' && groupName !== name) label = name + '·' + groupName;
          else if (order !== '') label = name + '·' + order.replace(/:/g, '');
          else if (source !== '') label = name + '·' + source;
        }
        var guard = 2;
        while (labels[label] === true && guard < 10) {
          label = name + '·' + guard;
          guard++;
        }
        labels[label] = true;
        list.push({ id: id, name: label });
      }
    }
    return list;
  },

  catalogPage: function (page, category) {
    var current = parseInt(page, 10);
    if (!isFinite(current) || current < 1) current = 1;
    if (current > MAX_PAGE) return { items: [], hasMore: false };
    var options = null;
    var key = textOf(category);
    if (key === '@new') {
      options = { order: 'new:top' };
    } else if (key === '@hot') {
      options = { order: 'hot:top' };
    } else if (key.indexOf('f|') === 0) {
      var parts = key.split('|');
      options = {
        cat_id: parts.length > 1 ? parts[1] : '',
        order: parts.length > 2 ? parts[2] : '',
        source: parts.length > 3 ? parts[3] : ''
      };
    }
    var response = apiCall('/drama/list', listPayload(current, options));
    var rows = rowsOf(response);
    var items = [];
    var seenIds = {};
    for (var i = 0; i < rows.length; i++) {
      var drama = dramaFromRow(rows[i] || {});
      if (seenIds[drama.sourceId] === true) continue;
      seenIds[drama.sourceId] = true;
      items.push(drama);
    }
    return {
      items: items,
      hasMore: rows.length >= PAGE_SIZE && current < MAX_PAGE
    };
  },

  detail: function (sourceId) {
    var id = textOf(sourceId);
    if (!/^[0-9a-fA-F]{8,40}$/.test(id)) throw new Error('黄豆剧集标识无效');
    var response = apiCall('/drama/detail', { id: id });
    var data = response.data || {};
    var drama = dramaFromRow(data);
    drama.desc = truncate(textOf(data.description), 8000);
    drama.intro = drama.desc;
    var cover = textOf(data.img_y) || textOf(data.img_x);
    if (cover !== '') {
      drama.cover = cover;
      drama.coverUrl = cover;
    }
    if (textOf(data.pay_type) !== '') drama.vip = textOf(data.pay_type) !== 'free';
    var rows = Array.isArray(data.episodes) ? data.episodes : [];
    if (rows.length > 5000) throw new Error('黄豆分集目录格式无效');
    var chapters = [];
    var seenSeq = {};
    for (var i = 0; i < rows.length; i++) {
      var episode = rows[i] || {};
      var seq = intOf(episode.seq);
      if (seq === 0) seq = i + 1;
      if (seenSeq[seq] === true) continue;
      seenSeq[seq] = true;
      var title = truncate(textOf(episode.name), 80);
      if (title === '') title = '第 ' + seq + ' 集';
      chapters.push({
        id: host.chapterId(id, String(seq)),
        source: host.source,
        title: title,
        currentEpisode: seq,
        videoUrl: 'huangdou-play://' + seq,
        referer: originOf(host.cacheGet(CACHE_BASE) || '') || 'https://' + FALLBACK_HOSTS[0] + '/'
      });
    }
    chapters.sort(function (left, right) {
      return left.currentEpisode - right.currentEpisode;
    });
    return { drama: drama, chapters: chapters };
  },

  search: function (page, query) {
    var current = parseInt(page, 10);
    if (!isFinite(current) || current < 1) current = 1;
    if (current > MAX_PAGE) return { items: [], hasMore: false };
    var keyword = textOf(query);
    if (keyword === '') return { items: [], hasMore: false };
    var response = apiCall('/drama/list', listPayload(current, { keywords: keyword }));
    var rows = rowsOf(response);
    var items = [];
    var seenIds = {};
    for (var i = 0; i < rows.length; i++) {
      var drama = dramaFromRow(rows[i] || {});
      if (seenIds[drama.sourceId] === true) continue;
      seenIds[drama.sourceId] = true;
      items.push(drama);
    }
    return {
      items: items,
      hasMore: rows.length >= PAGE_SIZE && current < MAX_PAGE
    };
  },

  // 自定义 scheme 落到这里：播放地址带 exp/sig，只能播放前现取。
  resolveMedia: function (task) {
    var prefix = host.source + ':';
    var dramaId = textOf(task && task.dramaId);
    var sourceId = dramaId.indexOf(prefix) === 0 ? dramaId.slice(prefix.length) : dramaId;
    if (!/^[0-9a-fA-F]{8,40}$/.test(sourceId)) throw new Error('黄豆播放剧集无效');
    var chapter = task && task.chapter ? task.chapter : {};
    var seq = 0;
    var videoUrl = textOf(chapter.videoUrl);
    if (videoUrl.indexOf('huangdou-play://') === 0) {
      seq = intOf(videoUrl.slice('huangdou-play://'.length));
    }
    if (seq === 0) seq = intOf(chapter.currentEpisode);
    if (seq === 0) {
      var chapterPrefix = host.chapterId(sourceId, '');
      var chapterId = textOf(chapter.id);
      if (chapterId.indexOf(chapterPrefix) === 0) seq = intOf(chapterId.slice(chapterPrefix.length));
    }
    if (seq <= 0) throw new Error('黄豆播放分集无效');
    var response = apiCall('/drama/play', { id: sourceId, seq: String(seq) });
    var data = response.data || {};
    var media = textOf(data.m3u8);
    if (media === '') media = textOf(data.preview_m3u8);
    if (media === '') {
      var lines = Array.isArray(data.lines) ? data.lines : [];
      for (var i = 0; i < lines.length && media === ''; i++) {
        media = textOf((lines[i] || {}).url);
      }
    }
    if (media === '') throw new Error('黄豆未返回播放地址');
    var refererBase = originOf(host.cacheGet(CACHE_BASE) || '') || 'https://' + FALLBACK_HOSTS[0];
    return {
      url: media,
      referer: refererBase + '/',
      durationMs: intOf(data.duration) * 1000
    };
  }
};
})();
