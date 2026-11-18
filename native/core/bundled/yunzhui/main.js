// 云追（yunzhui）站源模块 —— 按上游 guoapp-modules 写法实现。
// 协议严格对齐 native/sources/yunzhui：
//  1) 全部 POST，body 为 x-www-form-urlencoded 字符串；
//  2) 固定请求头 + MD5 签名 UPPER(HEX(MD5(signKey+device+curTime)))；
//  3) 响应外层 Base64 + AES-256-CBC/PKCS7 解密（host 原语），失败按明文 JSON 兜底；
//  4) 4 个 API 域轮转（网络/JSON 失败换域，业务码错误不换）；
//  5) 详情/取流需游客 token（init_v2 首次发放，30min 缓存）。
// 真网 2026-11-17 探针：8 个接口全部 HTTP 200 / code=10000。
// 坑：已被服务端记住的 device 再次 init 不再发 token，须用新 device 首次注册。

var sourceId = host.source;
var meta = host.manifest() || {};
var sourceName = meta.name || sourceId;

var defaultBase = 'https://u.gslock.com/';
var configuredBase = (host.baseUrl && host.baseUrl()) || '';
var primaryBase = configuredBase || defaultBase;
var imgBase = 'http://wim.xzjykj.com/';

var appID = 'yunzhuishipin';
var packageName = 'com.hjmore.jsyfjz';
var appVersion = '51000';
var signKey = 'zD9[bM4~sF4~uY2)';
var aesKey = 'aZ9$kU5%qI7=yC2=zH2#gM0@pX7^wF3a';
var aesIV = 'hY2&tN3]kF7,dL7=';
var apiHosts = ['u.gslock.com', 'u.alvzz.com', 'u.irltk.com', 'u.yyxdmn.com'];
var tokenTTL = 30 * 60 * 1000;

// 游客身份（模块实例内缓存，跨调用复用；跨进程重启换游客不影响游客态业务）。
var device = '';
var guestToken = '';
var guestTokenAt = 0;
var channelSpecs = null;
var catalogOrder = [];

function trim(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  if (typeof value === 'boolean') return String(value);
  return '';
}

function firstNonEmpty() {
  var values = arguments;
  for (var i = 0; i < values.length; i++) {
    var value = trim(values[i]);
    if (value !== '') return value;
  }
  return '';
}

function listOf(value) {
  return Object.prototype.toString.call(value) === '[object Array]' ? value : [];
}

function ensureDevice() {
  if (device !== '') return device;
  var cached = host.cacheGet(sourceId + ':device');
  if (cached) {
    device = trim(cached);
  }
  if (device === '') {
    device = host.hexEncode(host.randomBytes(8));
    try { host.cacheSet(sourceId + ':device', device, 0); } catch (e) {}
  }
  return device;
}

function signature(ts) {
  var raw = signKey + ensureDevice() + ts;
  return host.hexEncode(host.md5(host.utf8Encode(raw))).toUpperCase();
}

function formBody(form) {
  var parts = [];
  for (var key in form) {
    if (Object.prototype.hasOwnProperty.call(form, key)) {
      var value = form[key];
      parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(value === null || value === undefined ? '' : String(value)));
    }
  }
  return parts.join('&');
}

// 响应解密：Base64 → AES-256-CBC → UTF-8 JSON；失败按明文 JSON 兜底。
function decodeResponse(raw) {
  var text = '';
  try {
    var cipherBytes = host.base64Decode(trim(raw));
    var plain = host.aesCbcDecrypt(host.utf8Encode(aesKey), host.utf8Encode(aesIV), cipherBytes);
    text = host.utf8Decode(plain);
  } catch (e) {
    text = '';
  }
  if (text.length === 0 || text.charAt(0) !== '{') text = trim(raw);
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error('云追响应数据格式无效');
  }
}

function apiAddresses(path) {
  var list = [];
  var parsed = host.parseUrl(primaryBase);
  var hostname = (parsed && parsed.hostname) || '';
  if (primaryBase === defaultBase || apiHosts.indexOf(hostname) >= 0) {
    for (var i = 0; i < apiHosts.length; i++) list.push('https://' + apiHosts[i] + path);
  } else {
    list.push(primaryBase.replace(/\/+$/, '') + path);
  }
  return list;
}

function call(path, form, authed) {
  var payload = form || {};
  var token = authed ? ensureToken() : '';
  var ts = String(Date.now());
  var headers = {
    'app_id': appID,
    'package_name': packageName,
    'version': appVersion,
    'sys_platform': '2',
    'mob_mfr': 'xiaomi',
    'mobmodel': '2211133C',
    'sysrelease': '15',
    'device_id': ensureDevice(),
    'channel_code': 'official',
    'cur_time': ts,
    'token': token,
    'sign': signature(ts),
    'Content-Type': 'application/x-www-form-urlencoded'
  };
  var addresses = apiAddresses(path);
  var lastError = null;
  for (var i = 0; i < addresses.length; i++) {
    var response;
    try {
      response = host.fetch({
        method: 'POST',
        url: addresses[i],
        headers: headers,
        body: formBody(payload),
        timeoutMs: 20000,
        limit: 8 << 20
      });
    } catch (fetchError) {
      lastError = fetchError;
      continue;
    }
    if (!response || response.status < 200 || response.status >= 300) {
      lastError = new Error('云追 HTTP ' + (response ? response.status : 0));
      continue;
    }
    var decoded;
    try {
      decoded = decodeResponse(response.body || '');
    } catch (decodeError) {
      lastError = decodeError;
      continue;
    }
    if (String(decoded.code) !== '10000') {
      // 业务码（token 失效/参数错误/内容下架）换域名不会自愈，直接抛可读错误。
      throw new Error('云追: ' + (trim(decoded.message) || '请求被拒绝'));
    }
    return decoded;
  }
  throw lastError || new Error('云追请求失败');
}

function ensureToken() {
  if (guestToken !== '' && Date.now() - guestTokenAt < tokenTTL) return guestToken;
  var decoded = call('/api/new_public/init_v2', {}, false);
  var result = decoded.result || {};
  var info = result.user_info || {};
  var token = trim(info.token);
  if (token === '') throw new Error('云追游客身份初始化失败');
  guestToken = token;
  guestTokenAt = Date.now();
  return guestToken;
}

function coverURL(pic) {
  var value = trim(pic);
  if (value === '') return '';
  if (value.indexOf('http://') === 0 || value.indexOf('https://') === 0) return value;
  return imgBase + value.replace(/^\/+/, '');
}

function categoryName(pid) {
  switch (trim(pid)) {
    case '1': return '电影';
    case '2': return '国产剧';
    case '3': return '综艺';
    case '4': return '国漫';
    default: return '';
  }
}

function releaseStatus(value) {
  switch (trim(value)) {
    case '1': return 'finished';
    case '0': return 'ongoing';
    default: return 'unknown';
  }
}

function splitTags(value) {
  var raw = trim(value);
  if (raw === '') return [];
  var parts = raw.split(/[,，/]+/);
  var out = [];
  for (var i = 0; i < parts.length; i++) {
    var tag = parts[i].trim();
    if (tag !== '' && out.indexOf(tag) < 0) out.push(tag);
  }
  return out;
}

function toDrama(raw) {
  var row = raw || {};
  var id = trim(row.id);
  if (id === '') return null;
  var intro = firstNonEmpty(row.vod_blurb, row.remarks);
  return {
    id: host.dramaId(id),
    source: sourceId,
    sourceId: id,
    title: trim(row.vod_name),
    name: trim(row.vod_name),
    desc: intro,
    intro: intro,
    cover: coverURL(row.vod_pic),
    episodes: trim(row.vod_serial),
    channelName: sourceName,
    category: categoryName(row.type_pid),
    area: trim(row.vod_area),
    year: trim(row.vod_year),
    score: trim(row.vod_douban_score),
    heat: firstNonEmpty(row.click_count, row.total_view_count),
    tags: splitTags(row.vod_tag),
    releaseStatus: releaseStatus(row.vod_isend)
  };
}

function dramas(decoded) {
  var rows = listOf(decoded.result);
  var out = [];
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var drama = toDrama(rows[i]);
    if (!drama || drama.id === '' || seen[drama.id]) continue;
    seen[drama.id] = true;
    out.push(drama);
  }
  return out;
}

function loadChannels() {
  var decoded = call('/api/new_channel/get_list_v2', {}, false);
  var rows = listOf(decoded.result);
  var specs = {};
  var order = [];
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {};
    var id = trim(row.id);
    var name = trim(row.channel_name);
    if (id === '' || name === '') continue;
    specs[id] = {
      name: name,
      typeId: trim(row.vod_type_id),
      area: trim(row.screen_area),
      sort: trim(row.screen_sort),
      featured: name === '推荐'
    };
    order.push({ id: id, name: name });
  }
  if (order.length === 0) throw new Error('云追未返回频道列表');
  channelSpecs = specs;
  catalogOrder = order;
  return order;
}

function categories() {
  return loadChannels();
}

function findSpec(category) {
  if (!channelSpecs) loadChannels();
  var key = trim(category);
  if (channelSpecs[key]) return channelSpecs[key];
  for (var id in channelSpecs) {
    if (Object.prototype.hasOwnProperty.call(channelSpecs, id) && channelSpecs[id].name === key) {
      return channelSpecs[id];
    }
  }
  return null;
}

function catalogPage(pageNumber, category) {
  var page = pageNumber > 0 ? pageNumber : 1;
  var spec = findSpec(category);
  if (spec && spec.featured) {
    var featured = call('/api/new_search/recommend_v2', {}, false);
    return { items: dramas(featured), hasMore: false };
  }
  var form = { pn: String(page), type_id: spec ? spec.typeId : trim(category) };
  if (spec && spec.area !== '') form.area = spec.area;
  if (spec && spec.sort !== '') form.sort = spec.sort;
  var decoded = call('/api/new_search/screen_v2', form, false);
  var items = dramas(decoded);
  return { items: items, hasMore: items.length >= 20 };
}

function detail(vodID) {
  var id = trim(vodID);
  if (id === '') throw new Error('云追剧集 ID 无效');
  var decoded = call('/api/new_video/result_v2', { vod_id: id }, true);
  var result = decoded.result || {};
  var empty = true;
  for (var check in result) { if (Object.prototype.hasOwnProperty.call(result, check)) { empty = false; break; } }
  if (empty) throw new Error('云追详情为空');
  var drama = toDrama(result) || {};
  drama.id = host.dramaId(id);
  drama.source = sourceId;
  drama.sourceId = id;
  drama.channelName = sourceName;
  var rows = listOf(result.vod_collection);
  var chapters = [];
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {};
    var number = parseInt(trim(row.collection), 10);
    if (isNaN(number) || number <= 0) number = i + 1;
    var title = trim(row.title_desc);
    if (title === '') title = '第' + number + '集';
    chapters.push({
      id: host.dramaId(id) + ':' + number,
      source: sourceId,
      title: title,
      currentEpisode: number,
      videoUrl: '',
      pageUrl: primaryBase.replace(/\/+$/, '') + '/play/' + encodeURIComponent(id) + '/' + number,
      referer: ''
    });
  }
  if (chapters.length === 0) throw new Error('云追未返回可播放分集');
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  drama.episodeCount = trim(result.vod_serial);
  return { drama: drama, chapters: chapters };
}

function search(pageNumber, query) {
  var keyword = trim(query);
  if (keyword === '') return { items: [], hasMore: false };
  var decoded = call('/api/new_search/result_v2', { kw: keyword, pn: '1' }, false);
  return { items: dramas(decoded), hasMore: false };
}

function pickEpisode(rows, episode) {
  var first = null;
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {};
    if (first === null) first = row;
    if (trim(row.collection) === episode || trim(row.title) === episode) return row;
  }
  return first;
}

function buildMedias(result) {
  var out = [];
  var raw = result.m3u8_json;
  var items = [];
  if (typeof raw === 'string' && trim(raw) !== '') {
    try { items = JSON.parse(raw); } catch (e) { items = []; }
  } else {
    items = listOf(raw);
  }
  for (var i = 0; i < items.length; i++) {
    var url = trim(items[i] && items[i].url);
    if (url !== '') out.push(url);
  }
  var fallback = trim(result.vod_url);
  if (fallback !== '') out.push(fallback);
  return out;
}

function resolveMedia(task) {
  var input = task || {};
  var dramaID = trim(input.dramaId);
  var separator = dramaID.indexOf(':');
  var vodID = separator >= 0 ? dramaID.slice(separator + 1) : dramaID;
  if (vodID === '') throw new Error('云追剧集信息无效');
  var chapter = input.chapter || {};
  var episode = trim(chapter.currentEpisode);
  if (episode === '') episode = String((input.index || 0) + 1);
  var decoded = call('/api/new_video/result_v2', { vod_id: vodID }, true);
  var result = decoded.result || {};
  var picked = pickEpisode(listOf(result.vod_collection), episode);
  if (!picked) throw new Error('云追分集信息不存在，请刷新详情后重试');
  var media = call('/api/new_video/collection_v2', {
    vod_token: trim(picked.vod_token),
    cur_time: trim(picked.cur_time),
    vod_id: vodID,
    collection_id: trim(picked.id),
    session_id: '',
    sig: '',
    nc_token: '',
    phone: '',
    code: ''
  }, true);
  var addresses = buildMedias(media.result || {});
  if (addresses.length === 0) throw new Error('云追未返回有效播放地址');
  // 媒体 CDN 对任何非空 Referer 都返回 403（真网实测），故 referer 必须留空。
  var primary = host.prepareWebMedia({ url: addresses[0], referer: '' }, sourceName);
  if (addresses.length > 1) {
    var variants = [];
    for (var i = 1; i < addresses.length; i++) variants.push({ url: addresses[i], referer: '' });
    primary.variants = variants;
  }
  return primary;
}

// 榜单查询参数：与 Go 侧 provider_rankings.go 的 8 个云追榜一一对应。
// 榜单条目由 screen_v2 按 type_id/area/sort 取，参数口径与 Go 版 ranking.go 一致。
var rankingBoardSpecs = {
  'yunzhui-daily-drama':   { typeId: '2',  area: '内地', sort: '日榜' },
  'yunzhui-daily-movie':   { typeId: '1',  area: '',     sort: '日榜' },
  'yunzhui-daily-variety': { typeId: '3',  area: '',     sort: '日榜' },
  'yunzhui-daily-short':   { typeId: '31', area: '',     sort: '日榜' },
  'yunzhui-total-drama':   { typeId: '2',  area: '内地', sort: '最热' },
  'yunzhui-total-movie':   { typeId: '1',  area: '',     sort: '最热' },
  'yunzhui-total-variety': { typeId: '3',  area: '',     sort: '最热' },
  'yunzhui-total-short':   { typeId: '31', area: '',     sort: '最热' }
};

// rankingPage 返回 Drama 数组（非对象）——Go 侧 ModuleRankingPage 直接反序列化到 []Drama。
function rankingPage(boardId, page) {
  var spec = rankingBoardSpecs[boardId];
  if (!spec) throw new Error('未知的云追榜单：' + boardId);
  var number = page > 0 ? page : 1;
  var form = { pn: String(number), type_id: spec.typeId, sort: spec.sort };
  if (spec.area !== '') form.area = spec.area;
  var decoded = call('/api/new_search/screen_v2', form, false);
  return dramas(decoded);
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search,
  resolveMedia: resolveMedia,
  rankingPage: rankingPage
};
