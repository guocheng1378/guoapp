// maccms 采集站通用实现（内置模块族用）。
//
// 站点差异（基址、分类、成人标记等）写在模块清单的 config 段，
// 运行时通过 host.manifest() 读取；本文件只实现协议本身：
// 目录（分类 / 分页列表）、详情（分集线路）、搜索。
//
// 与内置 Go 实现（native/sources/maccmsapi）语义保持一致：
//   - 分类来自源站 type 列表，按固定顺序排列，未知分类按名称排序；
//   - 详情里若存在直链线路，只保留直链线路（网页线路交给核心通用解析）；
//   -  vod_time / vod_duration / vod_score 等松散字段按容错规则归一。

var cfg = (function () {
  var manifest = host.manifest() || {};
  return manifest.config || {};
})();

var sourceId = host.source;
var sourceName = (host.manifest() || {}).name || sourceId;

var TYPE_ORDER = [
  '12', '13', '14', '15', '16', '21', '22', '24', '25', '26', '27', '28', '29', '30',
  '5', '6', '7', '8', '9', '10', '11', '20'
];

function trim(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return '';
}

function idString(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'number') return String(Math.trunc(value));
  if (typeof value === 'string') return value.trim();
  return '';
}

function decodeEntities(value) {
  return String(value || '')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#0*39;/gi, "'")
    .replace(/&apos;/gi, "'");
}

function stripHTML(value) {
  var text = String(value === null || value === undefined ? '' : value).replace(/<[^>]+>/g, '');
  text = decodeEntities(text);
  return text.replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
}

function truncate(value, limit) {
  var text = String(value || '');
  if (text.length <= limit) return text;
  return text.slice(0, limit) + '...';
}

function formatDate(date) {
  if (!date || isNaN(date.getTime())) return '';
  var month = date.getMonth() + 1;
  var day = date.getDate();
  return date.getFullYear() + '-' + (month < 10 ? '0' + month : String(month)) +
    '-' + (day < 10 ? '0' + day : String(day));
}

// vod_time：unix 秒或 "2006-01-02 15:04:05"，非法值返回空串（让日期排序保持置灰）。
function onlineDate(raw) {
  var value = trim(raw);
  if (!value || value === 'null') return '';
  if (/^\d+$/.test(value)) {
    var seconds = parseInt(value, 10);
    if (seconds <= 0 || seconds < 1000000000) return '';
    return formatDate(new Date(seconds * 1000));
  }
  if (value.length >= 10 && /^\d{4}-\d{2}-\d{2}/.test(value)) return value.slice(0, 10);
  return '';
}

// vod_duration：数字秒 / "45:12" / "1:05:30"，无法识别返回 0。
function durationSeconds(raw) {
  var value = trim(raw);
  if (!value || value === 'null') return 0;
  if (/^-?\d+(\.\d+)?$/.test(value)) return parseFloat(value);
  var parts = value.split(':');
  if (parts.length < 2 || parts.length > 3) return 0;
  var total = 0;
  for (var i = 0; i < parts.length; i++) {
    var piece = parseFloat(String(parts[i]).trim());
    if (isNaN(piece) || piece < 0) return 0;
    total = total * 60 + piece;
  }
  return total;
}

function actorList(raw) {
  var value = trim(raw);
  if (!value) return [];
  var pieces = value.split(/[,，、\/|]/);
  var out = [];
  for (var i = 0; i < pieces.length; i++) {
    var name = pieces[i].trim();
    if (!name) continue;
    out.push(name);
    if (out.length >= 8) break;
  }
  return out;
}

function releaseStatus(raw) {
  var value = trim(raw).toLowerCase();
  if (['over', 'finished', 'completed', '2', '已完结', '完结'].indexOf(value) >= 0) return 'finished';
  if (['ongoing', 'serializing', '1', '连载中', '更新中'].indexOf(value) >= 0) return 'ongoing';
  return '';
}

function looksLikeMedia(address) {
  var lower = String(address || '').toLowerCase();
  return lower.indexOf('.m3u8') >= 0 || lower.indexOf('.mp4') >= 0 || lower.indexOf('.flv') >= 0;
}

function firstMediaURL(play) {
  var pieces = String(play || '').split(/[$#]/);
  var kept = [];
  for (var i = 0; i < pieces.length; i++) {
    if (pieces[i].trim() !== '') kept.push(pieces[i].trim());
  }
  return kept.length > 1 ? kept[1] : '';
}

function baseCandidates() {
  var manifest = host.manifest() || {};
  var list = [];
  var primary = String(host.baseUrl() || '').replace(/\/+$/, '');
  var builtin = String(manifest.base || '').replace(/\/+$/, '');
  if (primary) list.push(primary);
  if (builtin && builtin !== primary) list.push(builtin);
  return list;
}

function requestText(url, referer) {
  var response = host.fetch({
    url: url,
    headers: {
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer
    }
  });
  if (!response) throw new Error('请求失败');
  if (response.status < 200 || response.status >= 300) {
    throw new Error('HTTP ' + response.status);
  }
  return response.body;
}

// 拉取接口 JSON：按「运行时基址 → 内置基址」顺序回退，返回 { json, base }。
function fetchJSON(path) {
  var candidates = baseCandidates();
  var failures = [];
  for (var i = 0; i < candidates.length; i++) {
    var base = candidates[i];
    try {
      var body = requestText(base + path, base + '/');
      return { json: JSON.parse(body), base: base };
    } catch (error) {
      failures.push(error && error.message ? error.message : String(error));
    }
  }
  throw new Error(failures.join('；') || '请求失败');
}

function dramaOf(item, introLimit) {
  var id = idString(item.vod_id);
  if (!id) return null;
  var title = trim(item.vod_name);
  var intro = truncate(stripHTML(item.vod_content), introLimit);
  var remark = trim(item.vod_remarks);
  var cover = trim(item.vod_pic);
  return {
    id: sourceId + ':' + id,
    source: sourceId,
    sourceId: id,
    title: title,
    name: title,
    desc: intro,
    intro: intro,
    cover: cover,
    coverUrl: cover,
    categoryName: trim(item.type_name),
    remark: remark,
    releaseStatus: releaseStatus(remark),
    onlineDate: onlineDate(item.vod_time),
    area: trim(item.vod_area),
    year: trim(item.vod_year),
    score: trim(item.vod_score),
    duration: durationSeconds(item.vod_duration),
    actors: actorList(item.vod_actor),
    channelName: sourceName
  };
}

function dramaList(list, introLimit) {
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var drama = dramaOf(list[i], introLimit);
    if (drama) out.push(drama);
  }
  return out;
}

function pageCountOf(decoded) {
  var count = parseInt(decoded && decoded.pagecount, 10);
  return isNaN(count) || count < 0 ? 0 : count;
}

function categories(force) {
  var seen = {};
  var keys = [];
  for (var page = 1; page <= 2; page++) {
    var result = fetchJSON('/api.php/provide/vod/?ac=list&pg=' + page);
    var list = (result.json && result.json.list) ? result.json.list : [];
    for (var i = 0; i < list.length; i++) {
      var typeId = idString(list[i].type_id);
      if (!typeId || seen[typeId] !== undefined) continue;
      seen[typeId] = trim(list[i].type_name);
      keys.push(typeId);
    }
    if (page >= pageCountOf(result.json)) break;
  }
  keys.sort(function (left, right) {
    var leftIndex = TYPE_ORDER.indexOf(left);
    var rightIndex = TYPE_ORDER.indexOf(right);
    if (leftIndex >= 0 && rightIndex >= 0) return leftIndex - rightIndex;
    if (leftIndex >= 0) return -1;
    if (rightIndex >= 0) return 1;
    if (seen[left] === seen[right]) return left < right ? -1 : (left > right ? 1 : 0);
    return seen[left] < seen[right] ? -1 : 1;
  });
  var out = [{ id: '', name: '全部' }];
  for (var i = 0; i < keys.length; i++) {
    out.push({ id: keys[i], name: seen[keys[i]] });
  }
  return out;
}

function catalogPage(page, category) {
  var current = parseInt(page, 10);
  if (isNaN(current) || current < 1) current = 1;
  var type = trim(category);
  var path = '/api.php/provide/vod/?ac=list';
  if (type) path += '&t=' + encodeURIComponent(type);
  path += '&pg=' + current;
  var result = fetchJSON(path);
  var decoded = result.json || {};
  var list = decoded.list || [];
  var code = parseInt(decoded.code, 10);
  if (!list.length && (isNaN(code) || code !== 1)) throw new Error('maccms-api 无数据');
  return { items: dramaList(list, 500), hasMore: current < pageCountOf(decoded) };
}

function detail(sourceID) {
  var id = trim(sourceID);
  var prefix = sourceId + ':';
  if (id.indexOf(prefix) === 0) id = id.slice(prefix.length);
  var result = fetchJSON('/api.php/provide/vod/?ac=detail&ids=' + encodeURIComponent(id));
  var list = (result.json && result.json.list) ? result.json.list : [];
  if (!list.length) throw new Error('maccms-api detail 无数据');
  var item = list[0];
  var vodId = idString(item.vod_id);
  var fromList = String(item.vod_play_from || '').split('$$$');
  var urlList = String(item.vod_play_url || '').split('$$$');
  var lines = [];
  for (var i = 0; i < fromList.length && i < urlList.length; i++) {
    lines.push({ direct: looksLikeMedia(firstMediaURL(urlList[i])) });
  }
  var hasDirect = false;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].direct) { hasDirect = true; break; }
  }
  var chapters = [];
  for (var i = 0; i < lines.length; i++) {
    if (hasDirect && !lines[i].direct) continue;
    var pieces = String(urlList[i] || '').split(/[$#]/);
    var clean = [];
    for (var j = 0; j < pieces.length; j++) {
      if (pieces[j].trim() !== '') clean.push(pieces[j].trim());
    }
    for (var j = 0; j + 1 < clean.length; j += 2) {
      var episodeURL = clean[j + 1];
      if (!episodeURL) continue;
      var chapter = {
        id: sourceId + ':' + vodId + ':' + (chapters.length + 1),
        source: sourceId,
        title: clean[j],
        currentEpisode: chapters.length + 1,
        referer: result.base + '/'
      };
      if (lines[i].direct) chapter.videoUrl = episodeURL;
      else chapter.pageUrl = episodeURL;
      chapters.push(chapter);
    }
  }
  var drama = dramaOf(item, 2000) || {};
  return { drama: drama, chapters: chapters };
}

function search(page, query) {
  var current = parseInt(page, 10);
  if (isNaN(current) || current < 1) current = 1;
  var keyword = trim(query);
  if (!keyword) throw new Error('搜索词不能为空');
  var result = fetchJSON('/api.php/provide/vod/?ac=list&wd=' + encodeURIComponent(keyword) + '&pg=' + current);
  var decoded = result.json || {};
  var list = decoded.list || [];
  return { items: dramaList(list, 500), hasMore: current < pageCountOf(decoded) };
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search
};
