// 饭果（fanguo）站源模块 —— 按上游 guoapp-modules 写法实现。
// 站点逻辑全部在 JS 内：目录/搜索走 /xifan/search/getSearchList，
// 详情走 /xifan/drama/getDuanjuInfo，分集是直链（交给核心通用解析链路）。
// 与内置 Go 实现 native/sources/fanguo 语义保持一致，导出同名 id 接管原 provider。

var sourceId = host.source;
var meta = host.manifest() || {};
var sourceName = meta.name || sourceId;
var baseUrl = (host.baseUrl && host.baseUrl()) || meta.base || meta.baseUrl || 'https://xifan-api-cn.youlishipin.com';
var referer = meta.referer || baseUrl + '/';
var userAgent = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

var categories = [
  { id: '都市', name: '都市' },
  { id: '甜宠', name: '甜宠' },
  { id: '逆袭', name: '逆袭' },
  { id: '战神', name: '战神' },
  { id: '古装', name: '古装' },
  { id: '穿越', name: '穿越' },
  { id: '萌宝', name: '萌宝' }
];
var defaultKeyword = '都市';

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

function csv(values) {
  return values.join(', ');
}

function coverOf(row) {
  return text(row, 'coverImageUrl', 'cover_image_url', 'cover');
}

function releaseStatus(raw, total, current) {
  var value = trim(raw).toLowerCase();
  if (['over', 'finished', 'completed', '2', '已完结', '完结'].indexOf(value) >= 0) return 'finished';
  if (['ongoing', 'serializing', '1', '连载中', '更新中'].indexOf(value) >= 0) return 'ongoing';
  if (total > 0 && current >= total) return 'finished';
  if (current > 0) return 'ongoing';
  return '';
}

function sourceKeyOf(node) {
  var id = text(node, 'duanjuId', 'duanju_id', 'id');
  if (id === '') return '';
  var source = text(node, 'source');
  return source === '' ? id : id + '#' + source;
}

function dramaOf(node) {
  var key = sourceKeyOf(node);
  if (key === '') return null;
  var tags = stringList(node.categories);
  return {
    id: host.dramaId(key),
    source: sourceId,
    sourceId: key,
    title: text(node, 'title', 'name'),
    name: text(node, 'title', 'name'),
    intro: text(node, 'description', 'desc', 'intro'),
    cover: coverOf(node),
    episodeCount: intValue(node.total !== undefined ? node.total : node.totalEpisodeNum),
    category: csv(tags),
    tags: tags,
    channelName: sourceName
  };
}

// 拉取接口 JSON：运行时基址优先，异常直接上抛（无多域名回退需求）。
function requestJSON(path) {
  var response = host.fetch({
    method: 'GET',
    url: baseUrl + path,
    headers: {
      'User-Agent': userAgent,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer
    },
    timeoutMs: 15000,
    limit: 4 << 20
  });
  if (!response) throw new Error('饭果请求失败');
  if (response.status < 200 || response.status >= 300) {
    throw new Error('饭果 HTTP ' + response.status);
  }
  var decoded;
  try {
    decoded = JSON.parse(response.body);
  } catch (error) {
    throw new Error('饭果返回的数据格式无效');
  }
  return decoded;
}

function searchList(keyword) {
  var query = [
    'reqType=search',
    'offset=0',
    'keyword=' + encodeURIComponent(keyword),
    'quickEngineVersion=-1',
    'scene='
  ].join('&');
  var response = requestJSON('/xifan/search/getSearchList?' + query);
  var result = response && response.result ? response.result : {};
  var items = [];
  var seen = {};
  var elements = Array.isArray(result.elements) ? result.elements : [];
  for (var i = 0; i < elements.length; i++) {
    var contents = Array.isArray(elements[i].contents) ? elements[i].contents : [];
    for (var j = 0; j < contents.length; j++) {
      var drama = dramaOf(contents[j].duanjuVo);
      if (!drama || drama.id === '' || seen[drama.id]) continue;
      seen[drama.id] = true;
      items.push(drama);
    }
  }
  return items;
}

function catalogPage(pageNumber, category) {
  if (pageNumber > 1) return { items: [], hasMore: false };
  var keyword = trim(category) || defaultKeyword;
  return { items: searchList(keyword), hasMore: false };
}

function search(pageNumber, query) {
  if (pageNumber > 1) return { items: [], hasMore: false };
  return { items: searchList(trim(query)), hasMore: false };
}

function detail(sourceID) {
  var id = trim(sourceID);
  var duanjuID = id;
  var source = '';
  var cut = id.indexOf('#');
  if (cut >= 0) {
    duanjuID = id.slice(0, cut);
    source = id.slice(cut + 1);
  }
  if (duanjuID === '') throw new Error('饭果剧集 ID 无效');
  var query = 'duanjuId=' + encodeURIComponent(duanjuID) + '&source=' + encodeURIComponent(source);
  var response = requestJSON('/xifan/drama/getDuanjuInfo?' + query);
  var data = response && response.result ? response.result : null;
  if (!data || typeof data !== 'object') throw new Error('饭果未返回剧集资料');
  var tags = stringList(data.categories);
  var drama = {
    id: host.dramaId(id),
    source: sourceId,
    sourceId: id,
    title: text(data, 'title', 'name'),
    name: text(data, 'title', 'name'),
    intro: text(data, 'description', 'desc', 'intro'),
    cover: coverOf(data),
    category: csv(tags),
    tags: tags,
    channelName: sourceName,
    releaseStatus: releaseStatus(data.updateStatus, intValue(data.total), intValue(data.current))
  };
  var chapters = [];
  var episodes = Array.isArray(data.episodeList) ? data.episodeList : [];
  for (var i = 0; i < episodes.length; i++) {
    var node = episodes[i];
    if (!node || typeof node !== 'object') continue;
    var videoUrl = text(node, 'playUrl', 'play_url', 'videoUrl');
    if (videoUrl === '') continue;
    var number = intValue(node.index !== undefined ? node.index : (node.episode !== undefined ? node.episode : node.sort));
    if (number <= 0) number = i + 1;
    var title = text(node, 'title', 'name') || ('第' + number + '集');
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
  if (chapters.length === 0) throw new Error('饭果未返回可播放分集');
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  return { drama: drama, chapters: chapters };
}

module.exports = {
  categories: function () { return categories; },
  catalogPage: catalogPage,
  detail: detail,
  search: search
};
