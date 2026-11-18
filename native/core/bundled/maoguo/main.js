// 猫果（maoguo）站源模块 —— 按上游 guoapp-modules 写法实现。
// 请求头带 qm-params（设备 JSON → base64 → 字符表映射）与 md5 签名；
// 列表/搜索走 api-store，详情走 api-read。与内置 Go 实现
// native/sources/maoguo 语义一致，并按站点现状修正了分类来源：
// /api/v1/playlet/tag/list 已下线，真实分类在 index 响应的 data.tag_items。

var sourceId = host.source;
var meta = host.manifest() || {};
var sourceName = meta.name || sourceId;
var defaultBase = 'https://api-store.qmplaylet.com';
var storeBase = (host.baseUrl && host.baseUrl()) || meta.base || meta.baseUrl || defaultBase;
var referer = meta.referer || defaultBase + '/';
// 详情接口在独立域名；基址被覆盖（域名韧性/测试）时从基址派生。
var readBase = storeBase.replace(/\/+$/, '') !== defaultBase
  ? storeBase.replace(/\/+$/, '')
  : 'https://api-read.qmplaylet.com';
var key = 'd3dGiJc651gSQ8w1';
var trackID = 'ec1280db127955061754851657967';

var charMap = {
  '+': 'P', '/': 'X', '0': 'M', '1': 'U', '2': 'l', '3': 'E', '4': 'r', '5': 'Y', '6': 'W', '7': 'b', '8': 'd', '9': 'J',
  'A': '9', 'B': 's', 'C': 'a', 'D': 'I', 'E': '0', 'F': 'o', 'G': 'y', 'H': '_', 'I': 'H', 'J': 'G', 'K': 'i', 'L': 't',
  'M': 'g', 'N': 'N', 'O': 'A', 'P': '8', 'Q': 'F', 'R': 'k', 'S': '3', 'T': 'h', 'U': 'f', 'V': 'R', 'W': 'q', 'X': 'C',
  'Y': '4', 'Z': 'p', 'a': 'm', 'b': 'B', 'c': 'O', 'd': 'u', 'e': 'c', 'f': '6', 'g': 'K', 'h': 'x', 'i': '5', 'j': 'T',
  'k': '-', 'l': '2', 'm': 'z', 'n': 'S', 'o': 'Z', 'p': '1', 'q': 'V', 'r': 'v', 's': 'j', 't': 'Q', 'u': '7', 'v': 'D',
  'w': 'w', 'x': 'n', 'y': 'L', 'z': 'e'
};

function trim(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(Math.trunc(value));
  if (typeof value === 'boolean') return String(value);
  return '';
}

function text(node) {
  if (!node || typeof node !== 'object') return '';
  var keys = Array.prototype.slice.call(arguments, 1);
  for (var i = 0; i < keys.length; i++) {
    var value = trim(node[keys[i]]);
    if (value !== '') return value;
  }
  return '';
}

function intValue(value) {
  if (typeof value === 'number') return Math.trunc(value);
  var matched = trim(value).match(/^[+-]?\d+/);
  return matched ? parseInt(matched[0], 10) : 0;
}

function md5Hex(raw) {
  return host.hexEncode(host.md5(raw));
}

// 对齐 provider.StringList + 站点实际：tags 有时是数组、有时是「甲,乙」字符串。
function stringList(value) {
  if (!value) return [];
  var out = [];
  if (Object.prototype.toString.call(value) === '[object Array]') {
    for (var i = 0; i < value.length; i++) {
      var entry = value[i];
      var item = trim(typeof entry === 'object' && entry !== null ? text(entry, 'name', 'title', 'class_name') : entry);
      if (item !== '' && out.indexOf(item) < 0) out.push(item);
    }
    return out;
  }
  var raw = trim(value);
  if (raw === '') return [];
  var parts = raw.split(/[,，、|\/]+/);
  for (var k = 0; k < parts.length; k++) {
    var part = parts[k].trim();
    if (part !== '' && out.indexOf(part) < 0) out.push(part);
  }
  return out;
}

// 设备参数 → base64 → 字符表映射，再对固定拼接串做 md5。
function requestHeaders() {
  var payload = {
    'static_score': '0.8',
    'uuid': '00000000-7fc7-08dc-0000-000000000000',
    'device-id': '20250220125449b9b8cac84c2dd3d035c9052a2572f7dd0122edde3cc42a70',
    'mac': '',
    'sourceuid': 'aa7de295aad621a6',
    'refresh-type': '0',
    'model': '22021211RC',
    'wlb-imei': '',
    'client-id': 'aa7de295aad621a6',
    'brand': 'Redmi',
    'oaid': '',
    'oaid-no-cache': '',
    'sys-ver': '12',
    'trusted-id': '',
    'phone-level': 'H',
    'imei': '',
    'wlb-uid': 'aa7de295aad621a6',
    'session-id': String(Date.now())
  };
  var encoded = host.base64Encode(JSON.stringify(payload));
  var mapped = '';
  for (var i = 0; i < encoded.length; i++) {
    var ch = encoded.charAt(i);
    mapped += Object.prototype.hasOwnProperty.call(charMap, ch) ? charMap[ch] : ch;
  }
  var signature = md5Hex('AUTHORIZATION=' +
    'app-version=10001' +
    'application-id=com.duoduo.read' +
    'channel=unknown' +
    'is-white=' +
    'net-env=5' +
    'platform=android' +
    'qm-params=' + mapped +
    'reg=' + key);
  return {
    'net-env': '5',
    'reg': '',
    'channel': 'unknown',
    'is-white': '',
    'platform': 'android',
    'application-id': 'com.duoduo.read',
    'authorization': '',
    'app-version': '10001',
    'user-agent': 'webviewversion/0',
    'qm-params': mapped,
    'sign': signature,
    'Accept': 'application/json',
    'X-Requested-With': 'com.duoduo.read',
    'Referer': referer
  };
}

function getJSON(address) {
  var response = host.fetch({ method: 'GET', url: address, headers: requestHeaders(), timeoutMs: 15000, limit: 8 << 20 });
  if (!response) throw new Error('猫果请求失败');
  if (response.status < 200 || response.status >= 300) throw new Error('猫果 HTTP ' + response.status);
  try {
    return JSON.parse(response.body);
  } catch (error) {
    throw new Error('猫果返回的数据格式无效');
  }
}

function coverOf(node) {
  return text(node, 'image_link', 'imageLink', 'cover', 'cover_url', 'coverUrl');
}

function dramaFromNode(node) {
  var id = text(node, 'playlet_id', 'playletId', 'id');
  if (id === '') return null;
  var total = intValue(node.total_episode_num !== undefined ? node.total_episode_num
    : (node.totalEpisodeNum !== undefined ? node.totalEpisodeNum
      : (node.total !== undefined ? node.total : node.total_num)));
  var tags = stringList(node.tags);
  if (tags.length === 0) tags = stringList(node.tag_list);
  return {
    id: host.dramaId(id),
    source: sourceId,
    sourceId: id,
    title: text(node, 'title', 'playlet_name', 'name'),
    name: text(node, 'title', 'playlet_name', 'name'),
    intro: text(node, 'intro', 'description', 'desc'),
    cover: coverOf(node),
    episodeCount: total,
    releaseStatus: trim(node.is_over) === '1' ? 'finished' : (total > 0 ? 'ongoing' : ''),
    category: tags.join(', '),
    tags: tags,
    channelName: sourceName
  };
}

function catalogItems(data) {
  var rows = data && Object.prototype.toString.call(data.list) === '[object Array]' ? data.list : [];
  var items = [];
  for (var i = 0; i < rows.length; i++) {
    var drama = dramaFromNode(rows[i]);
    if (drama) items.push(drama);
  }
  return items;
}

// 站点已下线 tag/list：先试旧接口，失败或为空则回落到 index 的 tag_items。
function categories() {
  var rows = [];
  try {
    var response = getJSON(storeBase + '/api/v1/playlet/tag/list?operation=1&sign=' + md5Hex('operation=1' + key));
    rows = (response && response.data && Object.prototype.toString.call(response.data.list) === '[object Array]') ? response.data.list : [];
  } catch (error) {
    rows = [];
  }
  if (rows.length === 0) {
    var index = getJSON(storeBase + '/api/v1/playlet/index?tag_id=0&playlet_privacy=1&operation=1&sign=' + md5Hex('operation=1playlet_privacy=1tag_id=0' + key));
    rows = (index && index.data && Object.prototype.toString.call(index.data.tag_items) === '[object Array]') ? index.data.tag_items : [];
  }
  var out = [];
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var node = rows[i];
    var id = text(node, 'tag_id', 'id');
    var name = text(node, 'tag_name', 'name', 'title');
    if (id === '' || name === '' || seen[id] || name.length > 24) continue;
    seen[id] = true;
    out.push({ id: id, name: name });
  }
  if (out.length === 0) throw new Error('猫果未返回有效分类');
  return out;
}

function catalogPage(pageNumber, category) {
  var tagID = trim(category);
  // tag_id 允许 0（推荐）与 -1（新剧），对齐站点真实取值。
  if (!/^-?\d+$/.test(tagID)) tagID = '0';
  var address;
  if (pageNumber > 1) {
    address = storeBase + '/api/v1/playlet/index?tag_id=' + encodeURIComponent(tagID) +
      '&playlet_privacy=1&operation=1&next_id=' + pageNumber +
      '&sign=' + md5Hex('next_id=' + pageNumber + 'operation=1playlet_privacy=1tag_id=' + tagID + key);
  } else {
    address = storeBase + '/api/v1/playlet/index?tag_id=' + encodeURIComponent(tagID) +
      '&playlet_privacy=1&operation=1' +
      '&sign=' + md5Hex('operation=1playlet_privacy=1tag_id=' + tagID + key);
  }
  var response = getJSON(address);
  var items = catalogItems(response && response.data ? response.data : {});
  return { items: items, hasMore: pageNumber > 1 ? items.length > 0 : false };
}

function detail(sourceID) {
  var id = trim(sourceID);
  if (id === '') throw new Error('猫果剧集 ID 无效');
  var address = readBase.replace(/\/+$/, '') + '/player/api/v1/playlet/info?playlet_id=' +
    encodeURIComponent(id) + '&sign=' + md5Hex('playlet_id=' + id + key);
  var response = getJSON(address);
  var data = response && response.data ? response.data : null;
  if (!data || typeof data !== 'object') throw new Error('猫果未返回剧集资料');
  var drama = dramaFromNode(data) || {};
  drama.id = host.dramaId(id);
  drama.source = sourceId;
  drama.sourceId = id;
  drama.channelName = sourceName;

  var rows = Object.prototype.toString.call(data.play_list) === '[object Array]' ? data.play_list : [];
  var chapters = [];
  for (var i = 0; i < rows.length; i++) {
    var node = rows[i];
    var videoUrl = text(node, 'video_url', 'videoUrl', 'url');
    if (videoUrl === '') continue;
    var number = intValue(node.sort !== undefined ? node.sort : (node.episode !== undefined ? node.episode : node.index));
    if (number <= 0) number = i + 1;
    var title = text(node, 'title', 'name');
    if (title === '') title = '第' + number + '集';
    chapters.push({
      id: host.dramaId(id) + ':' + number,
      source: sourceId,
      title: title,
      currentEpisode: number,
      videoUrl: videoUrl,
      pageUrl: '',
      referer: referer
    });
  }
  if (chapters.length === 0) throw new Error('猫果未返回可播放分集');
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  drama.episodeCount = chapters.length;
  return { drama: drama, chapters: chapters };
}

function search(pageNumber, query) {
  var keyword = trim(query);
  if (keyword === '') return { items: [], hasMore: false };
  var address = storeBase + '/api/v1/playlet/search?extend=&page=1&wd=' + encodeURIComponent(keyword) +
    '&read_preference=0&track_id=' + trackID +
    '&sign=' + md5Hex('extend=page=1read_preference=0track_id=' + trackID + 'wd=' + keyword + key);
  var response = getJSON(address);
  return { items: catalogItems(response && response.data ? response.data : {}), hasMore: false };
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search
};