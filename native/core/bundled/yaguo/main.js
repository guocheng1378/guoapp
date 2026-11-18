// 芽果（yaguo）站源模块 —— 按上游 guoapp-modules 写法实现。
// 先匿名登录取 token（缓存 6h），所有接口带 authorization/platform/version_name。
// 与内置 Go 实现 native/sources/yaguo 语义一致。

var sourceId = host.source;
var meta = host.manifest() || {};
var sourceName = meta.name || sourceId;
var defaultBase = 'https://app.whjzjx.cn';
var baseUrl = (host.baseUrl && host.baseUrl()) || meta.base || meta.baseUrl || defaultBase;
var referer = meta.referer || baseUrl + '/';
// 对齐 Go 版 loginAddress：基址被覆盖（域名韧性/测试）时从基址派生登录路径。
var loginURL = baseUrl.replace(/\/+$/, '') !== defaultBase
  ? baseUrl.replace(/\/+$/, '') + '/user/v1/account/login'
  : 'https://u.shytkjgs.com/user/v1/account/login';
var device = '24250683a3bdb3f118dff25ba4b1cba1a';
var tokenCacheKey = 'yaguo.token.v1';
var tokenTTL = 6 * 60 * 60 * 1000;
var userAgent = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

function trim(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(Math.trunc(value));
  if (typeof value === 'boolean') return String(value);
  return '';
}

function text(row) {
  if (!row || typeof row !== 'object') return '';
  var keys = Array.prototype.slice.call(arguments, 1);
  for (var i = 0; i < keys.length; i++) {
    var value = trim(row[keys[i]]);
    if (value !== '') return value;
  }
  return '';
}

function intValue(value) {
  if (typeof value === 'number') return Math.trunc(value);
  var matched = trim(value).match(/^[+-]?\d+/);
  return matched ? parseInt(matched[0], 10) : 0;
}

function stringList(value) {
  if (!Array.isArray(value)) return [];
  var out = [];
  for (var i = 0; i < value.length; i++) {
    var item = trim(value[i]);
    if (item !== '' && out.indexOf(item) < 0) out.push(item);
  }
  return out;
}

function releaseStatus(raw, total, current) {
  var value = trim(raw);
  if (value === 'finished' || value === '2' || value === '完结') return 'finished';
  if (value === 'ongoing' || value === '1' || value === '更新中') return 'ongoing';
  if (total > 0 && current >= total) return 'finished';
  if (current > 0) return 'ongoing';
  return '';
}

// 登录取 token：exclusive 串行 + cache 缓存，避免并发登录。
function fetchToken() {
  return host.exclusive(function () {
    var cached = host.cacheGet(tokenCacheKey);
    if (typeof cached === 'string' && cached !== '') return cached;
    var response = host.fetch({
      method: 'POST',
      url: loginURL,
      headers: { 'platform': '1', 'Content-Type': 'application/json', 'User-Agent': userAgent, 'Referer': referer },
      body: JSON.stringify({ device: device }),
      timeoutMs: 15000
    });
    if (!response || response.status < 200 || response.status >= 300) throw new Error('芽果登录失败');
    var decoded;
    try { decoded = JSON.parse(response.body); } catch (error) { throw new Error('芽果登录返回无效'); }
    var token = text(decoded.data, 'token') || text(decoded, 'token');
    if (token === '') throw new Error('芽果未返回有效的访问令牌');
    host.cacheSet(tokenCacheKey, token, tokenTTL);
    return token;
  });
}

function authHeaders() {
  return {
    'User-Agent': userAgent,
    'Accept': 'application/json, text/plain, */*',
    'Referer': referer,
    'authorization': fetchToken(),
    'platform': '1',
    'version_name': '3.8.3.1'
  };
}

function getJSON(path) {
  var response = host.fetch({ method: 'GET', url: baseUrl + path, headers: authHeaders(), timeoutMs: 15000 });
  if (!response || response.status < 200 || response.status >= 300) throw new Error('芽果 HTTP ' + (response ? response.status : 0));
  try { return JSON.parse(response.body); } catch (error) { throw new Error('芽果返回的数据格式无效'); }
}

function postJSON(path, payload) {
  var headers = authHeaders();
  headers['Content-Type'] = 'application/json';
  var response = host.fetch({ method: 'POST', url: baseUrl + path, headers: headers, body: JSON.stringify(payload), timeoutMs: 15000 });
  if (!response || response.status < 200 || response.status >= 300) throw new Error('芽果 HTTP ' + (response ? response.status : 0));
  try { return JSON.parse(response.body); } catch (error) { throw new Error('芽果返回的数据格式无效'); }
}

function queryString(params) {
  var parts = [];
  for (var key in params) {
    if (Object.prototype.hasOwnProperty.call(params, key)) {
      parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(params[key]));
    }
  }
  return parts.join('&');
}

function dramaFromNode(node) {
  var theater = (node && typeof node.theater === 'object' && node.theater !== null) ? node.theater : node;
  var id = text(theater, 'id', 'theater_id', 'theater_parent_id');
  if (id === '') return null;
  var total = intValue(theater.total !== undefined ? theater.total : (theater.total_num !== undefined ? theater.total_num : theater.current_num));
  return {
    id: host.dramaId(id),
    source: sourceId,
    sourceId: id,
    title: text(theater, 'title', 'name'),
    name: text(theater, 'title', 'name'),
    intro: text(theater, 'descrip', 'introduction', 'desc'),
    cover: text(theater, 'cover_url', 'son_cover_url', 'cover'),
    episodeCount: total,
    releaseStatus: releaseStatus('', total, intValue(theater.current_num)),
    category: stringList(theater.tags).join(', '),
    tags: stringList(theater.tags),
    channelName: sourceName
  };
}

function categories() {
  var response = getJSON('/cloud/v2/theater/classes');
  var out = [];
  var seen = {};
  var walk = function (obj) {
    if (!obj || typeof obj !== 'object') return;
    if (Array.isArray(obj.alg_class)) {
      for (var i = 0; i < obj.alg_class.length; i++) {
        var node = obj.alg_class[i];
        var id = text(node, 'id');
        var name = text(node, 'class_name', 'name');
        if (id !== '' && name !== '' && !seen[id] && Array.from(name).length <= 24) {
          seen[id] = true;
          out.push({ id: id, name: name });
        }
      }
    }
    for (var key in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, key)) walk(obj[key]);
    }
  };
  walk(response && response.data ? response.data : response);
  if (out.length === 0) throw new Error('芽果未返回有效分类');
  return out;
}

function hasMoreFrom(data, page, count) {
  var end = data.is_end === true || data.is_end === 1 || String(data.is_end) === 'true';
  var total = intValue(data.total);
  return !end && count > 0 && total > page * count;
}

function catalogPage(pageNumber, category) {
  var classID = trim(category);
  if (classID === '9') {
    var rank = getJSON('/cloud/v1/first_level_ranking/detail?' + queryString({ id: '1' }));
    var rows = (rank && rank.data && Array.isArray(rank.data.list)) ? rank.data.list : [];
    var rankItems = [];
    for (var r = 0; r < rows.length; r++) {
      var d = dramaFromNode(rows[r]);
      if (d) rankItems.push(d);
    }
    return { items: rankItems, hasMore: false };
  }
  if (classID !== '' && !/^\d+$/.test(classID)) classID = '';
  var params = { theater_class_id: classID, type: '1', class2_ids: '0', page_num: String(pageNumber), page_size: '24' };
  var response = getJSON('/cloud/v2/theater/home_page?' + queryString(params));
  var data = response && response.data ? response.data : {};
  var list = Array.isArray(data.list) ? data.list : [];
  var items = [];
  for (var i = 0; i < list.length; i++) {
    var drama = dramaFromNode(list[i]);
    if (drama) items.push(drama);
  }
  return { items: items, hasMore: hasMoreFrom(data, pageNumber, items.length) };
}

function detail(sourceID) {
  var id = trim(sourceID);
  if (id === '') throw new Error('芽果剧集 ID 无效');
  var response = getJSON('/v2/theater_parent/detail?' + queryString({ theater_parent_id: id }));
  var data = response && response.data ? response.data : null;
  if (!data || typeof data !== 'object') throw new Error('芽果未返回剧集资料');
  var total = intValue(data.total);
  var current = intValue(data.current_num);
  var isOver = intValue(data.is_over);
  var status = releaseStatus(String(isOver), total, current);
  if (status === '' && isOver === 2) status = 'finished';
  var drama = {
    id: host.dramaId(id),
    source: sourceId,
    sourceId: id,
    title: text(data, 'title', 'share_title'),
    name: text(data, 'title', 'share_title'),
    intro: text(data, 'descrip', 'introduction', 'share_title'),
    cover: text(data, 'cover_url', 'share_cover'),
    episodeCount: total,
    releaseStatus: status,
    channelName: sourceName
  };
  var chapters = [];
  var theaters = Array.isArray(data.theaters) ? data.theaters : [];
  for (var i = 0; i < theaters.length; i++) {
    var node = theaters[i];
    var videoUrl = text(node, 'son_video_url', 'video_url');
    if (videoUrl === '') continue;
    var number = intValue(node.num !== undefined ? node.num : node.sort);
    if (number <= 0) number = i + 1;
    chapters.push({
      id: host.dramaId(id) + ':' + number,
      source: sourceId,
      title: text(node, 'son_title', 'title'),
      currentEpisode: number,
      videoUrl: videoUrl,
      pageUrl: '',
      referer: referer
    });
  }
  if (chapters.length === 0) throw new Error('芽果未返回可播放分集');
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  drama.episodeCount = chapters.length;
  return { drama: drama, chapters: chapters };
}

function search(pageNumber, query) {
  var keyword = trim(query);
  if (keyword === '') return { items: [], hasMore: false };
  var response = postJSON('/v3/search', { text: keyword });
  var data = response && response.data ? response.data : {};
  var rows = Array.isArray(data.list) ? data.list : null;
  if (!rows && data.theater && Array.isArray(data.theater.search_data)) rows = data.theater.search_data;
  var items = [];
  for (var i = 0; rows && i < rows.length; i++) {
    var drama = dramaFromNode(rows[i]);
    if (drama) items.push(drama);
  }
  return { items: items, hasMore: false };
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search
};
