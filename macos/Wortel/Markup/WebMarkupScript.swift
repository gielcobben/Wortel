import Foundation

/// The script a page runs while it is being marked up.
///
/// It runs in a world of Wortel's own (`WebMarkupSurface.world`), so the page's
/// scripts see neither `__wortelMarkup` nor the message handler it posts to
/// (measured 2026-11-25), and it changes nothing in the page: no element is
/// added, no attribute set, no style touched. It only reads, and scrolls when
/// a mark is to be brought into view. The marks themselves are drawn by the
/// app, over the web view.
///
/// What it does: says what is under a point, remembers the element a mark is
/// tied to, and reports where those elements are whenever that may have
/// changed (a scroll anywhere in the page, a resize, the page changing
/// itself). It listens only between `start` and `stop`, and posts nothing
/// while there are no marks.
///
/// **A page moves things without changing itself.** A transition or an
/// animation runs for its length with no event a step, a picture that
/// arrives pushes down what is under it, and neither is a scroll, a resize
/// or a mutation. So whatever starts or ends such a move starts a look
/// every frame (`follow`), which goes on while something still moves and
/// for a moment after, and then stops: nothing runs on a page that is
/// still. Measured 2026-11-25, each with the mark left there for good
/// until the next scroll: a fixed header sliding away over 300 ms, 30pt;
/// a button moved 50px by a CSS animation or by a script's, 50pt; mark-up
/// turned on 60 ms into the header's slide, 10pt.
///
/// Its JavaScript keeps to `var` and `function` on purpose: leave it so. It
/// reads from top to bottom: where things are, what an element is called,
/// the report, the look every frame, the listeners, tying a mark, and
/// bringing one into view. The table at its end is what the app calls
/// (`WebMarkupSurface`).
enum WebMarkupScript {
    static let handler = "wortelMarkup"

    static let source = ##"""
    (function () {
      if (window.__wortelMarkup) { return 1; }
      // A mark by its number: the element it is on, the boxes and frames
      // that cut it off, whether it stays put, and a selector to find the
      // element again by.
      var marks = new Map();
      var listening = false;
      // The documents listened to: the page's, and each frame's a mark is in.
      var watched = [];
      var mutations = null;
      var sizes = null;
      // A report is owed at the next frame.
      var queued = false;
      // The look every frame is running.
      var looking = false;
      var lastPosted = '';
      var lastMoved = 0;
      // What begins or ends a move that no scroll, resize or mutation
      // tells of. `load` is a picture, a frame or a stylesheet arriving.
      var moves = ['transitionrun', 'transitionstart', 'transitionend', 'transitioncancel',
                   'animationstart', 'animationiteration', 'animationend', 'animationcancel', 'load'];
      // How long after the last move the look goes on, in ms: past an
      // easing's slow end, and past a frame or two that were dropped.
      var patience = 400;

      // Where things are. Every rect is [left, top, width, height] in the
      // top page's view, in CSS pixels.

      // The frame a window is shown in. None for the top page, and for a
      // window that will not say.
      function frameAround(win) {
        try { return win.frameElement; } catch (e) { return null; }
      }

      // Where a document inside a frame sits in the top page's view.
      function offsetOf(el) {
        var x = 0, y = 0, win = el.ownerDocument.defaultView;
        while (win && win !== window) {
          var frame = frameAround(win);
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

      function isRoot(el) {
        return !el || el === el.ownerDocument.documentElement || el === el.ownerDocument.body;
      }

      function isFrame(el) {
        return el.tagName === 'IFRAME' || el.tagName === 'FRAME';
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
          if (!isFrame(el)) { break; }
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

      // What an element is inside: its parent, the host of its shadow root,
      // or the frame its document is in.
      function above(el) {
        if (el.parentElement) { return el.parentElement; }
        var root = el.getRootNode ? el.getRootNode() : null;
        if (root && root.host) { return root.host; }
        return frameAround(el.ownerDocument.defaultView);
      }

      // Whether `el` is `top` or inside it, through shadow roots and frames.
      function isInside(el, top) {
        for (var guard = 0; el && guard < 400; guard++) {
          if (el === top) { return true; }
          el = above(el);
        }
        return false;
      }

      // Whether a box scrolls or clips what is inside it.
      function clips(el) {
        var style = el.ownerDocument.defaultView.getComputedStyle(el);
        return /(auto|scroll|hidden|clip)/.test(style.overflowX + ' ' + style.overflowY);
      }

      // Whether what is inside `el` is cut off where `el` ends.
      function cuts(el) {
        if (isFrame(el)) { return true; }
        return !isRoot(el) && clips(el);
      }

      // What has a box of its own in a line of text.
      var solid = /^(img|svg|video|canvas|picture|iframe|object|embed|input|button|select|textarea)$/i;

      // What a drawn area is on, to follow: the block under its middle.
      // Not `within`, the element that holds all of it, which is often the
      // whole column: text added above a paragraph moves the paragraph in
      // its column and leaves the column where it was (measured 2026-11-25:
      // a paragraph added above two areas tied to the column, and both
      // stayed 76pt above their words). But never something inside a box
      // that cuts off and that the area reaches out of: the area would be
      // cut off with it.
      function blockUnder(under, within) {
        var on = under;
        for (var guard = 0; guard < 400 && on !== within; guard++) {
          var style = on.ownerDocument.defaultView.getComputedStyle(on), box = on.getBoundingClientRect();
          // A picture in a line of text has a box of its own; a link or a
          // word in bold is a run of the line, which breaks where it wraps.
          var boxed = (style.display !== 'inline' && style.display !== 'contents') || solid.test(on.tagName);
          if (boxed && box.width >= 1 && box.height >= 1) { break; }
          var up = above(on);
          if (!up) { break; }
          on = up;
        }
        var node = on;
        for (var limit = 0; limit < 400 && node !== within; limit++) {
          var out = above(node);
          if (!out || out === within) { break; }
          if (cuts(out)) { on = out; }
          node = out;
        }
        return on;
      }

      // What cuts an element off: every scrolling or clipping box around it,
      // and every frame it is inside. And whether it stays put when the page
      // scrolls.
      function chainOf(el) {
        var chain = [], fixed = false, node = el;
        for (var guard = 0; node && guard < 400; guard++) {
          var win = node.ownerDocument.defaultView;
          if (win.getComputedStyle(node).position === 'fixed') { fixed = true; }
          var parent = node.parentElement;
          if (!parent) {
            var root = node.getRootNode ? node.getRootNode() : null;
            if (root && root.host) { node = root.host; continue; }
            var frame = frameAround(win);
            if (!frame) { break; }
            chain.push(frame);
            node = frame;
            continue;
          }
          if (!isRoot(parent) && clips(parent)) { chain.push(parent); }
          node = parent;
        }
        return {chain: chain, fixed: fixed};
      }

      // The part of the view a mark may show in: what every box of its
      // chain leaves of the window.
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

      // What an element is called, for the note and the details file.

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

      // The styles someone asking for a change would name, and no others.
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

      // The selector of the frame an element is in, when it is in one.
      function frameOf(el) {
        var frame = frameAround(el.ownerDocument.defaultView);
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

      // The report: where every mark is now.

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

      // One flat list of numbers, as `WebMarkReport` reads it: the page's
      // scroll, the view's size and the page's, then ten a mark: its
      // number, its rect, its clip, and its flags (1 for an element that is
      // gone, 2 for one that stays put).
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

      function send(out) {
        lastPosted = out.join();
        try { webkit.messageHandlers.wortelMarkup.postMessage(out); } catch (e) {}
      }

      function post() {
        if (!listening || marks.size === 0) { return; }
        send(report());
      }

      // At the next frame, and once for however many changes came before it.
      function later() {
        if (queued || marks.size === 0) { return; }
        queued = true;
        requestAnimationFrame(function () { queued = false; post(); });
      }

      // The look every frame, for what moves with no word of it.

      // Whether an animation with an end is running on the page's own
      // clock. One without an end (a spinner) would keep the look going
      // for as long as mark-up is on, and one on a scroll's timeline only
      // moves when the page scrolls, which is heard anyway.
      function moving() {
        try {
          var all = document.getAnimations();
          for (var i = 0; i < all.length; i++) {
            var one = all[i];
            if (one.playState !== 'running' || !one.effect || one.timeline !== document.timeline) { continue; }
            if (isFinite(one.effect.getComputedTiming().endTime)) { return true; }
          }
        } catch (e) {}
        return false;
      }

      // Look every frame, and say so when a mark's place changed, until
      // nothing has moved for a while.
      function follow() {
        lastMoved = performance.now();
        if (looking || !listening || marks.size === 0) { return; }
        looking = true;
        requestAnimationFrame(function step() {
          if (!listening || marks.size === 0) { looking = false; return; }
          var out = report(), now = performance.now();
          if (out.join() !== lastPosted) { send(out); lastMoved = now; }
          if (now - lastMoved < patience || moving()) { requestAnimationFrame(step); } else { looking = false; }
        });
      }

      // Every scroll is answered at once, moved or not: the app is waiting
      // to hear. And a scroll is what most often sets a page moving (a
      // part that comes in as it is reached, by a script's own animation,
      // which has no event to hear), so the look begins too.
      function scrolled() {
        post();
        follow();
      }

      // Listening, between `start` and `stop` and never outside them.

      function watch(doc) {
        if (!listening || watched.indexOf(doc) >= 0) { return; }
        doc.addEventListener('scroll', scrolled, {capture: true, passive: true});
        moves.forEach(function (name) { doc.addEventListener(name, follow, {capture: true, passive: true}); });
        watched.push(doc);
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
        // The page growing or shrinking is how something that arrived late
        // and pushed the rest down is heard of when no mark is on it.
        sizes.observe(document.documentElement);
        if (document.body) { sizes.observe(document.body); }
        // Turned on while something is on its way (a header sliding in
        // after the scroll that came before): the first report is of where
        // it was passing.
        follow();
        return 1;
      }

      function stop() {
        if (!listening) { return 1; }
        listening = false;
        watched.forEach(function (doc) {
          doc.removeEventListener('scroll', scrolled, {capture: true});
          moves.forEach(function (name) { doc.removeEventListener(name, follow, {capture: true}); });
        });
        watched = [];
        window.removeEventListener('resize', later);
        if (mutations) { mutations.disconnect(); mutations = null; }
        if (sizes) { sizes.disconnect(); sizes = null; }
        return 1;
      }

      // Tying a mark to an element.

      // An element is no longer watched for its size once no other mark
      // is on it. Two can share one: two areas over one paragraph, or an
      // area and the element picked under it.
      function release(el, number) {
        if (!sizes || !el.isConnected || isRoot(el)) { return; }
        var shared = false;
        marks.forEach(function (other, n) { if (n !== number && other.el === el) { shared = true; } });
        if (!shared) { sizes.unobserve(el); }
      }

      function keep(number, el) {
        // Tied again (a drawing that was moved): let go of what it was on.
        var was = marks.get(number);
        if (was && was.el !== el) { release(was.el, number); }
        var around = chainOf(el);
        var mark = {el: el, chain: around.chain, fixed: around.fixed,
                    selector: el.ownerDocument === document ? selectorOf(el) : null};
        marks.set(number, mark);
        watch(el.ownerDocument);
        if (sizes) { sizes.observe(el); }
        // It may be on its way somewhere: a part of the page still coming in.
        follow();
        return mark;
      }

      // Where a mark just tied is, so it is drawn before the next report.
      function answer(mark) {
        return {rect: rectOf(mark.el), clip: clipOf(mark), fixed: mark.fixed,
                scroll: [window.scrollX, window.scrollY]};
      }

      // What a click at a point would pick, to outline it.
      function probe(x, y) {
        var el = deepest(x, y);
        return isRoot(el) ? null : rectOf(el);
      }

      // An element picked before is that mark again, not a second one.
      // Only the marks named in `picked` count: a drawing is tied to an
      // element too, and that element can still be picked.
      function pick(number, x, y, picked) {
        var el = deepest(x, y);
        if (isRoot(el)) { return null; }
        for (var i = 0; picked && i < picked.length; i++) {
          var was = marks.get(picked[i]);
          if (was && !was.el.isConnected) { rebind(was); }
          if (was && was.el === el) { return {already: picked[i]}; }
        }
        var out = answer(keep(number, el));
        out.details = detailsOf(el);
        return out;
      }

      // A drawn area: followed by the block under its middle, and
      // described by the element that holds all of it.
      function tie(number, l, t, w, h) {
        var under = deepest(l + w / 2, t + h / 2) || document.body || document.documentElement;
        // What holds all of the area: that is what is said about it.
        var el = under;
        for (var guard = 0; guard < 400; guard++) {
          var r = rectOf(el);
          if (r[0] <= l + 0.5 && r[1] <= t + 0.5 && r[0] + r[2] >= l + w - 0.5 && r[1] + r[3] >= t + h - 0.5) { break; }
          var up = above(el);
          if (!up) { break; }
          el = up;
        }
        // The middle of an area around a few paragraphs is as likely
        // between two of them as on one: then a quarter of the way in,
        // from each side in turn.
        var on = blockUnder(under, el);
        var tries = [[0.5, 0.25], [0.5, 0.75], [0.25, 0.5], [0.75, 0.5]];
        for (var i = 0; i < tries.length && on === el; i++) {
          var hit = deepest(l + w * tries[i][0], t + h * tries[i][1]);
          if (hit && isInside(hit, el)) { on = blockUnder(hit, el); }
        }
        var out = answer(keep(number, on));
        out.details = {tag: el.tagName.toLowerCase(), selector: selectorOf(el), frame: frameOf(el),
                       elements: inside(el, l, t, w, h)};
        return out;
      }

      function forget(number) {
        var mark = marks.get(number);
        if (mark) { release(mark.el, number); }
        marks.delete(number);
        return 1;
      }

      // Bringing a mark into view.

      // How far a box has to move to show in a room: `MarkReveal.shift`,
      // the same rule in the page's own units. Nothing when it is inside;
      // to the middle where it fits; its start to the room's where not.
      function shift(box, room) {
        function along(start, length, roomStart, roomLength) {
          if (start >= roomStart - 0.5 && start + length <= roomStart + roomLength + 0.5) { return 0; }
          if (length <= roomLength) { return (roomStart + roomLength / 2) - (start + length / 2); }
          return roomStart - start;
        }
        if (room[2] <= 0 || room[3] <= 0) { return [0, 0]; }
        return [along(box[0], box[2], room[0], room[2]), along(box[1], box[3], room[1], room[3])];
      }

      // Scroll a box's holder so the box moves by `d`, as far as the holder
      // goes, and say where the box is then. Worked out and not read back:
      // an eased scroll has not moved yet when the next holder is measured.
      function slide(scroller, box, d, how) {
        if (!d[0] && !d[1]) { return box; }
        var left = scroller.scrollLeft, top = scroller.scrollTop;
        var toLeft = Math.max(0, Math.min(left - d[0], scroller.scrollWidth - scroller.clientWidth));
        var toTop = Math.max(0, Math.min(top - d[1], scroller.scrollHeight - scroller.clientHeight));
        scroller.scrollTo({left: toLeft, top: toTop, behavior: how});
        return [box[0] - (toLeft - left), box[1] - (toTop - top), box[2], box[3]];
      }

      // How far down from the top, and up to where from `bottom`, the view
      // shows the page: a fixed or sticky header or footer that the mark
      // is not inside covers what is under it.
      function covered(mark, bottom) {
        function over(x, y) {
          var el = document.elementFromPoint(x, y);
          for (var guard = 0; el && guard < 60; guard++, el = el.parentElement) {
            var position = getComputedStyle(el).position;
            if (position !== 'fixed' && position !== 'sticky') { continue; }
            if (el.contains(mark.el)) { return null; }
            var r = el.getBoundingClientRect();
            return r.height < window.innerHeight / 2 ? r : null;
          }
          return null;
        }
        var top = 0, end = bottom, w = window.innerWidth;
        [0.2, 0.5, 0.8].forEach(function (f) {
          var high = over(w * f, 1);
          if (high && high.top <= 1) { top = Math.max(top, high.bottom); }
          var low = over(w * f, window.innerHeight - 1);
          if (low && low.bottom >= window.innerHeight - 1) { end = Math.min(end, low.top); }
        });
        // A page that covers nearly all of itself (a cookie wall) would
        // leave no room to show anything in: then the covers are ignored.
        return end - top < 80 ? [0, bottom] : [top, end];
      }

      // The mark's own box (`part`, from its element's corner, or the
      // whole element) into what shows: each scrolling box it is inside,
      // then the window less the note bar (`below`) and what the page
      // keeps over its own edges. Not `scrollIntoView`: that centres the
      // element, which for a drawn box is whatever holds all of it, and
      // it counts what the note bar and a fixed header cover as shown.
      function reveal(number, part, below, smooth) {
        var mark = marks.get(number);
        if (!mark || !mark.el.isConnected) { return 0; }
        var r = rectOf(mark.el);
        var box = part ? [r[0] + part[0], r[1] + part[1], part[2], part[3]] : r;
        var how = smooth ? 'smooth' : 'instant';
        for (var i = 0; i < mark.chain.length; i++) {
          var holder = mark.chain[i], scroller = holder;
          if (!holder.isConnected) { continue; }
          if (isFrame(holder)) {
            scroller = null;
            try { scroller = holder.contentDocument.scrollingElement; } catch (e) {}
          } else {
            var style = holder.ownerDocument.defaultView.getComputedStyle(holder);
            if (!/(auto|scroll)/.test(style.overflowX + ' ' + style.overflowY)) { scroller = null; }
          }
          if (!scroller) { continue; }
          var h = rectOf(holder);
          box = slide(scroller, box, shift(box, [h[0] + holder.clientLeft, h[1] + holder.clientTop,
                                                 holder.clientWidth, holder.clientHeight]), how);
        }
        if (mark.fixed) { return 1; }
        var edges = covered(mark, Math.max(0, window.innerHeight - (below || 0)));
        var d = shift(box, [0, edges[0], window.innerWidth, Math.max(0, edges[1] - edges[0])]);
        if (d[0] || d[1]) {
          window.scrollTo({left: window.scrollX - d[0], top: window.scrollY - d[1], behavior: how});
        }
        return 1;
      }

      // Out of the page: nothing is left of the script.
      function destroy() {
        stop();
        marks.clear();
        delete window.__wortelMarkup;
        return 1;
      }

      window.__wortelMarkup = {start: start, stop: stop, report: report, probe: probe, pick: pick, tie: tie,
                               reveal: reveal, forget: forget, destroy: destroy};
      return 1;
    })()
    """##
}
