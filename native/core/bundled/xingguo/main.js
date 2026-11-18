// 星果（xingguo）站源模块 —— 按上游 guoapp-modules 写法实现。
// 目录/详情/搜索均为 GET + 固定公共参数，无签名；分集直链嵌在
// shortPlayList[].chapterShortPlayVoList[].shortPlayUrl。
// 与内置 Go 实现 native/sources/xingguo 语义一致。

var sourceId = host.source;
var meta = host.manifest() || {};
var sourceName = meta.name || sourceId;
var baseUrl = (host.baseUrl && host.baseUrl()) || meta.base || meta.baseUrl || 'http://read.api.duodutek.com';
var referer = meta.referer || baseUrl + '/';
var userAgent = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

var productID = '2a8c14d1-72e7-498b-af23-381028eb47c0';
var vestID = '2be070e0-c824-4d0e-a67a-8f688890cadb';
var token = '202509271001001446030204698626';
var channel = 'oppo19';
var version = '20';

var categories = [
  { id: '1287', name: '推荐一' },
  { id: '1288', name: '推荐二' },
  { id: '1289', name: '推荐三' },
  { id: '1290', name: '推荐四' },
  { id: '1291', name: '推荐五' }
];

function trim(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(Math.trunc(value));
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

function commonQuery(extra) {
  var parts = [
    'productId=' + encodeURIComponent(productID),
    'vestId=' + encodeURIComponent(vestID),
    'channel=' + encodeURIComponent(channel),
    'osType=android',
    'version=' + encodeURIComponent(version),
    'token=' + encodeURIComponent(token)
  ];
  for (var key in extra) {
    if (Object.prototype.hasOwnProperty.call(extra, key)) {
      parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(extra[key]));
    }
  }
  return parts.join('&');
}

function requestJSON(path) {
  var response = host.fetch({
    method: 'GET',
    url: baseUrl + path,
    headers: {
      'User-Agent': userAgent,
      'Accept': 'application/json',
      'Referer': referer
    },
    timeoutMs: 15000,
    limit: 4 << 20
  });
  if (!response) throw new Error('星果请求失败');
  if (response.status < 200 || response.status >= 300) throw new Error('星果 HTTP ' + response.status);
  try {
    return JSON.parse(response.body);
  } catch (error) {
    throw new Error('星果返回的数据格式无效');
  }
}

function dramaOf(node) {
  var id = text(node, 'id', 'bookId');
  if (id === '') return null;
  // 星果把简介编码进 sourceId 携带到详情（对齐 Go 版 id@intro 约定）。
  var intro = text(node, 'introduction', 'desc');
  var sourceKey = intro === '' ? id : id + '@' + intro;
  var heat = intValue(node.heat);
  return {
    id: host.dramaId(sourceKey),
    source: sourceId,
    sourceId: sourceKey,
    title: text(node, 'name', 'title'),
    name: text(node, 'name', 'title'),
    intro: intro,
    cover: text(node, 'icon', 'cover'),
    episodeCount: intValue(node.chapterCount !== undefined ? node.chapterCount : node.total),
    heat: heat > 0 ? String(heat) : '',
    views: heat > 0 ? String(heat) + '万播放' : '',
    channelName: sourceName
  };
}

function catalogPage(pageNumber, category) {
  var resourceID = trim(category) || categories[0].id;
  if (!/^\d+$/.test(resourceID)) return { items: [], hasMore: false, warning: '星果分类无效' };
  var query = commonQuery({ resourceId: resourceID, pageNum: String(pageNumber), pageSize: '10' });
  var response = requestJSON('/novel-api/app/pageModel/getResourceById?' + query);
  var data = response && response.data ? response.data : {};
  var rows = Array.isArray(data.datalist) ? data.datalist : [];
  var items = [];
  for (var i = 0; i < rows.length; i++) {
    var drama = dramaOf(rows[i]);
    if (drama) items.push(drama);
  }
  return { items: items, hasMore: items.length >= 10 };
}

function search(pageNumber, query) {
  var keyword = trim(query);
  if (keyword === '') return { items: [], hasMore: false };
  var params = commonQuery({ key: keyword, pageNum: '1', pageSize: '20' });
  var response = requestJSON('/novel-api/basedata/book/searchBook?' + params);
  var data = response && response.data ? response.data : {};
  var rows = Array.isArray(data.datalist) ? data.datalist : [];
  var items = [];
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var drama = dramaOf(rows[i]);
    if (!drama || seen[drama.id]) continue;
    seen[drama.id] = true;
    items.push(drama);
  }
  return { items: items, hasMore: false };
}

// 递归找分集直链（对齐 Go 版 episodeURL）。
function episodeURL(node) {
  if (!node || typeof node !== 'object') return '';
  var direct = text(node, 'shortPlayUrl', 'playUrl', 'url');
  if (direct !== '') return direct;
  var keys = ['shortPlayList', 'chapterShortPlayVoList'];
  for (var k = 0; k < keys.length; k++) {
    var list = Array.isArray(node[keys[k]]) ? node[keys[k]] : [];
    for (var i = 0; i < list.length; i++) {
      var found = episodeURL(list[i]);
      if (found !== '') return found;
    }
  }
  return '';
}

function detail(sourceID) {
  var id = trim(sourceID);
  var cut = id.indexOf('@');
  var bookID = cut >= 0 ? id.slice(0, cut) : id;
  var intro = cut >= 0 ? id.slice(cut + 1) : '';
  if (bookID === '') throw new Error('星果剧集 ID 无效');
  var query = commonQuery({ bookId: bookID });
  var response = requestJSON('/novel-api/basedata/book/getChapterList?' + query);
  var rows = Array.isArray(response && response.data) ? response.data : [];
  var drama = {
    id: host.dramaId(id),
    source: sourceId,
    sourceId: id,
    intro: intro,
    channelName: sourceName
  };
  var chapters = [];
  for (var i = 0; i < rows.length; i++) {
    var node = rows[i];
    var videoUrl = episodeURL(node);
    if (videoUrl === '') continue;
    var number = intValue(node.chapterNum !== undefined ? node.chapterNum : (node.chapterIndex !== undefined ? node.chapterIndex : (node.sort !== undefined ? node.sort : node.index)));
    if (number <= 0) number = i + 1;
    chapters.push({
      id: host.dramaId(id) + ':' + number,
      source: sourceId,
      title: text(node, 'chapterName', 'title'),
      currentEpisode: number,
      videoUrl: videoUrl,
      pageUrl: '',
      referer: referer
    });
  }
  if (chapters.length === 0) throw new Error('星果未返回可播放分集');
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  drama.episodeCount = chapters.length;
  return { drama: drama, chapters: chapters };
}

module.exports = {
  categories: function () { return categories; },
  catalogPage: catalogPage,
  detail: detail,
  search: search
};
