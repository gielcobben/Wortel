import Foundation

/// The script a page runs while it is being marked up.
///
/// It runs in a world of Wortel's own (`WebMarkupSurface.world`), so the page's
/// scripts see neither `__wortelMarkup` nor the message handler it posts to
/// (measured 2026-11-25), and it changes nothing in the page: no element is
/// added, no attribute set, no style touched. It only reads. The marks
/// themselves are drawn by the app, over the web view.
///
/// What it does: says what is under a point, remembers the element a mark is
/// tied to, and reports where those elements are whenever that may have
/// changed (a scroll anywhere in the page, a resize, the page changing
/// itself). It listens only between `start` and `stop`, and posts nothing
/// while there are no marks.
enum WebMarkupScript {
    static let handler = "wortelMarkup"

    static let source = ##"""
    (function () {
      if (window.__wortelMarkup) { return 1; }
      var marks = new Map();
      var listening = false;
      var queued = false;
      var watched = [];
      var mutations = null;
      var sizes = null;

      // Where a document inside a frame sits in the top page's view.
      function offsetOf(el) {
        var x = 0, y = 0, win = el.ownerDocument.defaultView;
        while (win && win !== window) {
          var frame = null;
          try { frame = win.frameElement; } catch (e) {}
          if (!frame) { break; }
          var r = frame.getBoundingClientRect();
          x += r.left + frame.clientLeft;
          y += r.top + frame.clientTop;
          win = frame.ownerDocument.defaultView;
        }
        return [x, y];
      }

      function rectOf(el) {
        var r = el.getBoundingClientRect(), o = offsetOf(el);
        return [r.left + o[0], r.top + o[1], r.width, r.height];
      }

      // The deepest element at a point of the view: through frames of the
      // page's own site and through open shadow roots. A frame from another
      // site is one thing, since nothing in it can be reached.
      function deepest(x, y) {
        var doc = document, ox = 0, oy = 0, el = null;
        for (var depth = 0; depth < 6; depth++) {
          var hit = doc.elementFromPoint(x - ox, y - oy);
          if (!hit) { break; }
          el = hit;
          for (var shadow = 0; shadow < 6 && el.shadowRoot; shadow++) {
            var inner = el.shadowRoot.elementFromPoint(x - ox, y - oy);
            if (!inner || inner === el) { break; }
            el = inner;
          }
          if (el.tagName !== 'IFRAME' && el.tagName !== 'FRAME') { break; }
          var content = null;
          try { content = el.contentDocument; } catch (e) {}
          if (!content) { break; }
          var r = el.getBoundingClientRect();
          ox += r.left + el.clientLeft;
          oy += r.top + el.clientTop;
          doc = content;
        }
        return el;
      }

      function isRoot(el) {
        return !el || el === el.ownerDocument.documentElement || el === el.ownerDocument.body;
      }

      // What cuts an element off: every scrolling or clipping box around it,
      // and every frame it is inside. And whether it stays put when the page
      // scrolls.
      function chainOf(el) {
        var chain = [], fixed = false, node = el;
        for (var guard = 0; node && guard < 400; guard++) {
          var view = node.ownerDocument.defaultView;
          if (view.getComputedStyle(node).position === 'fixed') { fixed = true; }
          var parent = node.parentElement;
          if (!parent) {
            var root = node.getRootNode ? node.getRootNode() : null;
            if (root && root.host) { node = root.host; continue; }
            var frame = null;
            try { frame = view.frameElement; } catch (e) {}
            if (!frame) { break; }
            chain.push(frame);
            node = frame;
            continue;
          }
          if (!isRoot(parent)) {
            var style = parent.ownerDocument.defaultView.getComputedStyle(parent);
            if (/(auto|scroll|hidden|clip)/.test(style.overflowX + ' ' + style.overflowY)) { chain.push(parent); }
          }
          node = parent;
        }
        return {chain: chain, fixed: fixed};
      }

      function clipOf(mark) {
        var l = 0, t = 0, r = window.innerWidth, b = window.innerHeight;
        for (var i = 0; i < mark.chain.length; i++) {
          var box = mark.chain[i];
          if (!box.isConnected) { continue; }
          var rect = rectOf(box);
          var bl = rect[0] + box.clientLeft, bt = rect[1] + box.clientTop;
          l = Math.max(l, bl);
          t = Math.max(t, bt);
          r = Math.min(r, bl + box.clientWidth);
          b = Math.min(b, bt + box.clientHeight);
        }
        return [l, t, Math.max(0, r - l), Math.max(0, b - t)];
      }

      function textOf(el, most) {
        var text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
        return text.length > most ? text.slice(0, most - 1) + '…' : text;
      }

      var words = {A: 'link', BUTTON: 'button', IMG: 'image', SVG: 'image', PICTURE: 'image',
                   INPUT: 'field', TEXTAREA: 'field', SELECT: 'menu', H1: 'heading', H2: 'heading',
                   H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading', P: 'paragraph',
                   LI: 'list item', NAV: 'navigation', VIDEO: 'video', LABEL: 'label'};

      // What a person would call it: a word for what it is, and what it says.
      function nameOf(el) {
        var tag = el.tagName.toUpperCase();
        var role = el.getAttribute('role');
        var word = role === 'button' || role === 'link' ? role : (words[tag] || el.tagName.toLowerCase());
        var says = el.getAttribute('aria-label') || el.getAttribute('alt') ||
                   el.getAttribute('placeholder') || textOf(el, 40) || el.getAttribute('title') || '';
        says = says.replace(/\s+/g, ' ').trim();
        if (says.length > 40) { says = says.slice(0, 39) + '…'; }
        if (says) { return word + ' "' + says + '"'; }
        if (el.id) { return word + ' #' + el.id; }
        var first = (el.getAttribute('class') || '').trim().split(/\s+/)[0];
        return first ? word + ' .' + first : word;
      }

      // A selector that finds this element and no other, as short as that
      // allows: its id, a test id, or the way down to it from the nearest id.
      function selectorOf(el) {
        var doc = el.ownerDocument;
        function alone(selector) {
          try { return doc.querySelectorAll(selector).length === 1; } catch (e) { return false; }
        }
        if (el.id) {
          var byId = '#' + CSS.escape(el.id);
          if (alone(byId)) { return byId; }
        }
        var test = el.getAttribute('data-testid');
        if (test) {
          var byTest = '[data-testid="' + test.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"]';
          if (alone(byTest)) { return byTest; }
        }
        var parts = [], node = el;
        while (node && node.nodeType === 1 && parts.length < 10) {
          var tag = node.tagName.toLowerCase();
          if (node !== el && node.id) {
            var anchor = '#' + CSS.escape(node.id);
            if (alone(anchor)) { parts.unshift(anchor); break; }
          }
          if (tag === 'html' || tag === 'body') {
            parts.unshift(tag);
          } else {
            var index = 1, sibling = node;
            while ((sibling = sibling.previousElementSibling)) {
              if (sibling.tagName === node.tagName) { index++; }
            }
            parts.unshift(tag + ':nth-of-type(' + index + ')');
          }
          if (alone(parts.join(' > '))) { break; }
          node = node.parentElement;
        }
        return parts.join(' > ');
      }

      function stylesOf(el) {
        var s = el.ownerDocument.defaultView.getComputedStyle(el), out = {};
        out['font'] = s.fontWeight + ' ' + s.fontSize + '/' + s.lineHeight + ' ' +
                      s.fontFamily.split(',')[0].trim();
        out['color'] = s.color;
        if (s.backgroundColor && s.backgroundColor !== 'rgba(0, 0, 0, 0)') { out['background'] = s.backgroundColor; }
        if (s.padding && s.padding !== '0px') { out['padding'] = s.padding; }
        if (s.margin && s.margin !== '0px') { out['margin'] = s.margin; }
        if (s.borderTopWidth !== '0px' && s.borderTopStyle !== 'none') {
          out['border'] = s.borderTopWidth + ' ' + s.borderTopStyle + ' ' + s.borderTopColor;
        }
        if (s.borderRadius && s.borderRadius !== '0px') { out['border-radius'] = s.borderRadius; }
        if (s.gap && s.gap !== 'normal') { out['gap'] = s.gap; }
        if (s.boxShadow && s.boxShadow !== 'none') { out['shadow'] = s.boxShadow; }
        var r = el.getBoundingClientRect();
        out['size'] = Math.round(r.width) + ' x ' + Math.round(r.height);
        return out;
      }

      function frameOf(el) {
        var frame = null;
        try { frame = el.ownerDocument.defaultView.frameElement; } catch (e) {}
        return frame && el.ownerDocument !== document ? selectorOf(frame) : null;
      }

      function detailsOf(el) {
        var html = el.outerHTML || '';
        return {tag: el.tagName.toLowerCase(), role: el.getAttribute('role'), name: nameOf(el),
                text: textOf(el, 200), selector: selectorOf(el), frame: frameOf(el),
                styles: stylesOf(el), html: html.length > 2000 ? html.slice(0, 2000) + '…' : html};
      }

      // The outermost elements that lie wholly inside a box.
      function inside(root, l, t, w, h) {
        var out = [];
        (function walk(node) {
          for (var child = node.firstElementChild; child && out.length < 20; child = child.nextElementSibling) {
            var r = rectOf(child);
            if (r[2] < 1 || r[3] < 1) { continue; }
            if (r[0] + r[2] <= l || r[1] + r[3] <= t || r[0] >= l + w || r[1] >= t + h) { continue; }
            if (r[0] >= l - 1 && r[1] >= t - 1 && r[0] + r[2] <= l + w + 1 && r[1] + r[3] <= t + h + 1) {
              out.push({name: nameOf(child), selector: selectorOf(child), text: textOf(child, 80)});
            } else {
              walk(child);
            }
          }
        })(root);
        return out;
      }

      function watch(doc) {
        if (!listening || watched.indexOf(doc) >= 0) { return; }
        doc.addEventListener('scroll', post, {capture: true, passive: true});
        watched.push(doc);
      }

      function keep(number, el) {
        // Tied again (a drawing that was moved): let go of what it was on.
        var was = marks.get(number);
        if (was && sizes && was.el.isConnected && was.el !== el) { sizes.unobserve(was.el); }
        var around = chainOf(el);
        var mark = {el: el, chain: around.chain, fixed: around.fixed,
                    selector: el.ownerDocument === document ? selectorOf(el) : null};
        marks.set(number, mark);
        watch(el.ownerDocument);
        if (sizes) { sizes.observe(el); }
        return mark;
      }

      function answer(mark) {
        return {rect: rectOf(mark.el), clip: clipOf(mark), fixed: mark.fixed,
                scroll: [window.scrollX, window.scrollY]};
      }

      // An element that left the page is looked for again by its selector:
      // a page that draws itself anew replaces its elements with like ones.
      function rebind(mark) {
        if (!mark.selector) { return; }
        var found = null;
        try { found = document.querySelectorAll(mark.selector); } catch (e) {}
        if (!found || found.length !== 1) { return; }
        mark.el = found[0];
        var around = chainOf(mark.el);
        mark.chain = around.chain;
        mark.fixed = around.fixed;
        if (sizes) { sizes.observe(mark.el); }
      }

      function report() {
        var root = document.documentElement, body = document.body;
        var out = [window.scrollX, window.scrollY, window.innerWidth, window.innerHeight,
                   Math.max(root.scrollWidth, body ? body.scrollWidth : 0),
                   Math.max(root.scrollHeight, body ? body.scrollHeight : 0)];
        marks.forEach(function (mark, number) {
          if (!mark.el.isConnected) { rebind(mark); }
          var flags = mark.fixed ? 2 : 0;
          if (!mark.el.isConnected) {
            out.push(number, 0, 0, 0, 0, 0, 0, 0, 0, flags | 1);
            return;
          }
          var r = rectOf(mark.el), c = clipOf(mark);
          out.push(number, r[0], r[1], r[2], r[3], c[0], c[1], c[2], c[3], flags);
        });
        return out;
      }

      function post() {
        if (!listening || marks.size === 0) { return; }
        try { webkit.messageHandlers.wortelMarkup.postMessage(report()); } catch (e) {}
      }

      function later() {
        if (queued || marks.size === 0) { return; }
        queued = true;
        requestAnimationFrame(function () { queued = false; post(); });
      }

      function start() {
        if (listening) { return 1; }
        listening = true;
        watch(document);
        marks.forEach(function (mark) { if (mark.el.isConnected) { watch(mark.el.ownerDocument); } });
        window.addEventListener('resize', later, {passive: true});
        mutations = new MutationObserver(later);
        mutations.observe(document.documentElement, {subtree: true, childList: true, attributes: true,
                                                     attributeFilter: ['class', 'style', 'hidden', 'open']});
        sizes = new ResizeObserver(later);
        marks.forEach(function (mark) { if (mark.el.isConnected) { sizes.observe(mark.el); } });
        return 1;
      }

      function stop() {
        if (!listening) { return 1; }
        listening = false;
        watched.forEach(function (doc) { doc.removeEventListener('scroll', post, {capture: true}); });
        watched = [];
        window.removeEventListener('resize', later);
        if (mutations) { mutations.disconnect(); mutations = null; }
        if (sizes) { sizes.disconnect(); sizes = null; }
        return 1;
      }

      window.__wortelMarkup = {
        start: start,
        stop: stop,
        report: report,
        probe: function (x, y) {
          var el = deepest(x, y);
          return isRoot(el) ? null : rectOf(el);
        },
        pick: function (number, x, y) {
          var el = deepest(x, y);
          if (isRoot(el)) { return null; }
          var out = answer(keep(number, el));
          out.details = detailsOf(el);
          return out;
        },
        tie: function (number, l, t, w, h) {
          var el = deepest(l + w / 2, t + h / 2) || document.body || document.documentElement;
          for (var guard = 0; guard < 400; guard++) {
            var r = rectOf(el);
            if (r[0] <= l + 0.5 && r[1] <= t + 0.5 && r[0] + r[2] >= l + w - 0.5 && r[1] + r[3] >= t + h - 0.5) { break; }
            var up = el.parentElement;
            if (!up) {
              var root = el.getRootNode ? el.getRootNode() : null;
              if (root && root.host) { up = root.host; }
            }
            if (!up) {
              try { up = el.ownerDocument.defaultView.frameElement; } catch (e) {}
            }
            if (!up) { break; }
            el = up;
          }
          var out = answer(keep(number, el));
          out.details = {tag: el.tagName.toLowerCase(), selector: selectorOf(el), frame: frameOf(el),
                         elements: inside(el, l, t, w, h)};
          return out;
        },
        forget: function (number) {
          var mark = marks.get(number);
          if (mark && sizes && mark.el.isConnected) { sizes.unobserve(mark.el); }
          marks.delete(number);
          return 1;
        },
        destroy: function () {
          stop();
          marks.clear();
          delete window.__wortelMarkup;
          return 1;
        }
      };
      return 1;
    })()
    """##
}
