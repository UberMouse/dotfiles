// ==UserScript==
// @name         Reddit: no auth wall
// @namespace    taylorl.dotfiles
// @version      1.0.0
// @description  Defuses Reddit's logged-out signup nags: the blocking "Join the most real place on the internet" interstitial, the left-rail signup banner, and the Google One Tap prompt.
// @author       Taylor Lodge
// @match        https://*.reddit.com/*
// @run-at       document-start
// @grant        none
// @noframes
// @updateURL    https://raw.githubusercontent.com/UberMouse/dotfiles/master/userscripts/reddit-no-authwall.user.js
// @downloadURL  https://raw.githubusercontent.com/UberMouse/dotfiles/master/userscripts/reddit-no-authwall.user.js
// ==/UserScript==

// How the interstitial actually works (captured from a session that got it):
//
//   <template id="deferred-desktop_auth_blocking_upsell">
//     <desktop-dynamic-upsell-modal>
//       <rpl-dialog-sheet id="desktop-dynamic-upsell" blocking> ... </rpl-dialog-sheet>
//   <ac-render-template template="#deferred-desktop_auth_blocking_upsell"
//                       trigger="event(render-deferred-experience({...}))">
//   <template id="deferred-desktop_auth_blocking_upsell-trigger">
//     <ac-activate args='{"bodyParams":{"experienceKey":"desktop_auth_blocking_upsell"}}'>
//   <ac-render-template delay="30000" template="#deferred-...-trigger" trigger="init">
//
// So: 30s after page init Reddit renders the trigger template, which calls
// /svc/shreddit/partial/*/activate-experience, whose response fires a
// `render-deferred-experience` window event, which clones the modal template
// into the DOM. Killing the templates removes the source before anything can
// clone it, so the <dialog> is never created at all.
//
// This matters: `rpl-dialog-sheet blocking` opens a real modal <dialog>, and a
// showModal() dialog makes the rest of the page `inert`. Hiding it with CSS
// alone leaves the page visually fine but dead to clicks and scrolling — which
// is why this needs JS, not just a cosmetic filter.

(function () {
  'use strict';

  // --- 1. cosmetic: left rail + one tap, and a fallback for the interstitial ---

  const CSS = `
    /* The logged-out left rail is nothing but the signup banner, so drop the
       whole container and collapse the 315px grid column it sat in. */
    #left-sidebar-container:has(faceplate-tracker[noun="static_left_rail_banner"]) {
      display: none !important;
    }
    .grid-container.flex-nav-upsell {
      grid-template-columns: 0 1fr !important;
    }

    /* Google One Tap, bottom of the viewport. Delete these two lines if you
       ever want it back. */
    auth-flow-google-one-tap-prompt {
      display: none !important;
    }

    /* Belt and braces only — the JS below should mean these never exist.
       Not sufficient on its own: see the note about inert, above. */
    desktop-dynamic-upsell-modal,
    rpl-dialog-sheet#desktop-dynamic-upsell {
      display: none !important;
    }
  `;

  // At document-start there may be no <html> yet, let alone <head> — appending
  // blind throws and takes the whole script with it. Re-check on every sweep,
  // which also re-adds the style if Reddit ever removes it.
  let styleEl = null;

  function ensureStyle() {
    if (styleEl && styleEl.isConnected) return;
    const root = document.head || document.documentElement;
    if (!root) return;
    styleEl = document.createElement('style');
    styleEl.textContent = CSS;
    root.appendChild(styleEl);
  }

  // --- 2. the real kill: remove the templates before they are ever cloned ---

  const KEY = 'desktop_auth_blocking_upsell';

  // Note: there is deliberately no rule for <ac-render-template> / <ac-activate>.
  // Both delete themselves synchronously in connectedCallback (verified: the
  // element is already detached on the line after appendChild, and a loaded
  // Reddit page contains zero of them), so a selector for either could never
  // match. The templates are the thing that persists, so they are the target.
  const SELECTORS = [
    // the source templates, removed before anything can clone them
    `template[id^="deferred-${KEY}"]`,
    // and the rendered result, if it ever gets through anyway
    'desktop-dynamic-upsell-modal',
    'rpl-dialog-sheet#desktop-dynamic-upsell',
  ].join(',');

  // A showModal() dialog inerts everything outside itself and locks scroll.
  // Removing the dialog drops it out of the top layer, but Reddit may also have
  // set these itself, so undo them explicitly whenever we remove something.
  function unstick() {
    for (const el of document.querySelectorAll('[inert]')) {
      el.removeAttribute('inert');
    }
    for (const el of [document.documentElement, document.body]) {
      if (el && el.style.overflow === 'hidden') el.style.removeProperty('overflow');
    }
  }

  function sweep() {
    ensureStyle();

    let removed = 0;

    for (const el of document.querySelectorAll(SELECTORS)) {
      // close any open dialog first; rpl-dialog-sheet keeps its <dialog> in a
      // shadow root, so look in both places.
      for (const root of [el, el.shadowRoot]) {
        if (!root) continue;
        for (const dialog of root.querySelectorAll('dialog[open]')) {
          try { dialog.close(); } catch (e) { /* already closed */ }
        }
      }
      el.remove();
      removed++;
    }

    if (removed) unstick();
    return removed;
  }

  // --- 3. also refuse the event that triggers the clone ---
  // Cheap extra layer: survives Reddit renaming the template ids, as long as
  // the experience key stays recognisable. Scoped to the auth upsell so other
  // deferred experiences still work.

  window.addEventListener('render-deferred-experience', function (e) {
    const detail = e.detail || {};
    const key = detail.experienceKey ||
      (detail.bodyParams && detail.bodyParams.experienceKey) || '';
    if (/upsell|auth/i.test(String(key))) {
      e.stopImmediatePropagation();
      e.preventDefault();
    }
  }, true);

  // --- 4. keep sweeping: the page streams in, and Reddit is an SPA ---
  // Coalesced so feed scrolling doesn't pay for this. setTimeout rather than
  // requestAnimationFrame because rAF is throttled in background tabs, and the
  // 30s timer keeps running there.

  let scheduled = false;
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    setTimeout(function () {
      scheduled = false;
      sweep();
    }, 0);
  }

  // Observe `document`, not `document.documentElement` — at document-start the
  // latter can still be null, and observing the document catches it appearing.
  new MutationObserver(schedule)
    .observe(document, { childList: true, subtree: true });

  sweep();
})();
