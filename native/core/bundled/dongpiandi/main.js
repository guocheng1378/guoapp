// 真果·鉴 · H5 聚合站协议实现（JS 模块化移植）
//
// 平台对 /v1/* 请求做 HMAC-SHA256 签名：
//   payload = `${METHOD}\n${pathWithQuery}\n${timestamp}\n${nonce}`
//   signature = hex(HMAC-SHA256(KEY, payload))
// 固定请求头：x-ai-movie-timestamp/nonce/signature/site-host。
// 官方线的 resolve:// 票据需匿名会话（POST /v1/users/anonymous 的 set-cookie）
// 后再 POST /v1/playback/resolve-line?view=full 兑换真实直链。

var SIGN_KEY = '8b9a908a05eac640e1ee06f52acaa741bfe4ba9e004eeffdbeb635e532e06666';
var SITE_HOST = 'dongpiandi.ai';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15';
var CHANNEL = '真果·鉴';
var PAGE_SIZE = 20;
var ANON_STATE = 'dp.anon';
var COOKIE_STATE = 'dp.cookie';
var LINE_TTL_MS = 20 * 60 * 1000;
var LINE_STATE_PREFIX = 'dp.lines.';

var lineCache = {};       // episodeID -> { lines, tickets, at, complete }
var ticketCache = {};     // episodeID -> resolve:// ticket line
var anonReady = false;
var anonTried = false;

// ---------------------------------------------------------------- 基础工具

function trim(value) {
  return value === null || value === undefined ? '' : String(value).trim();
}

function text(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  return String(value);
}

function clampInt(value, fallback) {
  var n = parseInt(value, 10);
  return isNaN(n) ? fallback : n;
}

function listOf(value) {
  return Object.prototype.toString.call(value) === '[object Array]' ? value : [];
}

function truncate(value, max) {
  var s = text(value);
  var count = 0;
  for (var i = 0; i < s.length; i++) {
    count++;
    if (count > max) return s.slice(0, i);
  }
  return s;
}

function escapePath(value) {
  try { return encodeURIComponent(trim(value)); } catch (e) { return trim(value); }
}

function queryString(params) {
  var keys = [];
  for (var key in params) {
    if (Object.prototype.hasOwnProperty.call(params, key) && params[key] !== undefined && params[key] !== null && params[key] !== '') {
      keys.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(params[key])));
    }
  }
  return keys.length ? keys.join('&') : '';
}

function numberFrom(value, fallback) {
  if (value === null || value === undefined || value === '') return fallback;
  var n = parseFloat(value);
  return isNaN(n) ? fallback : n;
}

// ---------------------------------------------------------------- 请求与签名

function baseURL() {
  var manifest = host.manifest();
  var base = manifest && (manifest.base || manifest.baseUrl);
  return trim(base) || ('https://' + SITE_HOST);
}

function nonceHex() {
  return host.hexEncode(host.randomBytes(16));
}

function sign(method, pathWithQuery, ts, nonce) {
  var payload = method + '\n' + pathWithQuery + '\n' + ts + '\n' + nonce;
  return host.hexEncode(host.hmacSha256(host.utf8Encode(SIGN_KEY), host.utf8Encode(payload)));
}

// 从 set-cookie 头里抽 cookie 对（name=value），累积到已保存的 cookie jar。
function absorbCookie(headerValue) {
  if (!headerValue) return;
  var pair = trim(headerValue).split(';')[0];
  if (pair.indexOf('=') < 0) return;
  var name = pair.slice(0, pair.indexOf('=')).trim();
  var jar = loadCookie();
  jar[name] = pair;
  saveCookie(jar);
}

function cookieHeader() {
  var jar = loadCookie();
  var parts = [];
  for (var name in jar) {
    if (Object.prototype.hasOwnProperty.call(jar, name)) parts.push(jar[name]);
  }
  return parts.join('; ');
}

function loadCookie() {
  try {
    var raw = host.loadState(COOKIE_STATE);
    return raw ? JSON.parse(raw) : {};
  } catch (e) { return {}; }
}

function saveCookie(jar) {
  try { host.saveState(COOKIE_STATE, JSON.stringify(jar)); } catch (e) { /* 忽略 */ }
}

// request(method, path, params, body, withCookie) -> { status, body, headers }
// 统一构造签名头、UA、Origin/Referer；带 cookie 时附加匿名会话。
function request(method, path, params, body, withCookie) {
  var full = path;
  var query = params ? queryString(params) : '';
  if (query !== '') full += '?' + query;
  var ts = String(Date.now());
  var nonce = nonceHex();
  var sig = sign(method.toUpperCase(), full, ts, nonce);
  var headers = {
    'x-ai-movie-timestamp': ts,
    'x-ai-movie-nonce': nonce,
    'x-ai-movie-signature': sig,
    'x-ai-movie-site-host': SITE_HOST,
    'Accept': 'application/json',
    'User-Agent': UA,
    'Origin': baseURL(),
    'Referer': baseURL() + '/'
  };
  if (body !== undefined && body !== null) headers['Content-Type'] = 'application/json';
  if (withCookie) {
    var cookie = cookieHeader();
    if (cookie !== '') headers['Cookie'] = cookie;
  }
  var options = {
    method: method.toUpperCase(),
    url: baseURL() + full,
    headers: headers,
    timeoutMs: 15000,
    limit: 8 << 20,
    anyStatus: true,
    followRedirects: true
  };
  if (body !== undefined && body !== null) {
    options.body = typeof body === 'string' ? body : JSON.stringify(body);
  }
  var response = host.fetchText(options);
  if (!response) throw new Error('真果·鉴：请求无响应');
  var responseHeaders = response.headers || {};
  var setCookie = responseHeaders['set-cookie'] || responseHeaders['Set-Cookie'];
  if (setCookie) absorbCookie(setCookie);
  var status = parseInt(response.status, 10) || 0;
  if (status < 200 || status >= 300) {
    throw new Error('真果·鉴：HTTP ' + status + ' ' + truncate(response.body, 200));
  }
  var parsed = null;
  try { parsed = JSON.parse(host.preserveIntegers ? host.preserveIntegers(response.body) : response.body); }
  catch (e) { throw new Error('真果·鉴：响应不是合法 JSON'); }
  return parsed;
}

function apiGet(path, params, withCookie) {
  return request('GET', path, params, null, withCookie);
}

function apiPost(path, body, withCookie) {
  return request('POST', path, null, body, withCookie);
}

// 匿名会话：官方线兑换要求服务端会话。惰性建号一次，失败不固化（下次重试）。
function ensureAnonymous() {
  if (anonReady) return true;
  if (anonTried && !anonReady) return false;
  anonTried = true;
  try {
    var aid = host.hexEncode(host.randomBytes(8));
    apiPost('/v1/users/anonymous', { anonymous_id: 'web_' + aid }, false);
    anonReady = true;
    return true;
  } catch (e) {
    return false;
  }
}

// ---------------------------------------------------------------- 字段映射

function kindLabel(kind) {
  switch (text(kind)) {
    case 'short_drama': return '短剧';
    case 'series': return '电视剧';
    case 'movie': return '电影';
    case 'anime': return '动画';
    case 'variety': return '综艺';
    default: return '影视';
  }
}

function contentKind(kind) {
  switch (text(kind).toLowerCase()) {
    case 'short_drama': return 'short';
    case 'series':
    case 'movie':
    case 'anime':
    case 'variety': return 'long';
    default: return '';
  }
}

function releaseStatus(status, completed, progress) {
  switch (text(status).toLowerCase()) {
    case 'completed':
    case 'finished':
    case 'over':
    case 'ended': return 'finished';
    case 'ongoing':
    case 'serializing':
    case 'updating':
    case 'airing': return 'ongoing';
  }
  if (completed) return 'finished';
  var mark = text(progress);
  if (mark.indexOf('全') >= 0 && mark.indexOf('集') >= 0) return 'finished';
  if (mark.indexOf('更新至') >= 0 || mark.indexOf('连载') >= 0) return 'ongoing';
  return 'unknown';
}

// 从「更新至N集 / 全N集 / 第N集」文案抽集数。
function calendarEpisode(mark) {
  var m = text(mark).match(/(\d+)\s*集/);
  return m ? parseInt(m[1], 10) : 0;
}

function scoreText(value) {
  if (typeof value === 'number') {
    if (value > 0 && value <= 10) return value.toFixed(1);
    if (value > 0 && value <= 100) return String(Math.round(value));
  }
  var s = text(value);
  return s !== '' ? s : '';
}

function heatText(value) {
  var n = numberFrom(value, 0);
  if (n <= 0) return '';
  if (n >= 1e8) return (n / 1e8).toFixed(1) + '亿热度';
  if (n >= 1e4) return (n / 1e4).toFixed(1) + '万热度';
  return String(Math.floor(n)) + '热度';
}

function isExtraEpisode(episode) {
  var row = episode || {};
  var track = text(row.episode_track).toLowerCase();
  if (track === 'main') return false;
  if (track === 'extras') return true;
  var key = text(row.key).toLowerCase();
  return key.indexOf('special-') === 0 || key.indexOf('part-') === 0 || text(row.title).indexOf('彩蛋') >= 0;
}

function extraCount(episodes) {
  var count = 0;
  for (var i = 0; i < episodes.length; i++) if (isExtraEpisode(episodes[i])) count++;
  return count;
}

function trimExtras(total, episodes) {
  var extra = extraCount(episodes);
  if (extra <= 0 || episodes.length < total || total <= extra) return total;
  var trimmed = total - extra;
  var main = episodes.length - extra;
  if (trimmed < main) trimmed = main;
  if (trimmed > total) trimmed = total;
  return trimmed;
}

// 短剧批次：key=range-0001-0020 / title=第1-20集 → 批次覆盖的最大集号。
function batchTotal(episodes) {
  var best = 0;
  for (var i = 0; i < episodes.length; i++) {
    var ep = episodes[i] || {};
    var source = text(ep.key) + ' ' + text(ep.title);
    var m = source.match(/(\d{1,5})\s*[-~至]\s*(\d{1,5})/);
    if (m) {
      var hi = parseInt(m[2], 10);
      if (hi > best) best = hi;
    }
  }
  return best;
}

function episodeNumber(value, fallback) {
  var n = numberFrom(value, 0);
  if (n > 0) return Math.floor(n);
  var m = text(value).match(/(\d{1,5})/);
  return m ? parseInt(m[1], 10) : fallback;
}

// 卡片集数：playback_groups[].episode_count 是权威，remarks 文案交叉校验。
// 短剧批次（episode_count >= 文案*2）信 episode_count；附加内容撑大则信文案。
function cardEpisodes(kind, groupEpisodes, remark) {
  var label = calendarEpisode(remark);
  if (label <= 0) return groupEpisodes;
  if (groupEpisodes <= 0 || label > groupEpisodes) return label;
  if (label === groupEpisodes) return groupEpisodes;
  if (text(kind).toLowerCase() === 'short_drama' && groupEpisodes >= label * 2) return groupEpisodes;
  return label;
}

function episodeCountFromCard(card) {
  var groups = listOf(card.playback_groups);
  var groupEpisodes = 0;
  for (var i = 0; i < groups.length; i++) {
    var e = numberFrom(groups[i] && groups[i].episode_count, 0);
    if (e > groupEpisodes) groupEpisodes = e;
  }
  return cardEpisodes(card.content_kind, groupEpisodes, card.remarks);
}

function buildTags(genres, area, year, remark, score) {
  var tags = [];
  var seen = {};
  function add(raw) {
    var s = trim(raw);
    if (s === '' || seen[s] || s.length > 48 || tags.length >= 16) return;
    seen[s] = true;
    tags.push(s);
  }
  var items = listOf(genres);
  for (var i = 0; i < items.length; i++) add(items[i]);
  if (trim(area) !== '') add(area);
  var y = numberFrom(year, 0);
  if (y > 0) add(String(Math.floor(y)) + '年');
  if (trim(remark) !== '') add(remark);
  if (trim(score) !== '') add('评分 ' + score);
  if (tags.length === 0) add('短剧');
  return tags;
}

function cardToDrama(card) {
  var row = card || {};
  var title = truncate(row.title || row.normalized_title, 256);
  if (title === '') return null;
  var id = trim(row.id);
  var score = scoreText(row.score);
  var cover = trim(row.poster_url);
  var episodes = episodeCountFromCard(row);
  return {
    id: host.dramaId(id),
    source: host.source,
    sourceId: id,
    title: title,
    name: title,
    cover: cover,
    coverUrl: cover,
    image: cover,
    pic: cover,
    poster: cover,
    tags: buildTags(row.genres, row.area, row.year, row.remarks, score),
    actors: listOf(row.actors),
    score: score,
    heat: heatText(row.heat_value),
    remark: text(row.remarks),
    episodeCount: episodes,
    totalEpisode: episodes,
    channelName: CHANNEL,
    category: kindLabel(row.content_kind),
    contentKind: contentKind(row.content_kind),
    releaseStatus: releaseStatus('', false, row.remarks),
    area: trim(row.area),
    year: numberFrom(row.year, 0) > 0 ? String(Math.floor(numberFrom(row.year, 0))) : ''
  };
}

function dramasFromResp(resp) {
  var rows = listOf(resp && resp.cards);
  var items = [];
  for (var i = 0; i < rows.length; i++) {
    var drama = cardToDrama(rows[i]);
    if (drama) items.push(drama);
  }
  return items;
}

// ---------------------------------------------------------------- 线路解析

function isDirectLine(line) {
  var row = line || {};
  var url = trim(row.url);
  if (url === '' || url.indexOf('resolve://') === 0) return false;
  if (row.url_kind === 'm3u8' || row.url_kind === 'mp4') return true;
  if (row.url_kind === 'page') return false;
  var lower = url.toLowerCase();
  if (lower.indexOf('.m3u8') >= 0 || lower.indexOf('.mp4') >= 0) return true;
  return lower.indexOf('http://') === 0 || lower.indexOf('https://') === 0;
}

function lineScore(line) {
  var row = line || {};
  var score = 0;
  if (row.official) score += 30000;
  if (row.selected) score += 5000;
  score += numberFrom(row.preference_weight, 0);
  if (row.url_kind === 'm3u8') score += 100;
  if (row.url_kind === 'mp4') score += 90;
  if (row.default_priority) score += 50;
  return score;
}

function lineLabel(line) {
  var row = line || {};
  var label = trim(row.label);
  if (label === '') label = trim(row.provider_name);
  if (label === '') label = trim(row.play_from);
  return label;
}

function lineQuality(label) {
  var s = text(label);
  for (var i = 0; i < s.length; i++) {
    if (s.charAt(i) !== 'p' && s.charAt(i) !== 'P') continue;
    var j = i - 1;
    var start = i;
    while (j >= 0 && s.charAt(j) >= '0' && s.charAt(j) <= '9') { start = j; j--; }
    var digits = s.slice(start, i);
    if (digits.length >= 3 && digits.length <= 4) {
      var value = parseInt(digits, 10);
      if (value >= 144 && value <= 4320) return value;
    }
  }
  return 0;
}

function lineToMedia(line) {
  var label = lineLabel(line);
  return {
    url: trim(line.url),
    referer: baseURL() + '/',
    label: label,
    quality: lineQuality(label),
    official: !!line.official
  };
}

// 兑换单条 resolve:// 票据线。失败返回 null（不连累同剧其它集）。
function redeemTicket(line) {
  var url = trim(line.url);
  if (url.indexOf('resolve://') !== 0) return null;
  var ticket = url.slice('resolve://'.length);
  if (ticket === '') return null;
  if (!ensureAnonymous()) return null;
  try {
    var ack = apiPost('/v1/playback/resolve-line?view=full', { ticket: ticket }, true);
    var redeemed = ack && ack.line;
    if (!redeemed) return null;
    var mediaUrl = trim(redeemed.url);
    if (mediaUrl === '' || mediaUrl.indexOf('resolve://') === 0) return null;
    var out = {};
    for (var key in redeemed) if (Object.prototype.hasOwnProperty.call(redeemed, key)) out[key] = redeemed[key];
    out.id = line.id;
    out.resolved = true;
    out.official = true;
    if (trim(out.label) === '') out.label = trim(line.label) || '官方线路';
    out.selected = line.selected;
    out.preference_weight = line.preference_weight;
    return out;
  } catch (e) {
    return null;
  }
}

// resolveLinesSet(episodeToken, full) -> { lines, tickets, redeemed, complete, ticketLines }
function resolveLinesSet(episodeToken, full) {
  var resp = apiGet('/v1/playback/resolve/' + escapePath(episodeToken), null, false);
  var options = listOf(resp && resp.line_options);
  var lines = [];
  var tickets = [];
  for (var i = 0; i < options.length; i++) {
    var line = options[i] || {};
    if (!line.resolved || trim(line.url) === '') {
      if (trim(line.url).indexOf('resolve://') === 0) tickets.push(line);
      continue;
    }
    if (!isDirectLine(line)) continue;
    line.official = false;
    lines.push(line);
  }
  var ticketLines = [];
  var redeemed = 0;
  var totalTickets = 0;
  if (tickets.length > 0) {
    var toRedeem = tickets;
    if (!full) {
      if (lines.length > 0) toRedeem = [];
      else if (tickets.length > 1) toRedeem = tickets.slice(0, 1);
    }
    totalTickets = toRedeem.length;
    for (var k = 0; k < toRedeem.length; k++) {
      ticketLines.push(toRedeem[k]);
      var done = redeemTicket(toRedeem[k]);
      if (done) { lines.push(done); redeemed++; }
    }
  }
  lines.sort(function (a, b) { return lineScore(b) - lineScore(a); });
  return {
    lines: lines,
    tickets: totalTickets,
    redeemed: redeemed,
    complete: totalTickets === 0 || redeemed >= totalTickets,
    ticketLines: ticketLines
  };
}

function cacheLines(episodeID, set) {
  if (!episodeID) return;
  lineCache[episodeID] = { set: set, at: Date.now() };
  try { host.saveState(LINE_STATE_PREFIX + episodeID, JSON.stringify(set)); } catch (e) { /* 忽略 */ }
}

function cachedLines(episodeID) {
  var hit = lineCache[episodeID];
  if (hit && Date.now() - hit.at < LINE_TTL_MS) return hit.set;
  try {
    var raw = host.loadState(LINE_STATE_PREFIX + episodeID);
    if (!raw) return null;
    var parsed = JSON.parse(raw);
    var storedAt = parsed._at || 0;
    if (Date.now() - storedAt >= LINE_TTL_MS) return null;
    lineCache[episodeID] = { set: parsed.set || parsed, at: storedAt };
    return parsed.set || parsed;
  } catch (e) { return null; }
}

// ---------------------------------------------------------------- 对外接口

var CATEGORIES = [
  { id: '', name: '全部' },
  { id: 'short_drama', name: '短剧' },
  { id: 'series', name: '电视剧' },
  { id: 'movie', name: '电影' },
  { id: 'anime', name: '动画' },
  { id: 'variety', name: '综艺' }
];

function categories() {
  return CATEGORIES;
}

function catalogPage(pageNumber, category, query) {
  var page = pageNumber > 0 ? pageNumber : 1;
  if (page > 100) return { items: [], hasMore: false };
  var params = { page: String(page), limit: String(PAGE_SIZE) };
  var kind = trim(category);
  var keyword = trim(query);
  if (kind !== '') params.kind = kind;
  else if (keyword !== '') params.q = keyword;
  var resp = apiGet('/v1/browse/catalog', params, false);
  var items = dramasFromResp(resp);
  var pagination = resp && resp.pagination ? resp.pagination : {};
  return { items: items, hasMore: !!pagination.has_more };
}

function detail(sourceID) {
  var id = trim(sourceID);
  if (id === '' || id.length > 256) throw new Error('真果·鉴剧集标识无效');
  var data = apiGet('/v1/catalog/' + escapePath(id), null, false);
  if (!data || trim(data.title) === '') throw new Error('真果·鉴返回的详情不完整');
  // 社区跳过预设随详情下发，缓存供播放期 skipPreset 读取（剧级常量）。
  var preset = data.playback_skip_settings_preset;
  if (preset && (numberFrom(preset.intro_end_seconds, 0) > 0 || numberFrom(preset.outro_from_end_seconds, 0) > 0)) {
  	try { host.cacheSet('dp.skip.' + id, JSON.stringify(preset), 86400000); } catch (e) { /* 忽略 */ }
  }

  var episodes = [];
  var seenEpisode = {};
  var rawEpisodes = listOf(data.episodes);
  for (var i = 0; i < rawEpisodes.length; i++) {
    var ep = rawEpisodes[i] || {};
    if (trim(ep.token) === '' || trim(ep.id) === '' || seenEpisode[ep.id]) continue;
    seenEpisode[ep.id] = true;
    episodes.push(ep);
  }

  var epCount = numberFrom(data.available_episode_count, 0);
  if (epCount <= 0) epCount = numberFrom(data.current_episode_count, 0);
  if (epCount <= 0) epCount = numberFrom(data.episode_count, 0);
  if (epCount <= 0) epCount = episodes.length - extraCount(episodes);
  var total = numberFrom(data.total_episode_count, 0);
  if (total <= 0) total = epCount;
  var batch = batchTotal(episodes);
  if (batch > total) total = batch;
  total = trimExtras(total, episodes);
  var status = releaseStatus(data.update_status, !!data.is_completed, data.episode_progress_text);
  var shown = batch > 0 ? total : (status === 'ongoing' && epCount > 0 ? epCount : total);

  var cover = trim(data.poster_url);
  var drama = {
    id: host.dramaId(id),
    source: host.source,
    sourceId: id,
    title: truncate(data.title, 256),
    name: truncate(data.title, 256),
    desc: truncate(data.description, 12000),
    intro: truncate(data.description, 12000),
    cover: cover,
    coverUrl: cover,
    image: cover,
    pic: cover,
    poster: cover,
    remark: text(data.episode_progress_text),
    tags: buildTags(data.genres, data.area, data.year, data.remarks, ''),
    actors: listOf(data.actors),
    channelName: CHANNEL,
    category: kindLabel(data.content_kind),
    contentKind: contentKind(data.content_kind),
    episodeCount: shown,
    totalEpisode: shown,
    releaseStatus: status
  };

  var chapters = [];
  for (var c = 0; c < episodes.length; c++) {
    var episode = episodes[c];
    var num = episodeNumber(episode.number, c + 1);
    var title = trim(episode.title) || ('第' + num + '集');
    var chapter = {
      id: host.chapterId(id, String(episode.id)),
      source: host.source,
      title: title,
      currentEpisode: num,
      videoUrl: '',
      pageUrl: baseURL() + '/player/' + escapePath(id),
      referer: baseURL() + '/',
      episodeId: trim(episode.id),
      token: trim(episode.token)
    };
    // 首集全量解析，保证详情默认地址落在官方线。
    if (c === 0 && trim(episode.token) !== '') {
      try {
        var set = resolveLinesSet(episode.token, true);
        if (set.lines.length > 0) {
          chapter.videoUrl = set.lines[0].url;
          cacheLines(trim(episode.id), set);
        }
      } catch (e) { /* 首集解析失败不影响详情返回 */ }
    }
    chapters.push(chapter);
  }
  chapters.sort(function (a, b) { return a.currentEpisode - b.currentEpisode; });
  if (chapters.length === 0) throw new Error('真果·鉴未返回可播放分集');
  return { drama: drama, chapters: chapters };
}

function search(pageNumber, query) {
  var keyword = trim(query);
  if (keyword === '') return { items: [], hasMore: false };
  var resp = apiGet('/v1/browse/catalog', { page: '1', limit: String(PAGE_SIZE), q: keyword }, false);
  var items = dramasFromResp(resp);
  var lower = keyword.toLowerCase();
  var matched = [];
  for (var i = 0; i < items.length; i++) {
    if (text(items[i].title).toLowerCase().indexOf(lower) >= 0) matched.push(items[i]);
  }
  return { items: matched.length > 0 ? matched : items, hasMore: false };
}

// 搜索联想：返回联想词字符串数组（对齐通用 moduleSuggester 的 []string 契约）。
// 带直达播放的完整建议（variantId/directPlayable）仍由 Go 的 suggest action 提供。
function suggestions(query) {
  var keyword = trim(query);
  if (keyword === '') return [];
  var resp = apiGet('/v1/suggest', { q: keyword, limit: '8' }, false);
  var rows = listOf(resp && resp.suggestions);
  var out = [];
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var label = trim((rows[i] || {}).label);
    if (label === '' || label.length > 96 || seen[label]) continue;
    seen[label] = true;
    out.push(label);
    if (out.length >= 8) break;
  }
  return out;
}

function findEpisodeToken(detailID, episodeID) {
  var data = apiGet('/v1/catalog/' + escapePath(detailID), null, false);
  var rows = listOf(data && data.episodes);
  for (var i = 0; i < rows.length; i++) {
    var ep = rows[i] || {};
    if (trim(ep.id) === episodeID && trim(ep.token) !== '') return trim(ep.token);
  }
  return '';
}

function resolveMedia(task) {
  var input = task || {};
  var chapter = input.chapter || {};
  var dramaID = trim(input.dramaId);
  var separator = dramaID.indexOf(':');
  var detailID = separator >= 0 ? dramaID.slice(separator + 1) : dramaID;
  var chapterID = trim(chapter.id);
  var colon = chapterID.lastIndexOf(':');
  var episodeID = colon >= 0 ? chapterID.slice(colon + 1) : trim(chapter.episodeId);

  // 优先用 chapter 里已带的直链（详情首集解析产物）。
  var address = trim(chapter.videoUrl);
  if (address !== '' && address.indexOf('http') === 0) {
    return host.prepareWebMedia({ url: address, referer: baseURL() + '/' }, CHANNEL);
  }

  // 缓存命中：线路表直接复用（零网络）。
  if (episodeID !== '') {
    var cached = cachedLines(episodeID);
    if (cached && cached.lines && cached.lines.length > 0) {
      return mediaFromLines(cached.lines);
    }
  }

  // 全链：详情反查 token → resolve 全量兑换。
  var token = trim(chapter.token) || (detailID && episodeID ? findEpisodeToken(detailID, episodeID) : '');
  if (token === '') throw new Error('真果·鉴未找到当前分集的播放票据');
  var set = resolveLinesSet(token, true);
  if (set.lines.length === 0) throw new Error('真果·鉴：本集暂无可用线路（官方票据兑现失败）');
  if (episodeID !== '') cacheLines(episodeID, set);
  return mediaFromLines(set.lines);
}

function mediaFromLines(lines) {
  var primary = lineToMedia(lines[0]);
  var prepared = host.prepareWebMedia({ url: primary.url, referer: primary.referer, label: primary.label, quality: primary.quality }, CHANNEL);
  var variants = [];
  for (var i = 1; i < lines.length; i++) {
    var next = lineToMedia(lines[i]);
    if (next.url === primary.url) continue;
    variants.push({ url: next.url, referer: next.referer, label: next.label, quality: next.quality, official: next.official });
  }
  if (variants.length > 0) prepared.variants = variants;
  return prepared;
}

// 跳过片头片尾预设：resolve 阶段调用，返回整数秒（消费侧 +0.5 进位）。
function skipPreset(task) {
  var input = task || {};
  var detailID = stripDramaID(input.dramaId);
  if (detailID === '') return { introSec: 0, outroSec: 0 };
  var raw = host.cacheGet('dp.skip.' + detailID);
  if (!raw) {
    // 缓存未命中：拉一次详情补缓存（调试/冷启动路径）。
    try {
      var data = apiGet('/v1/catalog/' + escapePath(detailID), null, false);
      var preset = data && data.playback_skip_settings_preset;
      if (preset) {
        raw = JSON.stringify(preset);
        host.cacheSet('dp.skip.' + detailID, raw, 86400000);
      }
    } catch (e) { return { introSec: 0, outroSec: 0 }; }
  }
  if (!raw) return { introSec: 0, outroSec: 0 };
  try {
    var parsed = JSON.parse(raw);
    // 返回原始秒（可含小数），Go 侧统一做 +0.5 进位，避免双重进位。
    return {
      introSec: numberFrom(parsed.intro_end_seconds, 0),
      outroSec: numberFrom(parsed.outro_from_end_seconds, 0)
    };
  } catch (e) { return { introSec: 0, outroSec: 0 }; }
}

// ---------------------------------------------------------------- 首页板块 / 追剧周表

// /v1/feed/home 的板块按 priority 降序，剧卡走 cardToDrama。
function homeFeed(force) {
  var resp = apiGet('/v1/feed/home', {}, false);
  var sections = listOf(resp && resp.sections);
  var out = [];
  for (var i = 0; i < sections.length; i++) {
    var section = sections[i] || {};
    var cards = listOf(section.cards);
    var items = [];
    for (var j = 0; j < cards.length; j++) {
      var drama = cardToDrama(cards[j]);
      if (drama) items.push(drama);
    }
    if (items.length === 0) continue;
    var browse = section.browse || {};
    var params = browse.params || {};
    var hasMore = false;
    for (var key in params) { if (Object.prototype.hasOwnProperty.call(params, key)) { hasMore = true; break; } }
    if (trim(browse.path) !== '') hasMore = true;
    out.push({
      id: trim(section.id),
      title: trim(section.title),
      subtitle: trim(section.subtitle),
      type: trim(section.type),
      role: trim(section.role),
      priority: numberFrom(section.priority, 0),
      count: items.length,
      moreLabel: trim(browse.label),
      hasMore: hasMore,
      items: items
    });
  }
  out.sort(function (a, b) { return b.priority - a.priority; });
  if (out.length === 0) throw new Error('没有可用的板块');
  var expiresAt = 0;
  if (resp && resp.expires_at) {
    var parsed = Date.parse(resp.expires_at);
    if (!isNaN(parsed)) expiresAt = parsed;
  }
  return { items: out, expiresAt: expiresAt };
}

function homeSection(sectionID, pageNumber) {
  var page = pageNumber > 0 ? pageNumber : 1;
  // 先取主页找 browse 描述，再按 path/params 翻页。
  var home = apiGet('/v1/feed/home', {}, false);
  var sections = listOf(home && home.sections);
  var target = null;
  for (var i = 0; i < sections.length; i++) {
    if (trim((sections[i] || {}).id) === trim(sectionID)) { target = sections[i]; break; }
  }
  if (!target) throw new Error('板块不存在');
  var browse = target.browse || {};
  var params = {};
  var source = browse.params || {};
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue;
    var value = source[key];
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') params[key] = value;
  }
  params.page = page;
  if (params.limit === undefined) params.limit = PAGE_SIZE;
  var path = trim(browse.path) || '/v1/browse/catalog';
  var resp = apiGet(path, params, false);
  var cards = listOf(resp && resp.cards);
  var items = [];
  for (var j = 0; j < cards.length; j++) {
    var drama = cardToDrama(cards[j]);
    if (drama) items.push(drama);
  }
  var pagination = resp && resp.pagination ? resp.pagination : {};
  return { items: items, hasMore: !!pagination.has_more, page: page };
}

function calendarEpisodeLabel(raw) {
  var s = text(raw);
  var m = s.match(/第\s*(\d{1,4})\s*[集期]/);
  if (m) return parseInt(m[1], 10);
  m = s.match(/(?:全|更新至)\s*(\d{1,4})\s*集/);
  return m ? parseInt(m[1], 10) : 0;
}

var WEEK_LABELS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

function homeCalendar(force) {
  var resp = apiGet('/v1/watch-calendar', {}, false);
  var days = listOf(resp && resp.days);
  var out = [];
  for (var i = 0; i < days.length; i++) {
    var day = days[i] || {};
    var groups = day.groups || {};
    var items = [];
    var seen = {};
    for (var gkey in groups) {
      if (!Object.prototype.hasOwnProperty.call(groups, gkey)) continue;
      var group = groups[gkey] || {};
      var preview = listOf(group.preview);
      for (var j = 0; j < preview.length; j++) {
        var row = preview[j] || {};
        var id = trim(row.id) || trim(row.variant_id);
        if (id === '' || trim(row.title) === '' || seen[id]) continue;
        seen[id] = true;
        var drama = cardToDrama({ id: id, title: row.title, content_kind: row.content_kind,
          poster_url: row.poster_url, year: row.year, heat_value: row.heat_score,
          remarks: row.latest_episode_label });
        if (!drama) continue;
        var eps = calendarEpisodeLabel(row.latest_episode_label);
        if (eps > 0) { drama.episodeCount = eps; drama.totalEpisode = eps; }
        if (trim(row.season_label) !== '') drama.tags.push(row.season_label);
        if (row.forecast && trim(row.forecast.label) !== '') drama.tags.push(trim(row.forecast.label));
        items.push(drama);
      }
    }
    if (items.length === 0) continue;
    var label = trim(day.label);
    if (label === '' && trim(day.date) !== '') {
      var d = new Date(trim(day.date));
      if (!isNaN(d.getTime())) label = WEEK_LABELS[d.getDay()];
    }
    out.push({ date: trim(day.date), label: label, items: items });
  }
  out.sort(function (a, b) { return a.date < b.date ? -1 : (a.date > b.date ? 1 : 0); });
  if (out.length === 0) throw new Error('本周还没有可追的更新');
  return { days: out };
}

// 线路面板：按播放任务反查 token，全量解析线路（含官方票据兑换）。
function routes(task) {
  var input = task || {};
  var chapter = input.chapter || {};
  var dramaID = trim(input.dramaId);
  var separator = dramaID.indexOf(':');
  var detailID = separator >= 0 ? dramaID.slice(separator + 1) : dramaID;
  var chapterID = trim(chapter.id);
  var colon = chapterID.lastIndexOf(':');
  var episodeID = colon >= 0 ? chapterID.slice(colon + 1) : trim(chapter.episodeId);

  var cached = episodeID !== '' ? cachedLines(episodeID) : null;
  if (cached && cached.lines && cached.lines.length > 0) {
    return linesToMedia(cached.lines);
  }
  var token = trim(chapter.token) || (detailID && episodeID ? findEpisodeToken(detailID, episodeID) : '');
  if (token === '') return [];
  var set = resolveLinesSet(token, true);
  if (set.lines.length === 0) return [];
  if (episodeID !== '') cacheLines(episodeID, set);
  return linesToMedia(set.lines);
}

function linesToMedia(lines) {
  var out = [];
  for (var i = 0; i < lines.length; i++) out.push(lineToMedia(lines[i]));
  return out;
}

// 带直达播放目标的搜索建议（对齐 Go nativeSuggestion 契约）。
function suggestDirect(query) {
  var keyword = trim(query);
  if (keyword === '') return [];
  var resp = apiGet('/v1/suggest', { q: keyword, limit: '8' }, false);
  var rows = listOf(resp && resp.suggestions);
  var out = [];
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {};
    var label = trim(row.label);
    if (label === '' || label.length > 96 || seen[label]) continue;
    seen[label] = true;
    var target = row.target || {};
    var prompt = trim(row.prompt) || trim(row.action && row.action.prompt);
    var variantID = trim(target.variant_id);
    out.push({
      label: label,
      subtitle: trim(row.subtitle),
      intent: trim(row.intent),
      variantId: variantID,
      directPlayable: !!target.direct_playable && variantID !== '',
      prompt: prompt
    });
    if (out.length >= 8) break;
  }
  return out;
}

// ---------------------------------------------------------------- 弹幕（时评）

var DANMAKU_WINDOW_MS = 30000;
var DANMAKU_MAX_MS = 24 * 3600 * 1000;
var DANMAKU_CACHE_PREFIX = 'dp.danmaku.';

function stripDramaID(id) {
  var value = trim(id);
  var pos = value.indexOf(':');
  return pos >= 0 ? value.slice(pos + 1) : value;
}

// chapter.ID 形如 source:dramaID:episodeID，取最后一段作 episodeID。
function stripChapterID(id) {
  var value = trim(id);
  var pos = value.lastIndexOf(':');
  return pos >= 0 ? value.slice(pos + 1) : value;
}

// 弹幕身份：series = dramaID 裸 ID，video = chapter.ID 的末段（分集 ID）。
function danmakuIds(task) {
  var input = task || {};
  var chapter = input.chapter || {};
  var series = stripDramaID(input.dramaId);
  var video = stripChapterID(chapter.id);
  if (series === '' || video === '' || series.length > 256 || video.length > 256) return null;
  return { series: series, video: video };
}

function cleanDanmakuText(raw) {
  var s = text(raw);
  var out = '';
  for (var i = 0; i < s.length; i++) {
    var code = s.charCodeAt(i);
    if (code < 32 || code === 0x2028 || code === 0x2029) out += ' ';
    else out += s.charAt(i);
  }
  out = trim(out.replace(/\s+/g, ' '));
  var chars = [];
  for (var j = 0; j < out.length; j++) chars.push(out.charAt(j));
  return chars.length > 180 ? chars.slice(0, 180).join('') + '…' : out;
}

function positionMS(raw) {
  var seconds = numberFrom(raw, -1);
  if (seconds < 0 || seconds > 7 * 24 * 3600) return -1;
  return Math.floor(seconds * 1000);
}

// 翻页拉全量评论，过滤出当前集的 visible 时评；结果缓存 10 分钟。
function fetchComments(series, video) {
  var cacheKey = DANMAKU_CACHE_PREFIX + series + '\u0000' + video;
  var cached = host.cacheGet(cacheKey);
  if (cached) {
    try { return JSON.parse(cached); } catch (e) { /* 忽略坏缓存 */ }
  }
  var items = [];
  var seen = {};
  var cursor = '';
  for (var page = 0; page < 4; page++) {
    var params = { variant_id: series, limit: '30' };
    if (cursor !== '') params.cursor = cursor;
    var resp = apiGet('/v1/comments', params, false);
    var rows = listOf(resp && resp.results);
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i] || {};
      if (row.status !== 'visible' || trim(row.id) === '' || seen[row.id]) continue;
      var playback = row.metadata && row.metadata.playback_context;
      if (!playback || trim(playback.episode_id) !== video) continue;
      var ms = positionMS(playback.position_seconds);
      if (ms < 0) continue;
      var clean = cleanDanmakuText(row.content);
      if (clean === '') continue;
      seen[row.id] = true;
      items.push({ id: row.id, text: clean, timeMs: ms });
    }
    var next = typeof resp.next_cursor === 'string' ? resp.next_cursor : '';
    if (!resp.has_more || next === '' || next === cursor) break;
    cursor = next;
  }
  items.sort(function (a, b) { return a.timeMs - b.timeMs; });
  try { host.cacheSet(cacheKey, JSON.stringify(items), 600000); } catch (e) { /* 忽略 */ }
  return items;
}

function danmaku(series, video, startMS, durationMS) {
  var start = numberFrom(startMS, -1);
  var duration = numberFrom(durationMS, 0);
  if (trim(series) === '' || trim(video) === '' || series.length > 256 || video.length > 256) {
    throw new Error('弹幕请求参数无效');
  }
  if (start < 0 || duration <= start || duration > DANMAKU_MAX_MS) {
    throw new Error('弹幕时间范围无效');
  }
  var items = fetchComments(series, video);
  var next = start + DANMAKU_WINDOW_MS;
  var pageItems = [];
  var truncated = false;
  for (var i = 0; i < items.length; i++) {
    var ms = items[i].timeMs;
    if (ms < start || ms >= duration) continue;
    if (pageItems.length === 90) { truncated = true; break; }
    pageItems.push(items[i]);
  }
  if (truncated) {
    if (pageItems.length > 0) {
      var edge = pageItems[pageItems.length - 1].timeMs + DANMAKU_WINDOW_MS;
      if (edge > next) next = edge;
    }
  } else {
    for (var k = 0; k < items.length; k++) {
      var e = items[k].timeMs + DANMAKU_WINDOW_MS;
      if (e > next) next = e;
    }
  }
  if (next > duration) next = duration;
  if (next <= start) next = start + 1;
  pageItems.sort(function (a, b) { return a.timeMs - b.timeMs; });
  return { episodeId: video, items: pageItems, startMs: start, nextMs: next, total: items.length };
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search,
  suggestions: suggestions,
  suggestDirect: suggestDirect,
  resolveMedia: resolveMedia,
  routes: routes,
  homeFeed: homeFeed,
  homeSection: homeSection,
  homeCalendar: homeCalendar,
  skipPreset: skipPreset,
  danmakuIds: danmakuIds,
  danmaku: danmaku
};
