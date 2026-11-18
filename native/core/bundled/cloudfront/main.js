// 黄果旧版（cloudfront）站源模块 —— 复刻 native/core/provider_legacy*.go。
// 站点前端托管在 CloudFront，API 域名从前端脚本动态探活；请求参数 AES-CBC
// 加密后放 query/body，响应 AES 解密（key/iv 由 interfaceKey + 前12字节派生）；
// 访客登录后拿 token，之后所有接口带 Authorization。
// host 原语：fetch/fetchText/cacheGet/cacheSet/utf8Encode/utf8Decode/
// base64Decode/aesCbcEncrypt/aesCbcDecrypt/sha256/hexEncode/randomBytes。

var sourceId = host.source;
var meta = host.manifest() || {};
var sourceName = meta.name || sourceId;
var frontend = (host.baseUrl && host.baseUrl()) || meta.baseUrl || meta.base || 'https://d2pypzndaqisk.cloudfront.net';
var frontendOrigin = frontend.replace(/\/+$/, '');

var XUA_TMPL = 'BuildID=com.abc.Butterfly;SysType=ios;DevID={dev};Ver=1.0.0;DevType=iPhone;DeviceBrand=APPLE;DeviceModel=iPhone;SystemName=iOS;SystemVersion=18.7;Terminal=1;IsH5=1;Sid=00000000000000000000000000000000';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
var SEED_HOSTS = [
  'https://dr6skssi3nxbk.cloudfront.net',
  'https://d18ka9rqpfd3lo.cloudfront.net',
  'https://d37n0wjehmw08f.cloudfront.net'
];
var DEFAULT_CDN = 'https://d2pypzndaqisk.cloudfront.net/';
var CACHE_KEY_CRED = 'cloudfront.cred.v1';
var CACHE_KEY_HOST = 'cloudfront.host.v1';
var CACHE_TTL = 10 * 60 * 1000;

function trim(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'string') return v.trim();
  if (typeof v === 'number') return String(Math.trunc(v));
  if (typeof v === 'boolean') return String(v);
  return '';
}

function text(node) {
  if (!node || typeof node !== 'object') return '';
  for (var i = 1; i < arguments.length; i++) {
    var v = trim(node[arguments[i]]);
    if (v !== '') return v;
  }
  return '';
}

function intValue(v) {
  if (typeof v === 'number') return Math.trunc(v);
  var m = trim(v).match(/^[+-]?\d+/);
  return m ? parseInt(m[0], 10) : 0;
}

function listOf(node, key) {
  if (!node || typeof node !== 'object') return [];
  return Object.prototype.toString.call(node[key]) === '[object Array]' ? node[key] : [];
}

function bytesOf(v) {
  if (typeof v === 'string') return host.utf8Encode(v);
  return v;
}

function jsonParse(raw, fallback) {
  try { return JSON.parse(raw); } catch (e) { return fallback; }
}

// ---- 前端脚本抓 key（interfaceKey/parameterKey/parameterIv/imgKey），带缓存 ----
function discoverProtocol() {
  var cached = host.cacheGet(CACHE_KEY_CRED);
  var cred = cached ? jsonParse(cached, null) : null;
  if (cred && cred.interfaceKey && cred.paramKey && cred.paramIv) return cred;
  var homeRes = host.fetchText({ url: frontend + '/', referer: frontendOrigin + '/' });
  var home = homeRes && homeRes.body ? homeRes.body : '';
  var m = /["']([^"']*main-[^"']*\.js)["']/.exec(home);
  if (!m) throw new Error('黄果旧版前端未找到 main 脚本');
  var scriptPath = m[1];
  var scriptURL = scriptPath.indexOf('http') === 0 ? scriptPath
    : frontendOrigin + (scriptPath.indexOf('/') === 0 ? scriptPath : '/' + scriptPath);
  var jsRes = host.fetchText({ url: scriptURL, referer: frontendOrigin + '/' });
  var js = jsRes && jsRes.body ? jsRes.body : '';
  function grab(name) {
    // 前端形如 t(ue,"interfaceKey","值") / "interfaceKey":"值"：找 key 后的第一个引号串。
    var needle = '"' + name + '"';
    var at = js.indexOf(needle);
    if (at < 0) at = js.indexOf("'" + name + "'");
    if (at < 0) return '';
    // key 后可能是 ,"值"（真网 t(ue,"key","值")）或 ]="值"（对象字面量），
    // 统一跳过分隔符，取第一个成对的引号串作为值。
    var rest = js.slice(at + needle.length, at + needle.length + 8);
    var qm = /(["'])/.exec(rest);
    if (!qm) return '';
    var quote = qm[1];
    var start = at + needle.length + qm.index;
    var end = js.indexOf(quote, start + 1);
    return end > start + 1 ? js.slice(start + 1, end) : '';
  }
  var interfaceKey = grab('interfaceKey');
  var paramKey = grab('parameterKey');
  var paramIv = grab('parameterIv');
  if (interfaceKey === '' || paramKey === '' || paramIv === '') {
    throw new Error('黄果旧版前端未能解析加密密钥');
  }
  cred = { interfaceKey: interfaceKey, paramKey: paramKey, paramIv: paramIv, imgKey: grab('imgKey') };
  host.cacheSet(CACHE_KEY_CRED, JSON.stringify(cred), CACHE_TTL);
  return cred;
}

// ---- API 域探活：逐个 ping/check，成功者缓存；全挂则从前端再发现 ----
function discoverHost(force) {
  if (!force) {
    var cached = host.cacheGet(CACHE_KEY_HOST);
    if (cached) return cached;
  }
  // baseUrl 指向的域优先（真网前端域兼 API 域；测试/自定义部署靠它注入）。
  var candidates = [];
  if (frontendOrigin && frontendOrigin.indexOf('http') === 0) candidates.push(frontendOrigin);
  for (var s = 0; s < SEED_HOSTS.length; s++) {
    if (candidates.indexOf(SEED_HOSTS[s]) < 0) candidates.push(SEED_HOSTS[s]);
  }
  var i;
  for (i = 0; i < candidates.length; i++) {
    try {
      var res = host.fetch({ url: candidates[i] + '/api/app/ping/check', method: 'GET', timeoutMs: 8000,
        headers: { 'User-Agent': UA, 'Accept': '*/*', 'Origin': frontendOrigin, 'Referer': frontendOrigin + '/' } });
      if (res && res.status >= 200 && res.status < 300 && /"code"\s*:\s*"?200"?/.test(res.body || '')) {
        host.cacheSet(CACHE_KEY_HOST, candidates[i], CACHE_TTL);
        return candidates[i];
      }
    } catch (e) { /* 换下一个域 */ }
  }
  // 从前端脚本正则再发现 cloudfront 域（脚本已在 discoverProtocol 读过，可重取）。
  try {
    var homeR = host.fetchText({ url: frontend + '/', referer: frontendOrigin + '/' });
    var home = homeR && homeR.body ? homeR.body : '';
    var m = /["']([^"']*main-[^"']*\.js)["']/.exec(home);
    if (m) {
      var su = m[1].indexOf('http') === 0 ? m[1] : frontendOrigin + (m[1].indexOf('/') === 0 ? m[1] : '/' + m[1]);
      var jsR = host.fetchText({ url: su, referer: frontendOrigin + '/' });
      var js = jsR && jsR.body ? jsR.body : '';
      var re = /(https:\/\/)[a-z0-9]+\.cloudfront\.net/g;
      var found;
      while ((found = re.exec(js)) !== null) {
        var h = found[0];
        if (candidates.indexOf(h) < 0) candidates.push(h);
      }
      for (i = 1; i < candidates.length; i++) {
        try {
          var res2 = host.fetch({ url: candidates[i] + '/api/app/ping/check', method: 'GET', timeoutMs: 8000,
            headers: { 'User-Agent': UA, 'Accept': '*/*', 'Origin': frontendOrigin, 'Referer': frontendOrigin + '/' } });
          if (res2 && /"code"\s*:\s*"?200"?/.test(res2.body || '')) {
            host.cacheSet(CACHE_KEY_HOST, candidates[i], CACHE_TTL);
            return candidates[i];
          }
        } catch (e2) { /* next */ }
      }
    }
  } catch (e3) { /* fall through */ }
  return candidates[0];
}

// ---- 请求参数加密：AES-CBC(JSON, key, iv) → base64 ----
function encryptParams(params, cred) {
  var raw = host.utf8Encode(JSON.stringify(params));
  var enc = host.aesCbcEncrypt(host.utf8Encode(cred.paramKey), host.utf8Encode(cred.paramIv), raw);
  return host.base64Encode(enc);
}

// ---- 响应解密：key/iv 由 interfaceKey + data 前12字节派生（复刻 decryptResponse）----
function decryptData(b64, cred) {
  var o = host.base64Decode(b64);
  var i = o.slice(0, 12);
  var r = host.utf8Encode(cred.interfaceKey).concat(i);
  var half = Math.floor(r.length / 2);
  var sha = host.sha256(r);
  var s = sha.slice(8, 24);
  var c = s.concat(r.slice(0, half));
  var a = r.slice(half).concat(s);
  var d = host.sha256(c);
  var f = host.sha256(a);
  var key = d.slice(0, 8).concat(f.slice(8, 24)).concat(d.slice(24, 32));
  var iv = f.slice(0, 4).concat(d.slice(12, 20)).concat(f.slice(28, 32));
  var plain = host.aesCbcDecrypt(key, iv, o.slice(12));
  if (plain.length > 0) {
    var pad = plain[plain.length - 1];
    if (pad > 0 && pad <= 16) plain = plain.slice(0, plain.length - pad);
  }
  return host.utf8Decode(plain);
}

// ---- 访客登录（POST），带缓存；token 失效时 force 重登 ----
function ensureSession(force) {
  var cached = host.cacheGet(CACHE_KEY_CRED + '.session');
  var session = cached ? jsonParse(cached, null) : null;
  if (session && session.token && !force) return session;
  var cred = discoverProtocol();
  var dev = host.hexEncode(host.randomBytes(16)).toUpperCase().slice(0, 16) + String(Date.now());
  var enc = encryptParams({ devID: dev, sysType: 'ios', isAppStore: false }, cred);
  var res = host.fetch({ url: discoverHost() + '/api/app/mine/login/h5', method: 'POST', timeoutMs: 20000,
    headers: { 'User-Agent': UA, 'Accept': 'application/json', 'Content-Type': 'application/json',
      'temp': 'test', 'X-User-Agent': XUA_TMPL.replace('{dev}', dev),
      'Origin': frontendOrigin, 'Referer': frontendOrigin + '/' },
    body: JSON.stringify({ data: enc }) });
  var env = jsonParse(res.body, null);
  if (!env || trim(env.code) !== '200') throw new Error('黄果旧版访客登录失败');
  var payload = jsonParse(decryptData(env.data, cred), null) || {};
  if (payload.token === '' || payload.token === undefined) throw new Error('黄果旧版登录未返回令牌');
  session = { token: payload.token, dev: dev };
  host.cacheSet(CACHE_KEY_CRED + '.session', JSON.stringify(session), CACHE_TTL);
  return session;
}

// ---- 统一 API 调用：GET + 加密 query；解 envelope；token 5005 失效重登重试 ----
function apiGet(apiPath, params, retry) {
  var cred = discoverProtocol();
  var session = ensureSession(false);
  var url = discoverHost() + apiPath;
  if (params !== undefined && params !== null) url += '?data=' + encodeURIComponent(encryptParams(params, cred));
  var res = host.fetch({ url: url, method: 'GET', timeoutMs: 20000,
    headers: { 'User-Agent': UA, 'Accept': 'application/json', 'temp': 'test',
      'X-User-Agent': XUA_TMPL.replace('{dev}', session.dev), 'Authorization': session.token,
      'Origin': frontendOrigin, 'Referer': frontendOrigin + '/' } });
  var env = jsonParse(res.body, null);
  if (!env) throw new Error('黄果旧版接口返回无效数据');
  var code = trim(env.code);
  if (code !== '' && code !== '200' && code !== '0') {
    if (code === '5005' && retry !== true) {
      ensureSession(true);
      return apiGet(apiPath, params, true);
    }
    throw new Error('黄果旧版 API 错误 ' + code + '：' + trim(env.msg));
  }
  var raw = env.data === undefined || env.data === null ? '' : env.data;
  if (typeof raw === 'object') return raw;
  var payload = trim(env.hash) !== '' && trim(env.hash) !== 'false' && trim(env.hash) !== '0' && raw !== ''
    ? decryptData(raw, cred) : raw;
  var decoded = jsonParse(payload, null);
  if (decoded === null) throw new Error('黄果旧版接口数据无法解析');
  return decoded;
}

function categories() {
  var tabs = apiGet('/api/app/playlet-tab/all', null);
  var rows = Object.prototype.toString.call(tabs) === '[object Array]' ? tabs : (tabs.list || []);
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    var id = text(rows[i], 'id', 'ID');
    if (id === '') continue;
    out.push({ id: id, name: text(rows[i], 'name', 'Name') || '分类' });
  }
  return out;
}

function dramaFromNode(node, tabName) {
  if (!node || typeof node !== 'object') return null;
  var id = text(node, 'id', 'ID', 'sourceId');
  if (id === '') return null;
  var cover = '';
  var coverKeys = ['cover', 'coverUrl', 'cover_url', 'image', 'imageUrl', 'image_url',
    'img', 'pic', 'picture', 'poster', 'thumb', 'thumbnail'];
  for (var c = 0; c < coverKeys.length; c++) {
    var cv = node[coverKeys[c]];
    if (typeof cv === 'string' && cv.indexOf('http') === 0) { cover = cv; break; }
  }
  var total = intValue(node.totalEpisode !== undefined ? node.totalEpisode
    : (node.total_episode !== undefined ? node.total_episode
      : (node.episodeCount !== undefined ? node.episodeCount
        : (node.episode_count !== undefined ? node.episode_count : node.total))));
  var cat = text(node, 'categoryName', 'category_name', 'typeName', 'type_name', 'sortName', 'sort_name', 'category') || tabName;
  return {
    id: host.dramaId(id), source: sourceId, sourceId: id,
    title: text(node, 'title', 'name'), name: text(node, 'name', 'title'),
    intro: text(node, 'desc', 'description', 'summary', 'intro'),
    cover: cover, episodeCount: total, category: cat, channelName: tabName || sourceName,
    tags: text(node, 'tags') !== '' ? String(node.tags).split(/[,，、]+/) : []
  };
}

function catalogPage(pageNumber, category) {
  var page = pageNumber > 0 ? pageNumber : 1;
  var tabs = categories();
  var chosen = [];
  for (var i = 0; i < tabs.length; i++) {
    if (category === '' || category === tabs[i].id) chosen.push(tabs[i]);
  }
  if (chosen.length === 0) throw new Error('黄果旧版分类已调整，请刷新');
  var pageSize = 30;
  var items = [];
  var seen = {};
  var hasMore = false;
  for (var k = 0; k < chosen.length; k++) {
    var result = apiGet('/api/app/playlet/home/tab/' + encodeURIComponent(chosen[k].id),
      { pageNumber: String(page), pageSize: String(pageSize), tabSortType: '1' });
    var rows = listOf(result, 'list');
    hasMore = hasMore || rows.length >= pageSize;
    for (var j = 0; j < rows.length; j++) {
      var drama = dramaFromNode(rows[j], chosen[k].name);
      if (!drama || drama.id === '' || seen[drama.id]) continue;
      seen[drama.id] = true;
      items.push(drama);
    }
  }
  return { items: items, hasMore: hasMore };
}

function detail(sourceID) {
  var id = trim(sourceID);
  if (id === '') throw new Error('黄果旧版剧集 ID 无效');
  var d = apiGet('/api/app/playlet/detail/' + encodeURIComponent(id), null);
  var drama = dramaFromNode(d, '') || {};
  drama.id = host.dramaId(id);
  drama.source = sourceId;
  drama.sourceId = id;
  drama.title = text(d, 'title', 'name') || drama.title;
  drama.name = text(d, 'name', 'title') || drama.name;
  var rows = listOf(d, 'chapters');
  if (rows.length === 0) rows = listOf(apiGet('/api/app/playlet-chapter/list/' + encodeURIComponent(id), null), 'list');
  var chapters = [];
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    var chapterID = text(row, 'id', 'ID') || String(i + 1);
    var number = intValue(row.currentEpisode !== undefined ? row.currentEpisode
      : (row.episode !== undefined ? row.episode : row.number));
    if (number <= 0) number = i + 1;
    chapters.push({
      id: host.dramaId(id) + ':' + number,
      source: sourceId,
      title: text(row, 'title') || ('第' + number + '集'),
      currentEpisode: number,
      videoUrl: text(row, 'videoUrl', 'video_url', 'url', 'playUrl'),
      referer: frontendOrigin + '/'
    });
  }
  if (chapters.length === 0) throw new Error('黄果旧版未返回可播放分集');
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  if (drama.episodeCount === undefined || intValue(drama.episodeCount) <= 0) drama.episodeCount = chapters.length;
  return { drama: drama, chapters: chapters };
}

function search(pageNumber, query) {
  // 黄果旧版无在线搜索，走本地分类缓存过滤（与 Go 语义一致：不匹配返回空）。
  var keyword = trim(query);
  if (keyword === '') return { items: [], hasMore: false };
  var items = [];
  var seen = {};
  var tabs = categories();
  for (var i = 0; i < tabs.length && items.length < 60; i++) {
    var result = apiGet('/api/app/playlet/home/tab/' + encodeURIComponent(tabs[i].id),
      { pageNumber: '1', pageSize: '30', tabSortType: '1' });
    var rows = listOf(result, 'list');
    for (var j = 0; j < rows.length; j++) {
      var drama = dramaFromNode(rows[j], tabs[i].name);
      if (!drama || drama.id === '' || seen[drama.id]) continue;
      seen[drama.id] = true;
      if (drama.title.indexOf(keyword) >= 0 || drama.intro.indexOf(keyword) >= 0) items.push(drama);
    }
  }
  return { items: items, hasMore: false };
}

function resolveMedia(task) {
  var chapter = task && task.chapter ? task.chapter : {};
  var address = trim(chapter.videoUrl);
  if (address === '') throw new Error('此分集没有可用的播放地址');
  var cred = discoverProtocol();
  var session = ensureSession(false);
  if (address.indexOf('http') !== 0) {
    address = discoverHost() + '/api/app/vid/h5/m3u8/' + encodeURIComponent(address) +
      '?token=' + encodeURIComponent(session.token) + '&c=' + encodeURIComponent(DEFAULT_CDN);
  }
  var media = host.prepareWebMedia({ url: address, referer: frontendOrigin + '/' }, sourceName);
  return media;
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search,
  resolveMedia: resolveMedia
};
