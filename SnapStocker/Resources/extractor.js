/**
 * SNAP STOCKER extractor（ページ内実行用）
 * ------------------------------------------------------------------
 * 商品ページ「そのもの」の中（Safariのブックマークレット等）で実行する。
 * 外部ページのDOMへ別オリジンのWebアプリから触れない（同一オリジンポリシー）ため、
 * このコードは“見ているページの中”で動かす前提。
 *
 *   window.SnapStockerExtract(document, { pageUrl })  → { title, images:[...], excluded:[...] }
 *
 * 画像1件: { url, kind, conf, reason, w, h }
 *   conf: "high"（商品本体と判断・初期選択） / "review"（要確認・初期は未選択）
 */
(function (root) {
  "use strict";

  // 商品本体とは別の「関連商品」セクション見出し
  var RELATED_RE = /(一緒に|よく見られ|あわせて|合わせて|おすすめ|オススメ|関連|最近見た|ランキング|他のグッズ|こちらもおすすめ|recommend|related|you may also|also viewed)/i;
  // 追跡・計測・広告・UI部品のホスト／パス
  var JUNK_HOST_RE = /(tr\.line\.me|facebook\.com\/tr|analytics\.twitter\.com|t\.co\/|bat\.bing\.com|doubleclick|google-analytics|googletagmanager|adsct|\/pixel|beacon)/i;
  var JUNK_PATH_RE = /(logo|icon|sprite|banner|btn_|button|arrow|common\/|header|footer|noimage|loading|spacer|blank)/i;
  var IMG_EXT_RE = /\.(jpe?g|png|webp|gif|avif)(\?|#|$)/i;

  function abs(u, base) {
    try { return new URL(u, base).href; } catch (e) { return ""; }
  }
  function bestFromSrcset(srcset, base) {
    if (!srcset) return "";
    var best = "", bestScore = -1;
    String(srcset).split(",").forEach(function (part) {
      var seg = part.trim().split(/\s+/);
      if (!seg[0]) return;
      var d = seg[1] || "1x";
      var score = parseFloat(d) || 1;
      if (/w$/.test(d)) score = parseFloat(d);
      if (score > bestScore) { bestScore = score; best = seg[0]; }
    });
    return best ? abs(best, base) : "";
  }
  function stem(url) {
    // 同じ商品のギャラリー画像は「<hash>_1.jpg」「<hash>_2.jpg」のように同じhashを共有する
    try {
      var p = new URL(url).pathname.split("/").pop() || "";
      var m = p.match(/^(.*?)(?:_\d+)?(?:_[a-z]{1,3})?\.[a-z0-9]+$/i);
      return m ? m[1] : p;
    } catch (e) { return ""; }
  }
  function key(url) {
    // クエリ・拡張子（jpg/webp違い）・末尾のサイズ違い接尾辞（_l, _xl 等）を除いて同一画像として扱う
    return String(url).split("?")[0].replace(/(_\d+)?_[a-z]{1,3}(\.[a-z0-9]+)$/i, "$1$2").replace(/\.(jpe?g|png|webp|gif|avif)$/i, "");
  }

  function extract(doc, opts) {
    opts = opts || {};
    var base = opts.pageUrl || (doc.location && doc.location.href) || "https://example.invalid/";
    var win = doc.defaultView || {};
    var cands = []; // { url, el, kind }

    function add(url, el, kind) {
      url = abs(url, base);
      if (!/^https?:/i.test(url)) return;
      cands.push({ url: url, el: el || null, kind: kind });
    }

    // 1) img / srcset / lazy属性
    Array.prototype.forEach.call(doc.querySelectorAll("img"), function (img) {
      var s = bestFromSrcset(img.getAttribute("srcset"), base);
      if (s) add(s, img, "srcset");
      ["data-src", "data-original", "data-lazy-src", "data-zoom-src", "data-large", "data-image"].forEach(function (a) {
        var v = img.getAttribute(a);
        if (v) add(v, img, "lazy-attr");
      });
      var cur = img.currentSrc || img.getAttribute("src");
      if (cur) add(cur, img, "img-src");
    });
    // 2) <picture><source>
    Array.prototype.forEach.call(doc.querySelectorAll("picture source[srcset]"), function (s) {
      var u = bestFromSrcset(s.getAttribute("srcset"), base);
      if (u) add(u, s.closest("picture"), "picture");
    });
    // 3) inline background-image（見えている商品ギャラリーで使われることがある）
    Array.prototype.forEach.call(doc.querySelectorAll("[style*='background']"), function (el) {
      var m = (el.getAttribute("style") || "").match(/url\((['"]?)(.+?)\1\)/);
      if (m) add(m[2], el, "background");
    });
    // 4) og:image（補助）
    Array.prototype.forEach.call(doc.querySelectorAll("meta[property='og:image']"), function (m) {
      add(m.getAttribute("content"), null, "og");
    });

    // 重複除去（クエリ違いは同一画像扱い。img-src より srcset / lazy を優先）
    var rank = { srcset: 0, picture: 1, "lazy-attr": 2, background: 3, "img-src": 4, og: 5 };
    var byKey = {};
    cands.forEach(function (c) {
      var k = key(c.url);
      if (!byKey[k] || rank[c.kind] < rank[byKey[k].kind]) byKey[k] = c;
      else if (!byKey[k].el && c.el) byKey[k].el = c.el;
    });
    var list = Object.keys(byKey).map(function (k) { return byKey[k]; });

    // 関連商品セクションの見出し（文書順で最初のもの）
    var relatedHead = null;
    var heads = doc.querySelectorAll("h1,h2,h3,h4,h5,h6,[class*='title'],[class*='ttl'],[class*='heading'],p,dt,span,div");
    for (var i = 0; i < heads.length; i++) {
      var h = heads[i];
      if (h.children.length > 2) continue;
      var t = (h.textContent || "").replace(/\s+/g, "");
      if (t && t.length <= 30 && RELATED_RE.test(t)) { relatedHead = h; break; }
    }
    var FOLLOWING = 4; // Node.DOCUMENT_POSITION_FOLLOWING

    function inRelatedContainer(el) {
      for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
        var cls = (n.getAttribute("class") || "") + " " + (n.id || "");
        if (/(related|recommend|also|ranking|osusume|similar|carousel-other)/i.test(cls)) return "関連商品系のクラス名";
      }
      return "";
    }
    function linkedToOtherProduct(el) {
      var a = el && el.closest ? el.closest("a[href]") : null;
      if (!a) return "";
      var href = a.getAttribute("href") || "";
      var cur = (base.match(/(?:prod_cd=|\/goods\/)(\d{6,13})/) || [])[1];
      var other = (href.match(/(?:prod_cd=|\/goods\/)(\d{6,13})/) || [])[1];
      return cur && other && cur !== other ? "別商品へのリンク内の画像" : "";
    }

    var excluded = [];
    var kept = [];
    list.forEach(function (c) {
      var reason = "";
      if (JUNK_HOST_RE.test(c.url)) reason = "計測・広告用の画像";
      else if (/^data:|\.svg(\?|$)/i.test(c.url)) reason = "SVG/データURI";
      else if (c.kind !== "og" && !IMG_EXT_RE.test(c.url) && !/\/(goods|images|image|img|product|item)\//i.test(c.url)) reason = "画像ファイルと判断できない";
      else if (JUNK_PATH_RE.test(c.url.replace(/^https?:\/\/[^/]+/, "")) && !/\/goods\//i.test(c.url)) reason = "ロゴ・アイコン・バナー等のUI画像";
      var w = 0, h2 = 0;
      if (c.el && c.el.tagName === "IMG") { w = c.el.naturalWidth || 0; h2 = c.el.naturalHeight || 0; }
      c.w = w; c.h = h2;
      if (!reason && c.el && c.el.tagName === "IMG") {
        var aw = parseInt(c.el.getAttribute("width") || "0", 10), ah = parseInt(c.el.getAttribute("height") || "0", 10);
        if ((aw && aw <= 2) || (ah && ah <= 2) || (w && w <= 2 && h2 && h2 <= 2)) reason = "1px前後の画像";
        else if (w && h2 && (w < 80 || h2 < 80)) reason = "小さすぎる画像（" + w + "x" + h2 + "）";
      }
      if (!reason && c.el) {
        if (relatedHead && relatedHead !== c.el && !relatedHead.contains(c.el) && (relatedHead.compareDocumentPosition(c.el) & FOLLOWING)) reason = "関連商品の見出し「" + (relatedHead.textContent || "").trim().slice(0, 20) + "」より後ろの画像";
        if (!reason) reason = inRelatedContainer(c.el);
        if (!reason) reason = linkedToOtherProduct(c.el);
      }
      if (reason) { c.reason = reason; excluded.push(c); } else kept.push(c);
    });

    // 商品本体グループの判定: 最初の大きい画像（なければ最初の画像）のhashを「主」とする
    var main = null;
    kept.forEach(function (c) {
      if (!main && c.kind !== "og") main = c;
    });
    var bigFirst = kept.filter(function (c) { return c.w >= 300 && c.h >= 300; })[0];
    if (bigFirst) main = bigFirst;
    var mainStem = main ? stem(main.url) : "";

    var images = kept.map(function (c) {
      var sameGroup = mainStem && stem(c.url) === mainStem;
      return {
        url: c.url, kind: c.kind, w: c.w, h: c.h,
        conf: sameGroup || c === main ? "high" : "review",
        reason: sameGroup ? "商品本体の画像と同じ画像グループ" : (c === main ? "ページ先頭の主画像" : "グループ不一致（本体か要確認）")
      };
    });
    // 本体グループが2枚以上取れた場合のみ、グループ外を「要確認」に落とす。グループ判定できなければ全て「要確認」
    var highCount = images.filter(function (i) { return i.conf === "high"; }).length;
    if (highCount === 0) images.forEach(function (i) { i.conf = "review"; i.reason = "商品本体かどうか確実に判断できない"; });

    var title = "";
    var og = doc.querySelector("meta[property='og:title']");
    if (og) title = (og.getAttribute("content") || "").replace(/^【公式】/, "").replace(/[｜|].*$/, "").trim();
    if (!title) { var h1 = doc.querySelector("h1"); title = h1 ? h1.textContent.trim() : (doc.title || ""); }

    return {
      pageUrl: base,
      title: title,
      images: images,
      excluded: excluded.map(function (c) { return { url: c.url, reason: c.reason }; }),
      relatedHeadingFound: !!relatedHead
    };
  }

  root.SnapStockerExtract = extract;
  if (typeof module !== "undefined" && module.exports) module.exports = { extract: extract };
})(typeof window !== "undefined" ? window : globalThis);
