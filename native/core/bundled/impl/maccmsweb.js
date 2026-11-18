// maccmsweb 采集站通用实现（内置模块族用）。
//
// 与 maccmsapi.js（JSON API）不同，本实现面向 HTML 网页解析：
// 目录/搜索页从 DOM 卡片里抓标题/封面/详情链接，详情页从分集容器里抓播放页链接，
// 取流时再抓播放页正文提取真实播放地址（host.prepareWebMedia 收尾）。
//
// 站点差异（4 套 URL 构造 profile、详情候选路径、默认分类）写在模块清单 config 段，
// 运行时通过 host.manifest().config 读取；DOM 解析五站共享，与 Go 版
// native/sources/maccmsweb/maccmsweb.go 语义逐函数对齐。
//
// 清单 config 字段：
//   profile          "huaguo"|"faguo"|"wuguo"|"wangguo"
//   categories       [{id,name}] 默认分类（Go sourceCategories）
//   defaultCategory  huaguo 空分类时兜底 type id（"27"）
//   catalogRoot      空分类首页路径（"/"）
//   catalogTemplate  分类/分页路径模板，占位 {page}/{category}
//   catalogMode      "query"|"zmn"|"pagepath"|"dashes"
//   searchTemplate   搜索路径模板，占位 {query}
//   searchEncode     "query"|"path"
//   detailTemplates  ["/path/{id}.html", ...] 详情候选路径

var cfg = (function () {
  var manifest = host.manifest() || {};
  return manifest.config || {};
})();

var sourceId = host.source;
var sourceName = (host.manifest() || {}).name || sourceId;

var CARD_CLASSES = [
  "col-lg-2", "col-xl-2", "module-item", "module-poster-item", "public-list-box",
  "videoBox", "detail-list-item", "col-md-6", "col-6", "listItem", "FeaturedList_featuredItem",
  "BrowseList_listItem", "SecondList_secondListItem", "vodlist__item", "v_list",
  "entry-wrapper", "TagBookList_tagItem"
];
var REMARK_CLASSES = [
  "meta-post-type2", "imagelabel", "module-item-note", "pic-text", "lastChapter",
  "SecondList_totalChapterNum", "SecondList_bookType"
];
var TITLE_CLASSES = ["module-info-heading", "detail-title", "video-info-title", "page-title"];
var INTRO_CLASSES = ["module-info-introduction-content", "detail-content", "video-info-content", "introduction_introEllipsis"];
var COVER_CLASSES = ["module-item-pic", "detail-pic", "video-info-pic", "pic"];
var CATEGORY_CLASSES = ["module-info-tag-link", "detail-tag", "video-info-actor"];
var EP_CLASSES = ["content__playlist", "playlink", "pcDrama_catalogItem", "catalogItem", "playlist"];
var EP_FALLBACK_CLASSES = ["tab-pane", "playlist", "playList"];
var TITLE_SUFFIXES = ["在线观看", "免费观看", "高清完整版", "完整版", "全集", "在线播放", "高清", "免费"];
var SEO_MARKERS = ["短剧", "全集", "在线观看", "免费", "高清", "完整版", "视频", "剧场", "影院", "网"];

var DETAIL_LINK = /(?:index\.php\/vod\/)?(?:detail|vod|show|view|movie|drama|zywview|xzyxvd)\//i;
var DETAIL_PATH = /\/(?:voddetail|detail|show|vod|drama|movie|tv)\/([0-9]+)(?:[-./]|$)/i;
var EPISODE_LINK = /(?:vod\/)?play\/|\/vodplay\/|\/drama-play|episode_id=/i;
var NUMERIC_ID = /^[1-9][0-9]{0,17}$/;
var PLAYER_DATA = /player_aaaa\s*=\s*(\{[\s\S]*?\})\s*<\/script>/i;
var PLAYER_URL_FIELD = /"url"\s*:\s*"([^"]+)"/i;
var PLAYER_FALLBACK = [
  /\$\.url\s*=\s*"([^"]+)"/i,
  /"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"/i,
  /(https?:\/\/[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)/i
];
var UNICODE_ESCAPE = /\\?u([0-9a-fA-F]{4})/g;

function trim(value) {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return "";
}

function decodeEntities(value) {
  return String(value || "")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/&#0*39;/gi, "'")
    .replace(/&apos;/gi, "'");
}

function truncate(value, limit) {
  var text = String(value || "");
  return text.length <= limit ? text : text.slice(0, limit) + "...";
}

function escapeQuery(value) {
  return encodeURIComponent(value).replace(/%20/g, "+");
}

function escapePath(value) {
  return encodeURIComponent(value);
}

function episodeNumber(raw, fallback) {
  var text = trim(raw);
  var match = /(?:第\s*)?(\d+)\s*(?:集|话|期|ep)/i.exec(text);
  if (!match) match = /(\d+)/.exec(text);
  if (match && parseInt(match[1], 10) > 0) return parseInt(match[1], 10);
  var plain = parseInt(text, 10);
  if (!isNaN(plain) && plain > 0) return plain;
  return fallback > 0 ? fallback : 1;
}

function releaseStatus(raw) {
  var value = trim(raw).toLowerCase();
  if (["over", "finished", "completed", "2", "已完结", "完结"].indexOf(value) >= 0) return "finished";
  if (["ongoing", "serializing", "1", "连载中", "更新中"].indexOf(value) >= 0) return "ongoing";
  return "";
}

// ---- DOM 遍历（host.parseHtml 的树不带 parent，遍历时补齐）----

function htmlTree(body) {
  if (body.length > 4 << 20) throw new Error("站源页面过大");
  var root = host.parseHtml(body);
  var pending = [root];
  while (pending.length > 0) {
    var node = pending.pop();
    var children = node.children || [];
    for (var i = 0; i < children.length; i++) {
      children[i].parent = node;
      pending.push(children[i]);
    }
  }
  return root;
}

function htmlNodes(root, match) {
  var found = [];
  if (!root) return found;
  var pending = [root];
  while (pending.length > 0) {
    var node = pending.pop();
    if (match(node)) found.push(node);
    var children = node.children || [];
    for (var i = children.length - 1; i >= 0; i--) pending.push(children[i]);
  }
  return found;
}

function htmlAttr(node, name) {
  return node && node.attrs && typeof node.attrs[name] === "string" ? node.attrs[name] : "";
}

function htmlClass(node, name) {
  return htmlAttr(node, "class").split(/\s+/).indexOf(name) >= 0;
}

function htmlFirstClass(root, name) {
  return htmlNodes(root, function (node) { return htmlClass(node, name); })[0] || null;
}

function htmlText(root) {
  if (!root) return "";
  var parts = [];
  var nodes = htmlNodes(root, function (node) {
    return node.tag === undefined && typeof node.text === "string";
  });
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i];
    if (node.parent && (node.parent.tag === "script" || node.parent.tag === "style")) continue;
    parts.push(node.text);
  }
  return decodeEntities(parts.join(" ")).replace(/\s+/g, " ").trim();
}

// 与 Go classMatcher 一致：class token 精确相等或 "-"+name 后缀（兼容 hash 前缀 CSS module）。
function classMatcher(name) {
  var suffix = "-" + name;
  return function (node) {
    var tokens = htmlAttr(node, "class").split(/\s+/);
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i] === name || (tokens[i].length > suffix.length && tokens[i].slice(-suffix.length) === suffix)) return true;
    }
    return false;
  };
}

function classesMatcher(names) {
  var matchers = [];
  for (var i = 0; i < names.length; i++) matchers.push(classMatcher(names[i]));
  return function (node) {
    for (var i = 0; i < matchers.length; i++) if (matchers[i](node)) return true;
    return false;
  };
}

// ---- 地址构造（base 两跳回退：运行时覆盖 → 清单基址）----

function baseCandidates() {
  var manifest = host.manifest() || {};
  var list = [];
  var primary = String(host.baseUrl() || "").replace(/\/+$/, "");
  var builtin = String(manifest.base || "").replace(/\/+$/, "");
  if (primary) list.push(primary);
  if (builtin && builtin !== primary) list.push(builtin);
  return list;
}

function catalogPath(category, page) {
  var current = parseInt(page, 10);
  if (isNaN(current) || current < 1) current = 1;
  var cat = trim(category);
  var mode = cfg.catalogMode || "query";
  var tpl = cfg.catalogTemplate || "/";
  if (mode === "query") {
    if (current <= 1 && cat === "") return cfg.catalogRoot || "/";
    if (cat === "") cat = cfg.defaultCategory || "27";
    return tpl.replace("{page}", String(current)).replace("{category}", escapeQuery(cat));
  }
  if (mode === "zmn") {
    // 发果：空分类走 /xzyxvt/{page}zmn.html；分类含 zmn 时把页码插在 zmn 前。
    if (cat === "") return tpl.replace("{page}", String(current));
    if (cat.indexOf("zmn") >= 0) {
      var head = cat.split("zmn")[0];
      return head + String(current) + "zmn.html";
    }
    throw new Error("发果分类无效");
  }
  if (mode === "pagepath") {
    // 五五：分类去 .html 后拼 /page/{page}.html。
    if (cat === "") return cfg.catalogRoot || "/";
    return cat.replace(/\.html$/, "") + tpl.replace("{page}", String(current));
  }
  if (mode === "dashes") {
    // 短剧网站：空分类用现成首页模板；分类取 "---.html" 之前的段再插页码。
    if (cat === "") return tpl;
    var prefix = cat.split("---.html")[0];
    return prefix + String(current) + "---.html";
  }
  return tpl.replace("{page}", String(current)).replace("{category}", escapeQuery(cat));
}

function searchPath(query) {
  var tpl = cfg.searchTemplate || "/search.html?searchword={query}";
  var keyword = trim(query);
  var encoded = cfg.searchEncode === "path" ? escapePath(keyword) : escapeQuery(keyword);
  return tpl.replace("{query}", encoded);
}

function detailPaths(sourceID) {
  var templates = cfg.detailTemplates || ["/detail/{id}.html"];
  var out = [];
  for (var i = 0; i < templates.length; i++) {
    out.push(templates[i].replace("{id}", encodeURIComponent(trim(sourceID))));
  }
  return out;
}

function fetchAt(base, path) {
  var address = base + path;
  var response = host.fetchText({ url: address, referer: base + "/" });
  if (!response) throw new Error("请求失败");
  if (response.status && (response.status < 200 || response.status >= 300)) throw new Error("HTTP " + response.status);
  var body = response.body || "";
  if (body.length > 4 << 20) throw new Error("站源页面过大");
  return { document: htmlTree(body), base: base, address: address };
}

function fetchPage(path) {
  var bases = baseCandidates();
  var failures = [];
  for (var i = 0; i < bases.length; i++) {
    try {
      return fetchAt(bases[i], path);
    } catch (error) {
      failures.push(error && error.message ? error.message : String(error));
    }
  }
  throw new Error(failures.join("；") || "请求失败");
}

// ---- 卡片解析（目录 / 搜索共用）----

function coverAddress(value, pageURL) {
  var address = trim(value);
  if (!address || address.indexOf("javascript:") === 0 || address.indexOf("data:") === 0) return "";
  if (/^https?:\/\//i.test(address)) return address;
  return host.resolveUrl(pageURL, address);
}

function cardCover(card, pageURL) {
  var images = htmlNodes(card, function (node) { return node.tag === "img"; });
  var attrs = ["data-original", "data-src", "src"];
  for (var i = 0; i < images.length; i++) {
    for (var j = 0; j < attrs.length; j++) {
      var cover = coverAddress(htmlAttr(images[i], attrs[j]), pageURL);
      if (cover) return cover;
    }
  }
  var anchors = htmlNodes(card, function (node) { return node.tag === "a"; });
  var lazyAttrs = ["data-original", "data-src"];
  for (var i = 0; i < anchors.length; i++) {
    for (var j = 0; j < lazyAttrs.length; j++) {
      var lazy = coverAddress(htmlAttr(anchors[i], lazyAttrs[j]), pageURL);
      if (lazy) return lazy;
    }
  }
  return "";
}

function cardTitle(card) {
  var attrs = ["title", "alt"];
  for (var a = 0; a < attrs.length; a++) {
    var nodes = htmlNodes(card, function (node) { return node.tag === "a" || node.tag === "img"; });
    for (var i = 0; i < nodes.length; i++) {
      var text = trim(htmlAttr(nodes[i], attrs[a]));
      if (text) return text;
    }
  }
  var anchors = htmlNodes(card, function (node) { return node.tag === "a"; });
  for (var i = 0; i < anchors.length; i++) {
    var inner = htmlText(anchors[i]);
    if (inner) return inner;
  }
  return "";
}

function cardLink(card, base) {
  var anchors = htmlNodes(card, function (node) { return node.tag === "a"; });
  for (var i = 0; i < anchors.length; i++) {
    var link = htmlAttr(anchors[i], "href");
    if (!link || link.indexOf("javascript:") === 0) continue;
    var absolute = host.resolveUrl(base + "/", link);
    if (absolute) return absolute;
  }
  return "";
}

function cardRemark(card) {
  for (var i = 0; i < REMARK_CLASSES.length; i++) {
    var node = htmlFirstClass(card, REMARK_CLASSES[i]);
    if (!node) node = htmlNodes(card, classMatcher(REMARK_CLASSES[i]))[0] || null;
    if (node) {
      var text = htmlText(node);
      if (text) return text;
    }
  }
  return "";
}

function sourceIDFromURL(link) {
  var path = String(link || "");
  var query = "";
  var qIndex = path.indexOf("?");
  if (qIndex >= 0) {
    query = path.slice(qIndex + 1);
    path = path.slice(0, qIndex);
  }
  var hashIndex = path.indexOf("#");
  if (hashIndex >= 0) path = path.slice(0, hashIndex);
  var absolute = /^https?:\/\/[^/]+(\/.*)?$/i.exec(path);
  if (absolute) path = absolute[1] || "/";
  var clean = path.replace(/\.html$/, "");
  var matched = DETAIL_PATH.exec(clean + "/");
  if (matched && matched[1]) return matched[1];
  var parts = clean.split("/");
  for (var i = parts.length - 1; i >= 0; i--) {
    var candidate = parts[i].replace(/\.html$/, "");
    if (NUMERIC_ID.test(candidate)) return candidate;
    var cut = candidate.indexOf("-");
    if (cut >= 0) {
      var tail = candidate.slice(cut + 1);
      if (NUMERIC_ID.test(tail)) return tail;
    }
  }
  var idMatch = /(?:^|&)id=([1-9][0-9]*)(?:&|$)/.exec(query);
  if (idMatch) return idMatch[1];
  return "";
}

function anchorCards(document) {
  var cards = [];
  var anchors = htmlNodes(document, function (node) {
    return node.tag === "a" && DETAIL_LINK.test(htmlAttr(node, "href"));
  });
  for (var i = 0; i < anchors.length; i++) {
    var parent = anchors[i].parent;
    while (parent && parent.tag !== undefined) {
      if (cards.indexOf(parent) >= 0) break;
      if (parent.tag !== "li" && parent.tag !== "div") {
        parent = parent.parent;
        continue;
      }
      cards.push(parent);
      break;
    }
  }
  return cards;
}

function cards(document, base) {
  var nodes = [];
  var matcher = classesMatcher(CARD_CLASSES);
  var found = htmlNodes(document, matcher);
  for (var i = 0; i < found.length; i++) {
    if (nodes.indexOf(found[i]) < 0) nodes.push(found[i]);
  }
  if (nodes.length === 0) nodes = anchorCards(document);
  var items = [];
  var ids = {};
  for (var i = 0; i < nodes.length; i++) {
    var card = nodes[i];
    var link = cardLink(card, base);
    var title = cardTitle(card);
    if (!link || !title) continue;
    var sourceID = sourceIDFromURL(link);
    if (!sourceID || ids[sourceID]) continue;
    ids[sourceID] = true;
    var remark = cardRemark(card);
    var cover = cardCover(card, link);
    items.push({
      id: sourceId + ":" + sourceID,
      source: sourceId,
      sourceId: sourceID,
      title: title,
      name: title,
      intro: "",
      desc: "",
      cover: cover,
      coverUrl: cover,
      remark: remark,
      episodeCount: episodeNumber(remark, 0),
      releaseStatus: releaseStatus(remark),
      channelName: sourceName
    });
  }
  return items;
}

// ---- 详情解析（分集 / 标题 / 简介 / 封面 / 分类）----

function episodeNodes(document) {
  var nodes = [];
  function collect(name) {
    var lists = htmlNodes(document, classMatcher(name));
    for (var i = 0; i < lists.length; i++) {
      var anchors = htmlNodes(lists[i], function (node) { return node.tag === "a"; });
      for (var j = 0; j < anchors.length; j++) nodes.push(anchors[j]);
    }
  }
  var i;
  for (i = 0; i < EP_CLASSES.length; i++) collect(EP_CLASSES[i]);
  if (nodes.length === 0) for (i = 0; i < EP_FALLBACK_CLASSES.length; i++) collect(EP_FALLBACK_CLASSES[i]);
  if (nodes.length === 0) {
    nodes = htmlNodes(document, function (node) {
      return node.tag === "a" && EPISODE_LINK.test(htmlAttr(node, "href"));
    });
  }
  return nodes;
}

function episodesFromDocument(document) {
  var episodes = [];
  var seen = {};
  var anchors = episodeNodes(document);
  for (var i = 0; i < anchors.length; i++) {
    var anchor = anchors[i];
    var link = trim(htmlAttr(anchor, "href"));
    var title = htmlText(anchor);
    if (!link) continue;
    if (title.indexOf("APP") >= 0 || title.indexOf("下载") >= 0) continue;
    if (seen[link]) continue;
    seen[link] = true;
    episodes.push({
      key: String(i + 1),
      title: title,
      url: link,
      index: i + 1
    });
  }
  return episodes;
}

function titleTailIsSeo(tail) {
  var text = trim(tail);
  if (text === "") return true;
  for (var i = 0; i < SEO_MARKERS.length; i++) {
    if (text.indexOf(SEO_MARKERS[i]) >= 0) return true;
  }
  return false;
}

function cleanTitle(raw) {
  var text = trim(raw);
  if (!text) return "";
  var cut = text.indexOf(" - ");
  if (cut >= 0) text = trim(text.slice(0, cut));
  cut = text.indexOf(" _ ");
  if (cut >= 0) text = trim(text.slice(0, cut));
  var separators = ["-", "_", "|"];
  for (var s = 0; s < separators.length; s++) {
    var separator = separators[s];
    for (;;) {
      var index = text.indexOf(separator);
      if (index < 0) break;
      var head = trim(text.slice(0, index));
      var tail = text.slice(index + separator.length);
      if (!titleTailIsSeo(tail)) break;
      text = head;
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (var i = 0; i < TITLE_SUFFIXES.length; i++) {
      var suffix = TITLE_SUFFIXES[i];
      if (text.length > suffix.length && text.slice(-suffix.length) === suffix) {
        text = trim(text.slice(0, text.length - suffix.length));
        changed = true;
      }
    }
  }
  text = text.replace(/^[-_|·—\s]+|[-_|·—\s]+$/g, "");
  if (!text) return trim(raw);
  return text;
}

function detailTitle(document) {
  for (var i = 0; i < TITLE_CLASSES.length; i++) {
    var node = htmlNodes(document, classMatcher(TITLE_CLASSES[i]))[0] || null;
    if (node) {
      var text = htmlText(node);
      if (text) return cleanTitle(text);
    }
  }
  var titleNodes = htmlNodes(document, function (node) { return node.tag === "title"; });
  if (titleNodes.length > 0) return cleanTitle(htmlText(titleNodes[0]));
  return "";
}

function detailIntro(document) {
  for (var i = 0; i < INTRO_CLASSES.length; i++) {
    var node = htmlNodes(document, classMatcher(INTRO_CLASSES[i]))[0] || null;
    if (node) {
      var text = htmlText(node);
      if (text) return truncate(text, 2000);
    }
  }
  var metas = htmlNodes(document, function (node) { return node.tag === "meta"; });
  for (var i = 0; i < metas.length; i++) {
    if (htmlAttr(metas[i], "name").toLowerCase() === "description") {
      var content = trim(htmlAttr(metas[i], "content"));
      if (content) return truncate(decodeEntities(content), 2000);
    }
  }
  return "";
}

function detailCover(document, pageURL) {
  for (var i = 0; i < COVER_CLASSES.length; i++) {
    var nodes = htmlNodes(document, classesMatcher([COVER_CLASSES[i]]));
    for (var j = 0; j < nodes.length; j++) {
      var cover = cardCover(nodes[j], pageURL);
      if (cover) return cover;
    }
  }
  var images = htmlNodes(document, function (node) { return node.tag === "img"; });
  var attrs = ["data-original", "data-src", "src"];
  for (var i = 0; i < images.length; i++) {
    for (var j = 0; j < attrs.length; j++) {
      var fallback = coverAddress(htmlAttr(images[i], attrs[j]), pageURL);
      if (fallback) return fallback;
    }
  }
  return "";
}

function detailCategory(document) {
  for (var i = 0; i < CATEGORY_CLASSES.length; i++) {
    var nodes = htmlNodes(document, classMatcher(CATEGORY_CLASSES[i]));
    if (nodes.length > 0) {
      var anchors = htmlNodes(nodes[0], function (node) { return node.tag === "a"; });
      var parts = [];
      for (var j = 0; j < anchors.length; j++) {
        var text = htmlText(anchors[j]);
        if (text) parts.push(text);
      }
      if (parts.length > 0) return parts.join(", ");
    }
  }
  return "";
}

// ---- 导出函数 ----

function categories(force) {
  var list = cfg.categories || [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    out.push({ id: trim(list[i].id), name: trim(list[i].name) });
  }
  return out;
}

function catalogPage(page, category) {
  var result = fetchPage(catalogPath(category, page));
  var items = cards(result.document, result.base);
  return { items: items, hasMore: items.length > 0 };
}

function detail(sourceID) {
  var id = trim(sourceID);
  var prefix = sourceId + ":";
  if (id.indexOf(prefix) === 0) id = id.slice(prefix.length);
  var bases = baseCandidates();
  var paths = detailPaths(id);
  var lastErr = null;
  for (var p = 0; p < paths.length; p++) {
    for (var b = 0; b < bases.length; b++) {
      var base = bases[b];
      try {
        var result = fetchAt(base, paths[p]);
        var episodes = episodesFromDocument(result.document);
        if (episodes.length === 0) {
          lastErr = new Error("未解析到分集列表");
          continue;
        }
        var chapters = [];
        for (var i = 0; i < episodes.length; i++) {
          var entry = episodes[i];
          var number = episodeNumber(entry.title || entry.key, i + 1);
          var link = host.resolveUrl(base + "/", entry.url);
          if (!link) continue;
          chapters.push({
            id: sourceId + ":" + id + ":" + number,
            source: sourceId,
            title: entry.title || ("第" + number + "集"),
            currentEpisode: number,
            pageUrl: link,
            referer: base + "/",
            videoUrl: ""
          });
        }
        if (chapters.length === 0) {
          lastErr = new Error("未解析到可播放分集");
          continue;
        }
        chapters.sort(function (left, right) {
          return (parseInt(left.currentEpisode, 10) || 0) - (parseInt(right.currentEpisode, 10) || 0);
        });
        var drama = {
          id: sourceId + ":" + id,
          source: sourceId,
          sourceId: id,
          title: detailTitle(result.document),
          intro: detailIntro(result.document),
          desc: detailIntro(result.document),
          cover: detailCover(result.document, result.address),
          coverUrl: detailCover(result.document, result.address),
          category: detailCategory(result.document),
          channelName: sourceName,
          episodeCount: chapters.length
        };
        return { drama: drama, chapters: chapters };
      } catch (error) {
        lastErr = error;
      }
    }
  }
  throw lastErr || new Error("未找到该剧的详情页");
}

function search(page, query) {
  var keyword = trim(query);
  if (!keyword) throw new Error("搜索词不能为空");
  var result = fetchPage(searchPath(keyword));
  var items = cards(result.document, result.base);
  return { items: items, hasMore: false };
}

function playerURL(body) {
  var text = String(body || "");
  var match = PLAYER_DATA.exec(text);
  if (match && match[1]) {
    var inner = PLAYER_URL_FIELD.exec(match[1]);
    if (inner && inner[1]) return inner[1].replace(/\\\//g, "/");
  }
  for (var i = 0; i < PLAYER_FALLBACK.length; i++) {
    var fallback = PLAYER_FALLBACK[i].exec(text);
    if (fallback && fallback[1]) return fallback[1].replace(/\\\//g, "/");
  }
  return "";
}

function decodeUnicode(value) {
  return String(value || "").replace(UNICODE_ESCAPE, function (whole, hex) {
    var number = parseInt(hex, 16);
    return isNaN(number) ? whole : String.fromCharCode(number);
  });
}

function normalizePlaybackURL(raw) {
  var address = trim(String(raw || "")).replace(/\\\//g, "/");
  address = address.replace(/^[,\\。，;；\s]+|[,\\。，;；\s]+$/g, "").trim();
  if (!address) return "";
  if (address.indexOf("p.") >= 0 || address.indexOf("c1.") >= 0) {
    var parts = address.split("/");
    if (parts.length >= 3) {
      var base = parts.slice(0, parts.length - 2).join("/");
      var folder = parts[parts.length - 2];
      var decoded = decodeUnicode(folder);
      if (decoded !== folder) return base + "/" + encodeURIComponent(decoded) + "/index.m3u8";
    }
  }
  return address;
}

function resolveMedia(task) {
  var chapter = task && task.chapter ? task.chapter : {};
  var pageURL = trim(chapter.pageUrl);
  if (!pageURL) throw new Error(sourceName + "分集缺少播放页面，请刷新详情后重试");
  var referer = trim(chapter.referer) || (baseCandidates()[0] || "") + "/";
  var response = host.fetchText({ url: pageURL, referer: referer });
  var body = response && response.body ? response.body : "";
  var address = normalizePlaybackURL(playerURL(body));
  if (!address) throw new Error(sourceName + "未返回有效播放地址，请刷新章节后重试");
  return host.prepareWebMedia({ url: address, referer: referer }, sourceName);
}

module.exports = {
  categories: categories,
  catalogPage: catalogPage,
  detail: detail,
  search: search,
  resolveMedia: resolveMedia
};
