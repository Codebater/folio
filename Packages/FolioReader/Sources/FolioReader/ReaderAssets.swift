// The reader page's stylesheet and script. They live in Swift strings rather
// than bundle resources so every platform (including the Windows test
// build) gets them without resource-bundle support.

public enum ReaderAssets {
    public static let css = #"""
    *{box-sizing:border-box}
    html{-webkit-text-size-adjust:100%;text-size-adjust:100%;background:var(--bg)}
    body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--font);font-size:var(--size);line-height:var(--lh);
      letter-spacing:var(--ls);-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;font-kerning:normal;
      font-variant-ligatures:common-ligatures;overflow-wrap:break-word;-webkit-tap-highlight-color:transparent;
      transition:background-color .3s,color .3s}
    #f-article{max-width:38em;margin:0 auto;padding:calc(env(safe-area-inset-top) + 64px) var(--margin) calc(env(safe-area-inset-bottom) + 112px)}
    .f-head{margin-bottom:2.1em}
    .f-site{font:600 .7em/1.3 ui-sans-serif,-apple-system,sans-serif;letter-spacing:.09em;text-transform:uppercase;color:var(--accent);margin:0 0 .95em}
    .f-title{font-size:1.72em;line-height:1.17;font-weight:700;letter-spacing:-.012em;margin:0 0 .55em;text-wrap:balance}
    .f-meta{font:.76em/1.45 ui-sans-serif,-apple-system,sans-serif;color:var(--fg2);margin:0}
    p,blockquote{margin:0 0 .95em;text-align:var(--align);hyphens:var(--hyphens);-webkit-hyphens:var(--hyphens);text-wrap:pretty}
    .f-h{font-weight:700;line-height:1.24;margin:1.65em 0 .55em;text-wrap:balance;letter-spacing:-.005em}
    h2.f-h{font-size:1.3em}h3.f-h{font-size:1.13em}h4.f-h{font-size:1em}
    .f-quote{margin:1.3em 0;padding:.05em 0 .05em 1.05em;border-left:3px solid var(--accent);font-style:italic}
    .f-li{position:relative;padding-left:1.45em;margin-bottom:.45em}
    .f-li::before{content:"\2022";position:absolute;left:.35em;color:var(--accent)}
    .f-points{margin:1.2em 0 .4em;padding:.75em 1em;border-radius:12px;background:var(--block);font:.86em/1.45 ui-sans-serif,-apple-system,sans-serif}
    .f-points summary{font-weight:600;letter-spacing:.06em;text-transform:uppercase;font-size:.78em;color:var(--accent);cursor:default}
    .f-points ul{margin:.5em 0 0;padding-left:1.1em}.f-points li{margin:.35em 0}
    .f-li.f-ol::before{content:attr(data-n) ".";left:0;font-variant-numeric:tabular-nums;color:var(--fg2)}
    .f-li[data-depth="1"]{margin-left:1.4em}.f-li[data-depth="2"]{margin-left:2.8em}.f-li[data-depth="3"]{margin-left:4.2em}
    .f-pre{font:.8em/1.5 ui-monospace,Menlo,monospace;background:color-mix(in srgb,var(--fg) 6%,transparent);padding:.95em 1.05em;
      border-radius:12px;overflow-x:auto;white-space:pre;margin:1.2em 0}
    code{font-family:ui-monospace,Menlo,monospace;font-size:.86em;background:color-mix(in srgb,var(--fg) 7%,transparent);padding:.06em .3em;border-radius:5px}
    a{color:var(--accent);text-decoration-thickness:1px;text-underline-offset:.16em}
    sup,sub{line-height:0}
    mark{background:color-mix(in srgb,var(--word) 55%,transparent);color:inherit}
    .f-img{margin:1.7em calc(-1 * var(--margin))}
    .f-img img{display:block;width:100%;height:auto;background:color-mix(in srgb,var(--fg) 5%,transparent)}
    .f-img figcaption{font:.76em/1.45 ui-sans-serif,-apple-system,sans-serif;color:var(--fg2);padding:.65em var(--margin) 0}
    .f-rule{height:1px;margin:2.2em 0;text-align:center;line-height:0;color:var(--fg2)}
    .f-rule::after{content:"\2042";font-size:.9em;background:var(--bg);padding:0 .6em}
    .f-embed{display:flex;gap:.7em;align-items:center;padding:.85em 1em;margin:1.3em 0;border-radius:14px;text-decoration:none;color:var(--fg);
      border:1px solid color-mix(in srgb,var(--fg) 14%,transparent);font:.86em/1.3 ui-sans-serif,-apple-system,sans-serif}
    .f-embed-icon{color:var(--accent)}.f-embed-title{font-weight:600;flex:1}.f-embed-host{color:var(--fg2);font-size:.9em}
    .f-table{overflow-x:auto;margin:1.3em 0}
    .f-table table{border-collapse:collapse;font:.82em/1.4 ui-sans-serif,-apple-system,sans-serif;min-width:100%}
    .f-table th,.f-table td{border-bottom:1px solid color-mix(in srgb,var(--fg) 12%,transparent);padding:.45em .65em;text-align:left;vertical-align:top}
    .f-foot{margin-top:3.2em;padding-top:1.2em;border-top:1px solid color-mix(in srgb,var(--fg) 12%,transparent);
      font:.76em/1.55 ui-sans-serif,-apple-system,sans-serif;color:var(--fg2)}
    .f-foot p{margin:0 0 .4em;text-align:start}
    .f-speaking{background:var(--block);box-shadow:0 0 0 .4em var(--block);border-radius:.25em;transition:background-color .25s,box-shadow .25s}
    .f-speaking.f-sentence-on{background:transparent;box-shadow:none}
    ::highlight(folio-sentence){background-color:color-mix(in srgb,var(--word) 34%,transparent)}
    ::highlight(folio-word){background-color:var(--word);color:var(--fg)}
    mark.f-word{background:var(--word);color:inherit;border-radius:.15em}
    ::selection{background:color-mix(in srgb,var(--accent) 30%,transparent)}
    html.f-paged,html.f-paged body{height:100%;overflow:hidden}
    html.f-paged #f-article{max-width:none;height:100vh;margin:0;column-width:calc(100vw - 2 * var(--margin));
      column-gap:calc(2 * var(--margin));column-fill:auto;overflow:hidden;
      padding:calc(env(safe-area-inset-top) + 52px) var(--margin) calc(env(safe-area-inset-bottom) + 60px)}
    html.f-paged .f-img{margin:1.2em 0;break-inside:avoid}
    html.f-paged .f-img img{width:auto;max-width:100%;max-height:calc(100vh - 230px);margin:0 auto;object-fit:contain}
    html.f-paged .f-img figcaption{padding-left:0;padding-right:0}
    html.f-paged .f-head,html.f-paged .f-h{break-after:avoid}
    html.f-paged .f-pre,html.f-paged .f-embed,html.f-paged .f-quote{break-inside:avoid}
    @media (prefers-reduced-motion:reduce){*{transition:none!important;scroll-behavior:auto!important}}
    """#

    /// The reader's page API, exposed as `window.folio`.
    ///
    /// Native → page: `highlight(blockId, start, end, follow)`,
    /// `clearHighlight()`, `scrollToBlock(id, offset, animated)`,
    /// `applySettings(cssVariables, paged)`, `nextPage()`, `previousPage()`,
    /// `position()`.
    /// Page → native (message handler "folio"): `ready`, `position`, `tap`,
    /// `userScroll`. Offsets are UTF-16 code units, as in Swift's `Block.text`.
    public static let script = #"""
    (() => {
      if (window.folio) return;
      const root = document.documentElement;
      const article = document.getElementById('f-article');
      const post = (msg) => {
        try { window.webkit.messageHandlers.folio.postMessage(msg); }
        catch (_) { (window.__folioMessages = window.__folioMessages || []).push(msg); }
      };
      const supportsHighlights = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight === 'function';
      const isPaged = () => root.classList.contains('f-paged');
      let speakingEl = null, markEl = null, userScrolledAt = 0, page = 0;

      const textRoot = (el) => (el && el.tagName === 'FIGURE') ? (el.querySelector('figcaption') || el) : el;

      // Walks text nodes and <br> (one "\n") in document order.
      function walker(el) {
        return document.createTreeWalker(el, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
          acceptNode: (n) => n.nodeType === 3 ? NodeFilter.FILTER_ACCEPT
            : (n.tagName === 'BR' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP)
        });
      }

      function rangeFor(el, start, end) {
        const w = walker(el), range = document.createRange();
        let pos = 0, started = false, n;
        while ((n = w.nextNode())) {
          const len = n.nodeType === 3 ? n.data.length : 1;
          if (!started && start < pos + len) {
            if (n.nodeType === 3) range.setStart(n, start - pos); else range.setStartBefore(n);
            started = true;
          }
          if (started && end <= pos + len) {
            if (n.nodeType === 3) range.setEnd(n, Math.max(0, end - pos)); else range.setEndAfter(n);
            return range;
          }
          pos += len;
        }
        if (started) { range.setEnd(el, el.childNodes.length); return range; }
        return null;
      }

      function offsetOf(el, node, offset) {
        const w = walker(el);
        let pos = 0, n;
        while ((n = w.nextNode())) {
          if (n === node) return pos + (n.nodeType === 3 ? offset : 0);
          pos += n.nodeType === 3 ? n.data.length : 1;
        }
        return 0;
      }

      function caretAt(x, y) {
        if (document.caretRangeFromPoint) {
          const r = document.caretRangeFromPoint(x, y);
          return r ? { node: r.startContainer, offset: r.startOffset } : null;
        }
        if (document.caretPositionFromPoint) {
          const p = document.caretPositionFromPoint(x, y);
          return p ? { node: p.offsetNode, offset: p.offset } : null;
        }
        return null;
      }

      function unwrapMark() {
        if (!markEl) return;
        const parent = markEl.parentNode;
        while (markEl.firstChild) parent.insertBefore(markEl.firstChild, markEl);
        parent.removeChild(markEl);
        parent.normalize();
        markEl = null;
      }

      function clearHighlight() {
        if (supportsHighlights) { CSS.highlights.delete('folio-word'); CSS.highlights.delete('folio-sentence'); }
        unwrapMark();
        if (speakingEl) { speakingEl.classList.remove('f-speaking', 'f-sentence-on'); speakingEl = null; }
      }

      // Page geometry for paginated mode.
      const pageWidth = () => window.innerWidth;
      const pageCount = () => isPaged() ? Math.max(1, Math.round(article.scrollWidth / pageWidth())) : 1;

      function goToPage(p, report = true) {
        page = Math.min(Math.max(0, p), pageCount() - 1);
        article.scrollTo({ left: page * pageWidth(), behavior: 'instant' });
        if (report) reportPosition();
      }

      function pageOfRect(rect) {
        return Math.floor((rect.left + article.scrollLeft + 1) / pageWidth());
      }

      function ensureVisible(rect, force) {
        if (!rect || (!force && Date.now() - userScrolledAt < 4000)) return;
        if (isPaged()) {
          const p = pageOfRect(rect);
          if (p !== page) goToPage(p);
          return;
        }
        const top = 90, bottom = window.innerHeight - 150;
        if (force || rect.top < top || rect.bottom > bottom) {
          window.scrollBy({ top: rect.top - window.innerHeight * 0.32, behavior: force ? 'instant' : 'smooth' });
        }
      }

      // The sentence being read (sStart..<sEnd) is shaded under the word;
      // with a sentence shown, the paragraph tint steps back.
      function highlight(id, start, end, follow = true, sStart = 0, sEnd = 0) {
        const block = document.getElementById(id);
        if (!block) return false;
        if (speakingEl !== block) {
          if (speakingEl) speakingEl.classList.remove('f-speaking', 'f-sentence-on');
          block.classList.add('f-speaking');
          speakingEl = block;
        }
        if (supportsHighlights) { CSS.highlights.delete('folio-word'); CSS.highlights.delete('folio-sentence'); }
        unwrapMark();
        const el = textRoot(block);
        let rect = block.getBoundingClientRect();
        const sentence = supportsHighlights && sEnd > sStart ? rangeFor(el, sStart, sEnd) : null;
        block.classList.toggle('f-sentence-on', !!sentence);
        if (sentence) {
          const shade = new Highlight(sentence);
          shade.priority = 0;
          CSS.highlights.set('folio-sentence', shade);
          const rects = sentence.getClientRects();
          if (rects.length) rect = rects[0];
        }
        if (end > start) {
          const r = rangeFor(el, start, end);
          if (r) {
            if (supportsHighlights) {
              const word = new Highlight(r);
              word.priority = 1;
              CSS.highlights.set('folio-word', word);
            } else {
              try { markEl = document.createElement('mark'); markEl.className = 'f-word'; r.surroundContents(markEl); }
              catch (_) { markEl = null; }  // range crosses an element boundary; the block tint still shows
            }
            const rects = r.getClientRects();
            if (rects.length) rect = rects[0];
          }
        }
        if (follow) ensureVisible(rect, false);
        return true;
      }

      function scrollToBlock(id, offset = 0, animated = false) {
        const block = document.getElementById(id);
        if (!block) return false;
        let rect = block.getBoundingClientRect();
        if (offset > 0) {
          const r = rangeFor(textRoot(block), offset, offset + 1);
          const rects = r ? r.getClientRects() : [];
          if (rects.length) rect = rects[0];
        }
        if (isPaged()) { goToPage(pageOfRect(rect)); return true; }
        window.scrollTo({ top: Math.max(0, rect.top + window.scrollY - 88), behavior: animated ? 'smooth' : 'instant' });
        reportPosition();
        return true;
      }

      // The first block visible at the top of the reading area, with the
      // offset of the first visible character.
      function position() {
        const blocks = article.querySelectorAll('[data-b]');
        let found = null;
        if (isPaged()) {
          for (const b of blocks) {
            const rects = b.getClientRects();
            for (const r of rects) { if (r.right > 4 && r.left < pageWidth() - 4) { found = b; break; } }
            if (found) break;
          }
        } else {
          for (const b of blocks) { if (b.getBoundingClientRect().bottom > 80) { found = b; break; } }
        }
        let offset = 0;
        if (found && found.id !== 'title') {
          const r = found.getBoundingClientRect();
          const caret = caretAt(Math.max(r.left, 0) + 2, Math.max(r.top, isPaged() ? 0 : 80) + 4);
          const el = textRoot(found);
          if (caret && el.contains(caret.node)) offset = offsetOf(el, caret.node, caret.offset);
        }
        let progress;
        if (isPaged()) progress = pageCount() > 1 ? page / (pageCount() - 1) : 1;
        else {
          const max = document.documentElement.scrollHeight - window.innerHeight;
          progress = max > 0 ? Math.min(1, window.scrollY / max) : 1;
        }
        return { block: found ? found.id : null, offset, progress, page, pages: pageCount() };
      }

      let reportTimer = null;
      function reportPosition() {
        clearTimeout(reportTimer);
        reportTimer = setTimeout(() => post(Object.assign({ type: 'position' }, position())), 200);
      }

      function applySettings(vars, paged) {
        const before = position();
        for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
        root.classList.toggle('f-paged', !!paged);
        requestAnimationFrame(() => { if (before.block) scrollToBlock(before.block, before.offset); });
      }

      const nextPage = () => goToPage(page + 1);
      const previousPage = () => goToPage(page - 1);

      window.addEventListener('scroll', () => reportPosition(), { passive: true });
      window.addEventListener('resize', () => { if (isPaged()) goToPage(page, false); reportPosition(); });
      const markUserScroll = () => { userScrolledAt = Date.now(); post({ type: 'userScroll' }); };
      window.addEventListener('wheel', markUserScroll, { passive: true });

      let touchStart = null;
      window.addEventListener('touchstart', (e) => {
        const t = e.touches[0];
        touchStart = { x: t.clientX, y: t.clientY, time: Date.now() };
      }, { passive: true });
      window.addEventListener('touchmove', () => { if (!isPaged()) markUserScroll(); }, { passive: true });
      window.addEventListener('touchend', (e) => {
        if (!touchStart || !isPaged()) return;
        const t = e.changedTouches[0], dx = t.clientX - touchStart.x, dy = t.clientY - touchStart.y;
        if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy) * 1.5 && Date.now() - touchStart.time < 600) {
          userScrolledAt = Date.now();
          dx < 0 ? nextPage() : previousPage();
          touchStart = null;
          e.preventDefault();
        }
      });

      document.addEventListener('click', (e) => {
        if (e.target.closest('a')) return;
        const sel = window.getSelection();
        if (sel && !sel.isCollapsed) return;
        const block = e.target.closest('[data-b]');
        let offset = 0;
        if (block) {
          const caret = caretAt(e.clientX, e.clientY);
          const el = textRoot(block);
          if (caret && el.contains(caret.node)) offset = offsetOf(el, caret.node, caret.offset);
        }
        const x = e.clientX / window.innerWidth;
        const zone = x < 0.25 ? 'left' : (x > 0.75 ? 'right' : 'center');
        post({ type: 'tap', block: block ? block.id : null, offset, zone });
      });

      window.folio = { highlight, clearHighlight, scrollToBlock, applySettings, nextPage, previousPage, goToPage,
                       position, rangeFor, offsetOf };
      const ready = () => post(Object.assign({ type: 'ready' }, position()));
      if (document.readyState === 'complete') ready(); else window.addEventListener('load', ready);
    })();
    """#
}
