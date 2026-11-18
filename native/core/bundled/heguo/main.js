// 河果（heguo）站源模块 —— 按上游 guoapp-modules 写法实现。
// 站点是 Next.js 页面：目录/详情数据都在 <script id="__NEXT_DATA__"> 的
// props.pageProps 里；搜索是独立的 POST JSON 接口。与内置 Go 实现
// native/sources/heguo 语义一致，并按真网现状修正两处：
//  1) 分集集号用 chapterIndex（Go 版只找 chapterNum/sort/index，靠顺序兜底）；
//  2) 详情 chapterList[].chapterVideoVo 自带 mp4/m3u8 直链，直接下发分集，
//     播放不依赖已失效的 /episode/ 分集页（那里 chapterInfo 已空）。

var sourceId = host.source;
var meta = host.manifest() || {};
var sourceName = meta.name || sourceId;
var defaultBase = 'https://www.kuaikaw.cn';
var siteBaseUrl = (host.baseUrl && host.baseUrl()) || meta.base || meta.baseUrl || defaultBase;
var referer = meta.referer || siteBaseUrl + '/';

var searchPath = '/seo/video/6007';
var searchSourceType = 1;
var searchPName = 'www.kuaikaw.cn';

var nextDataPattern = /<script id="__NEXT_DATA__" type="application\/json">([\s\S]*?)<\/script>/;
var mediaPattern = /(https?:\/\/[^"'\s<>\\]+\.(?:mp4|m3u8)[^"'\s<>\\]*)/i;

// 对齐 Go 的 10 个固定分类。
var builtinCategories = [
  { id: '462', name: '甜宠' },
  { id: '1102', name: '古装仙侠' },
  { id: '1145', name: '现代言情' },
  { id: '1170', name: '青春' },
  { id: '585', name: '豪门恩怨' },
  { id: '417-464', name: '逆袭' },
  { id: '439-465', name: '重生' },
  { id: '1159', name: '系统' },
  { id: '1147', name: '总裁' },
  { id: '943', name: '职场商战' }
];

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

function listOf(node, key) {
  if (!node || typeof node !== 'object') return [];
  var value = node[key];
  return Object.prototype.toString.call(value) === '[object Array]' ? value : [];
}

function mapOf(node, key) {
  if (!node || typeof node !== 'object') return null;
  var value = node[key];
  return value && typeof value === 'object' ? value : null;
}

function stringList(value) {
  if (!value) return [];
  var out = [];
  if (Object.prototype.toString.call(value) === '[object Array]') {
    for (var i = 0; i < value.length; i++) {
      var entry = value[i];
      var item = trim(typeof entry === 'object' && entry !== null
        ? (entry.name || entry.title || entry.class_name || '')
        : entry);
      if (item !== '' && out.indexOf(item) < 0) out.push(item);
    }
    return out;
  }
  var raw = trim(value);
  if (raw === '') return [];
  var parts = raw.split(/[,，、|]+/);
  for (var k = 0; k < parts.length; k++) {
    var part = parts[k].trim();
    if (part !== '' && out.indexOf(part) < 0) out.push(part);
  }
  return out;
}

function releaseStatus(status, total) {
  var value = trim(status);
  if (/完结|已完|全本|finished|completed|over/i.test(value)) return 'finished';
  if (/连载|更新中|ongoing|serializing/i.test(value)) return 'ongoing';
  return 'finished';
}

function formatCount(value) {
  return value > 0 ? String(value) + '集' : '';
}

function fetchBody(address, method, body, headers) {
  var request = {
    method: method || 'GET',
    url: address,
    headers: headers || {},
    timeoutMs: 20000,
    limit: 8 << 20
  };
  if (body !== undefined && body !== null) request.body = body;
  var response = host.fetch(request);
  if (!response) throw new Error('河果请求失败');
  if (response.status < 200 || response.status >= 300) throw new Error('河果 HTTP ' + response.status);
  return response.body || '';
}

// 从 HTML 里取 __NEXT_DATA__.props.pageProps。
function pageProps(body) {
  var matched = nextDataPattern.exec(body);
  if (!matched || !matched[1]) return null;
  var decoded;
  try {
    decoded = JSON.parse(matched[1]);
  } catch (error) {
    return null;
  }
  var props = mapOf(decoded, 'props');
  return mapOf(props, 'pageProps') || {};
}

function nextPage(address) {
  var body = fetchBody(address, 'GET', null, { 'Referer': referer });
  var props = pageProps(body);
  if (!props) throw new Error('河果页面结构无法识别');
  return { body: body, props: props };
}

function dramaFromBook(book) {
  var id = text(book, 'bookId', 'book_id', 'id');
  if (id === '') return null;
  var status = text(book, 'statusDesc', 'status');
  var total = intValue(book.totalChapterNum !== undefined ? book.totalChapterNum : book.total_chapter_num);
  var remark = (status + ' ' + formatCount(total)).trim();
  var tags = stringList(book.categoryList || book.bookTypeThree);
  return {
    id: host.dramaId(id),
    source: sourceId,
    sourceId: id,
    title: text(book, 'bookName', 'title', 'name'),
    name: text(book, 'bookName', 'title', 'name'),
    intro: text(book, 'introduction', 'intro', 'description'),
    cover: text(book, 'coverWap', 'cover', 'coverUrl'),
    remark: remark,
    episodeCount: total,
    releaseStatus: releaseStatus(status, total),
    category: tags.join(', '),
    tags: tags,
    channelName: sourceName
  };
}

// 对齐 Go 的 books：bannerList + bookList + recommendList + seoColumnVos[].bookInfos，按 ID 去重。
function collectBooks(props) {
  var rows = [];
  var direct = ['bannerList', 'bookList', 'recommendList'];
  for (var d = 0; d < direct.length; d++) {
    var group = listOf(props, direct[d]);
    for (var i = 0; i < group.length; i++) rows.push(group[i]);
  }
  var columns = listOf(props, 'seoColumnVos');
  for (var c = 0; c < columns.length; c++) {
    var infos = listOf(columns[c], 'bookInfos');
    for (var j = 0; j < infos.length; j++) rows.push(infos[j]);
  }
  var items = [];
  var seen = {};
  for (var k = 0; k < rows.length; k++) {
    var book = rows[k];
    if (!book || typeof book !== 'object') continue;
    var drama = dramaFromBook(book);
    if (!drama || drama.id === '' || seen[drama.id]) continue;
    seen[drama.id] = true;
    items.push(drama);
  }
  return items;
}

function categories() {
  return builtinCategories;
}

function catalogPage(pageNumber, category) {
  var page = pageNumber > 0 ? pageNumber : 1;
  var address = siteBaseUrl.replace(/\/+$/, '') + '/';
  var classID = trim(category);
  if (classID !== '') {
    address = siteBaseUrl.replace(/\/+$/, '') + '/browse/' + encodeURIComponent(classID) + '/' + page;
  }
  var result = nextPage(address);
  var props = result.props;
  var items = collectBooks(props);
  var totalPages = intValue(props.pages);
  var current = intValue(props.page);
  if (current <= 0) current = page;
  return { items: items, hasMore: totalPages > current };
}

function detail(sourceID) {
  var id = trim(sourceID);
  if (id === '') throw new Error('河果剧集 ID 无效');
  var address = siteBaseUrl.replace(/\/+$/, '') + '/drama/' + encodeURIComponent(id);
  var result = nextPage(address);
  var props = result.props;
  var book = mapOf(props, 'bookInfoVo');
  if (!book) throw new Error('河果未返回剧集资料');
  var drama = dramaFromBook(book) || {};
  drama.id = host.dramaId(id);
  drama.source = sourceId;
  drama.sourceId = id;
  drama.channelName = sourceName;
  var cats = stringList(book.categoryList || book.bookTypeThree);
  drama.category = cats.join(', ');
  drama.tags = cats;

  var rows = listOf(props, 'chapterList');
  var chapters = [];
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    var chapterID = text(row, 'chapterId', 'chapter_id', 'id');
    if (chapterID === '') continue;
    // 集号：真网新增 chapterIndex，Go 原候选 chapterNum/sort/index 一并兜底。
    var number = intValue(row.chapterIndex !== undefined ? row.chapterIndex
      : (row.chapterNum !== undefined ? row.chapterNum
        : (row.sort !== undefined ? row.sort : row.index)));
    if (number <= 0) number = i + 1;
    var title = text(row, 'chapterName', 'title');
    if (title === '') title = '第' + number + '集';
    var video = mapOf(row, 'chapterVideoVo') || {};
    var url = text(video, 'mp4720p', 'mp4', 'vodMp4Url', 'm3u8');
    var pageUrl = siteBaseUrl.replace(/\/+$/, '') + '/episode/' + encodeURIComponent(id) + '/' + encodeURIComponent(chapterID);
    chapters.push({
      id: host.dramaId(id) + ':' + number,
      source: sourceId,
      title: title,
      currentEpisode: number,
      videoUrl: url,
      pageUrl: pageUrl,
      referer: referer
    });
  }
  if (chapters.length === 0) throw new Error('河果未返回可播放分集');
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  drama.episodeCount = chapters.length;
  return { drama: drama, chapters: chapters };
}

function search(pageNumber, query) {
  var keyword = trim(query);
  if (keyword === '') return { items: [], hasMore: false };
  var body = JSON.stringify({ sourceType: searchSourceType, keyword: keyword, index: 1 });
  var raw = fetchBody(siteBaseUrl.replace(/\/+$/, '') + searchPath, 'POST', body, {
    'Content-Type': 'application/json',
    'pname': searchPName,
    'Referer': referer
  });
  var response;
  try {
    response = JSON.parse(raw);
  } catch (error) {
    throw new Error('河果搜索返回的数据格式无效');
  }
  var data = mapOf(response, 'data') || {};
  var items = [];
  var rows = listOf(data, 'bookList');
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var drama = dramaFromBook(rows[i]);
    if (!drama || drama.id === '' || seen[drama.id]) continue;
    seen[drama.id] = true;
    items.push(drama);
  }
  return { items: items, hasMore: false };
}

function resolveMedia(task) {
  var chapter = task && task.chapter ? task.chapter : {};
  var address = trim(chapter.videoUrl);
  var pageReferer = trim(chapter.referer) || referer;
  if (address === '') {
    var pageUrl = trim(chapter.pageUrl);
    if (pageUrl === '') throw new Error('河果分集缺少播放页面，请刷新详情后重试');
    var body = fetchBody(pageUrl, 'GET', null, { 'Referer': referer });
    var props = pageProps(body);
    if (props) {
      var info = mapOf(props, 'chapterInfo');
      var video = info ? mapOf(info, 'chapterVideoVo') : null;
      if (video) address = text(video, 'mp4720p', 'mp4', 'vodMp4Url', 'm3u8');
    }
    if (address === '') {
      // 正文里的直链可能是明文 https:// 或转义 https:\/\/；先归一化再匹配。
      var normalized = body.replace(/\\\//g, '/');
      var matched = mediaPattern.exec(normalized);
      if (matched && matched[1]) address = matched[1];
    }
  }
  if (address === '') throw new Error('河果未返回有效播放地址，请刷新章节后重试');
  return host.prepareWebMedia({ url: address, referer: pageReferer }, sourceName);
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search,
  resolveMedia: resolveMedia
};
