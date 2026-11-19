import Foundation

/// The page a phone opens from Inquiline's door (PhoneRemoteDoor): a controller, a touchpad
/// and the assistant, for the app window in front on the Mac. One page, as the phone loads it
/// from the Mac alone; it can live on the phone's home screen as an app.
enum PhoneRemotePage {
    /// `port` is the door's control socket; `macName` the Mac's name on the network, which stays
    /// when the router gives the Mac another address.
    static func html(port: Int, token: String, macName: String) -> String {
        template
            .replacingOccurrences(of: "{{PORT}}", with: String(port))
            .replacingOccurrences(of: "{{TOKEN}}", with: token)
            .replacingOccurrences(of: "{{NAME}}", with: macName)
    }

    /// For adding the page to a phone's home screen as an app of its own.
    static func manifest(token: String) -> String {
        """
        {"name": "Inquiline Remote", "short_name": "Inquiline", "start_url": "/\(token)", "scope": "/\(token)",
         "display": "fullscreen", "orientation": "landscape", "background_color": "#111214", "theme_color": "#111214",
         "icons": [{"src": "/\(token)/icon.png", "sizes": "512x512", "type": "image/png"}]}
        """
    }

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Inquiline">
<link rel="manifest" href="/{{TOKEN}}/manifest.json">
<link rel="apple-touch-icon" href="/{{TOKEN}}/icon.png">
<meta name="theme-color" content="#111214">
<title>Inquiline</title>
<style>
  :root { --bg: #0e0f11; --panel: #17181b; --key: #24262b; --edge: #33363d; --text: #f2f2f4; --dim: #8b8d94;
    --glow: rgba(120,160,255,.55); }
  * { box-sizing: border-box; -webkit-user-select: none; user-select: none; -webkit-tap-highlight-color: transparent;
      touch-action: none; -webkit-touch-callout: none; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
    font: 15px -apple-system, system-ui, sans-serif; overflow: hidden; touch-action: none; }
  body { display: flex; flex-direction: column; padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  header { display: flex; align-items: center; gap: 10px; padding: 6px 14px; }
  #dot { width: 9px; height: 9px; border-radius: 50%; background: #e5534b; flex: none; }
  #dot.on { background: #3fb950; }
  #title { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 1; }
  nav { display: flex; gap: 3px; background: var(--panel); border-radius: 9px; padding: 3px; }
  nav button { border: 0; background: none; color: var(--dim); font: inherit; font-size: 14px; padding: 5px 12px; border-radius: 7px; }
  nav button.on { background: var(--key); color: var(--text); }
  #assistant { border: 0; border-radius: 16px; padding: 6px 14px; font: inherit; font-size: 14px; font-weight: 600;
    color: var(--text); background: linear-gradient(135deg, #4b7bec, #a55eea); }
  main { flex: 1; position: relative; }
  section { position: absolute; inset: 0; display: none; }
  section.on { display: block; }

  /* The controller, laid out as an Xbox pad on a body of one shape, 2.1 wide for 1 high, as
     large as fits and centered, so it looks the same on any phone and nothing stretches:
     positions in percent of the body's width and height, sizes in its height. */
  #deck { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%);
    width: min(100%, calc((100vh - 52px) * 2.1)); aspect-ratio: 2.1 / 1; max-height: 100%; container-type: size; }
  .at { position: absolute; left: calc(var(--x) * 1cqw + var(--dx, 0) * 1cqh); top: calc(var(--y) * 1cqh);
    width: calc(var(--d) * 1cqh); height: calc(var(--d) * 1cqh); transform: translate(-50%, -50%); }
  .key { display: flex; align-items: center; justify-content: center; background: var(--key);
    border: 1.5px solid var(--edge); color: var(--text); font-weight: 700; border-radius: 50%;
    box-shadow: 0 3px 0 rgba(0,0,0,.45); transition: transform .05s, box-shadow .05s, background .05s; }
  .key.on { transform: translate(-50%, -50%) scale(.94); box-shadow: 0 0 calc(4cqh) var(--glow); background: #2e3138; }
  .face { font-size: calc(7cqh); }
  .face[data-b="a"] { color: #5cd65c; } .face[data-b="b"] { color: #ff5c5c; }
  .face[data-b="x"] { color: #4fa3ff; } .face[data-b="y"] { color: #ffd23f; }
  .bumper { width: calc(var(--w) * 1cqw); height: calc(var(--h) * 1cqh); border-radius: calc(3cqh); font-size: calc(4.5cqh); color: var(--dim); }
  .small { font-size: calc(4.5cqh); color: var(--dim); }
  .stick { border-radius: 50%; background: radial-gradient(circle, #1b1c20 55%, #121316 100%); border: 1.5px solid var(--edge); }
  .knob { position: absolute; left: 50%; top: 50%; width: 46%; height: 46%; margin: -23% 0 0 -23%; border-radius: 50%;
    background: radial-gradient(circle at 40% 35%, #3a3d45, #24262b 70%); border: 1.5px solid var(--edge);
    box-shadow: 0 4px 10px rgba(0,0,0,.5); }
  .stick.on .knob { box-shadow: 0 0 calc(4cqh) var(--glow); }
  .dpad { pointer-events: none; }
  .dpad::before, .dpad::after { content: ""; position: absolute; background: var(--key); border: 1.5px solid var(--edge);
    border-radius: calc(2.5cqh); }
  .dpad::before { left: 33%; top: 0; width: 34%; height: 100%; }
  .dpad::after { left: 0; top: 33%; width: 100%; height: 34%; }
  .arrow { background: transparent; border: 0; box-shadow: none; border-radius: calc(2cqh); font-size: calc(4.5cqh); color: var(--dim); }
  .arrow.on { background: rgba(120,160,255,.25); box-shadow: none; }
  #turn { display: none; position: absolute; inset: 0; align-items: center; justify-content: center; text-align: center;
    color: var(--dim); padding: 24px; }
  @media (orientation: portrait) { #deck { display: none; } #turn { display: flex; } }
  #surface, #trackpad { position: absolute; inset: 4px 10px 10px; border-radius: 16px; background: var(--panel); border: 1.5px solid var(--edge);
    display: flex; align-items: center; justify-content: center; color: var(--dim); }
  #trackpad { flex-direction: column; gap: 10px; }
  #macnote { display: none; max-width: 80%; text-align: center; color: #ffd23f; }
  #macnote.on { display: block; }
  #gone { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.85); align-items: center; justify-content: center;
    text-align: center; padding: 24px; z-index: 9; }
  #gone.on { display: flex; }
  #gone button { margin-top: 14px; border: 0; border-radius: 10px; padding: 9px 18px; font: inherit; background: var(--key); color: var(--text); }
</style>
</head>
<body>
<header>
  <span id="dot"></span><span id="title">Connecting…</span>
  <button id="assistant">✨ Gemini</button>
  <nav><button data-tab="pad" class="on">Controller</button><button data-tab="touch">Touchpad</button><button data-tab="mac">Mac</button></nav>
</header>
<main>
  <section id="pad" class="on">
    <div id="turn">Turn your phone sideways to use it as a controller.</div>
    <div id="deck">
      <!-- Laid out as an Xbox pad: left stick high, d-pad and right stick low and inward, the
           face buttons high on the right, View and Menu between; the triggers and bumpers as
           thin keys along the top. -->
      <div class="at key bumper" data-b="lt" style="--x:12;--y:7;--w:12;--h:9">LT</div>
      <div class="at key bumper" data-b="lb" style="--x:26;--y:7;--w:12;--h:9">LB</div>
      <div class="at key bumper" data-b="rb" style="--x:74;--y:7;--w:12;--h:9">RB</div>
      <div class="at key bumper" data-b="rt" style="--x:88;--y:7;--w:12;--h:9">RT</div>

      <div class="at stick" data-s="l" style="--x:25;--y:42;--d:42"><div class="knob"></div></div>

      <div class="at dpad" style="--x:37;--y:74;--d:32"></div>
      <div class="at key arrow" data-b="up" style="--x:37;--y:63;--d:10.5">▲</div>
      <div class="at key arrow" data-b="down" style="--x:37;--y:85;--d:10.5">▼</div>
      <div class="at key arrow" data-b="left" style="--x:37;--dx:-11;--y:74;--d:10.5">◀</div>
      <div class="at key arrow" data-b="right" style="--x:37;--dx:11;--y:74;--d:10.5">▶</div>

      <div class="at key small" data-b="back" style="--x:43;--y:42;--d:11">⧉</div>
      <div class="at key small" data-b="start" style="--x:57;--y:42;--d:11">≡</div>

      <div class="at key face" data-b="y" style="--x:75;--y:26;--d:15">Y</div>
      <div class="at key face" data-b="x" style="--x:75;--dx:-16;--y:42;--d:15">X</div>
      <div class="at key face" data-b="b" style="--x:75;--dx:16;--y:42;--d:15">B</div>
      <div class="at key face" data-b="a" style="--x:75;--y:58;--d:15">A</div>

      <div class="at stick" data-s="r" style="--x:63;--y:74;--d:34"><div class="knob"></div></div>
    </div>
  </section>
  <section id="touch"><div id="surface">Touch here as on the app's screen</div></section>
  <section id="mac"><div id="trackpad"><div>Your Mac's trackpad</div>
    <div id="macnote">On your Mac, allow Inquiline in System Settings › Privacy &amp; Security › Accessibility.</div></div></section>
</main>
<div id="gone"><div><div id="goneText">Not connected to your Mac.</div><button onclick="location.reload()">Try Again</button></div></div>
<script>
(() => {
  const token = "{{TOKEN}}", macName = "{{NAME}}";
  const dot = document.getElementById("dot"), gone = document.getElementById("gone"), title = document.getElementById("title");
  // Inquiline says which windows there are and which is in front; the page works that one,
  // over the window's own socket, and follows when another comes to the front.
  let control, app = null, appPid = 0, ready = false, tab = "pad", lastState = null, rtcHandler = null;
  function connect() {
    control = new WebSocket("ws://" + location.hostname + ":{{PORT}}/");
    control.onopen = () => control.send(JSON.stringify({ t: "hello", token }));
    control.onmessage = e => follow(JSON.parse(e.data));
    control.onclose = () => { closeApp(); gone.classList.add("on"); };
  }
  // The Mac tab works the Mac itself, which Inquiline lists too; the others, the app in front.
  function follow(s) {
    lastState = s;
    const list = s.windows || [];
    const w = tab === "mac" ? list.find(w => w.mac) : list.find(w => w.pid === s.active && !w.mac);
    if (!w) { title.textContent = tab === "mac" ? "Mac" : "Open an app on your Mac"; closeApp(); return; }
    title.textContent = w.mac ? "Mac" : w.title;
    if (w.pid !== appPid) openApp(w);
  }
  function closeApp() {
    if (app) { app.onclose = null; app.close(); }
    if (peer) { peer.close(); peer = null; }
    channel = null; rtcHandler = null;
    app = null; appPid = 0; ready = false; dot.classList.remove("on");
  }

  // A WebRTC data channel to the window, over UDP, unordered and never resent: a finger's moves
  // and the controller's state go there, so one lost on Wi-Fi doesn't hold back the next. The
  // WebSocket carries the offer and answer, and whatever must arrive: landing, lifting, letting
  // go. Without WebRTC everything goes over the WebSocket.
  let peer = null, channel = null;
  function startRtc(socket) {
    if (!window.RTCPeerConnection) return;
    try {
      const pc = new RTCPeerConnection({ iceServers: [] });
      peer = pc;
      const ch = pc.createDataChannel("input", { ordered: false, maxRetransmits: 0 });
      ch.onopen = () => { if (peer === pc) channel = ch; };
      ch.onclose = () => { if (channel === ch) channel = null; };
      pc.onicecandidate = e => {
        if (e.candidate && socket.readyState === 1)
          socket.send(JSON.stringify({ t: "rtc-candidate", cand: e.candidate.candidate, mid: e.candidate.sdpMid }));
      };
      rtcHandler = m => {
        if (m.t === "rtc-answer") pc.setRemoteDescription({ type: "answer", sdp: m.sdp }).catch(() => {});
        else if (m.t === "rtc-candidate") pc.addIceCandidate({ candidate: m.cand, sdpMid: m.mid }).catch(() => {});
      };
      pc.createOffer().then(o => pc.setLocalDescription(o))
        .then(() => socket.send(JSON.stringify({ t: "rtc-offer", sdp: pc.localDescription.sdp }))).catch(() => {});
    } catch (e) { peer = null; }
  }
  function openApp(w) {
    closeApp();
    appPid = w.pid;
    const socket = new WebSocket("ws://" + location.hostname + ":" + w.port + "/");
    app = socket;
    macSeq = 0; mx = 0; my = 0; sx = 0; sy = 0;
    socket.onopen = () => {
      socket.send(JSON.stringify({ t: "hello", token: w.token })); ready = true; dot.classList.add("on");
      if (!w.mac) send(true);
      startRtc(socket);
    };
    socket.onmessage = e => {
      const m = JSON.parse(e.data);
      if (m.t === "access") document.getElementById("macnote").classList.toggle("on", !m.ok);
      else if (rtcHandler) rtcHandler(m);
    };
    socket.onclose = () => { if (app === socket) { app = null; appPid = 0; ready = false; dot.classList.remove("on"); } };
  }
  function message(m, fast) {
    const text = JSON.stringify(m);
    if (fast && channel && channel.readyState === "open") { channel.send(text); return; }
    if (ready && app && app.readyState === 1) app.send(text);
  }
  function buzz() { if (navigator.vibrate) navigator.vibrate(8); }

  // Tabs
  document.querySelectorAll("nav button").forEach(b => b.onclick = () => {
    document.querySelectorAll("nav button").forEach(x => x.classList.toggle("on", x === b));
    document.querySelectorAll("section").forEach(s => s.classList.toggle("on", s.id === b.dataset.tab));
    tab = b.dataset.tab;
    document.getElementById("assistant").style.visibility = tab === "mac" ? "hidden" : "";
    if (lastState) follow(lastState);
  });
  document.getElementById("assistant").onclick = () => { buzz(); message({ t: "assistant" }); };

  // Controller: GamepadBridge's report bits and hat.
  const bits = { a: 0x0001, b: 0x0002, x: 0x0008, y: 0x0010, lb: 0x0040, rb: 0x0080, back: 0x0400, start: 0x0800 };
  const state = { lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0 };
  const held = new Set();
  let padSequence = 0;
  let pending = false, last = "";
  function hat() {
    const u = held.has("up"), d = held.has("down"), l = held.has("left"), r = held.has("right");
    return u ? (r ? 2 : l ? 8 : 1) : d ? (r ? 4 : l ? 6 : 5) : r ? 3 : l ? 7 : 0;
  }
  function send(force) {
    if (pending && !force) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      let b = 0;
      held.forEach(k => { if (bits[k]) b |= bits[k]; });
      const m = { t: "pad", lx: state.lx, ly: state.ly, rx: state.rx, ry: state.ry,
                  lt: held.has("lt") ? 1 : 0, rt: held.has("rt") ? 1 : 0, b, hat: hat() };
      const text = JSON.stringify(m);
      if (text !== last || force) {
        last = text;
        m.s = ++padSequence;
        // Let go entirely, it must arrive: over the WebSocket.
        const resting = !b && !m.hat && !m.lt && !m.rt && !m.lx && !m.ly && !m.rx && !m.ry;
        message(m, !resting);
      }
    });
  }
  const fingers = new Map(); // pointerId -> {key} or {stick, el, cx, cy, r}
  const pad = document.getElementById("pad");
  pad.addEventListener("pointerdown", e => {
    const key = e.target.closest(".key"), stick = e.target.closest(".stick");
    if (key) {
      fingers.set(e.pointerId, { key: key.dataset.b, el: key });
      key.classList.add("on"); held.add(key.dataset.b); buzz(); send();
    } else if (stick) {
      const box = stick.getBoundingClientRect();
      fingers.set(e.pointerId, { stick: stick.dataset.s, el: stick, cx: box.left + box.width / 2,
                                 cy: box.top + box.height / 2, r: box.width / 2 });
      stick.classList.add("on"); move(e);
    } else return;
    pad.setPointerCapture(e.pointerId);
    e.preventDefault();
  });
  function move(e) {
    const f = fingers.get(e.pointerId);
    if (!f || !f.stick) return;
    let x = (e.clientX - f.cx) / f.r, y = (e.clientY - f.cy) / f.r;
    const length = Math.hypot(x, y);
    if (length > 1) { x /= length; y /= length; }
    f.el.querySelector(".knob").style.transform = "translate(" + (x * f.r * 0.6) + "px," + (y * f.r * 0.6) + "px)";
    state[f.stick + "x"] = Math.round(x * 1000) / 1000;
    state[f.stick + "y"] = Math.round(y * 1000) / 1000;
    send();
  }
  pad.addEventListener("pointermove", move);
  function lift(e) {
    const f = fingers.get(e.pointerId);
    if (!f) return;
    fingers.delete(e.pointerId);
    f.el.classList.remove("on");
    if (f.key) held.delete(f.key);
    if (f.stick) { state[f.stick + "x"] = 0; state[f.stick + "y"] = 0; f.el.querySelector(".knob").style.transform = ""; }
    send();
  }
  pad.addEventListener("pointerup", lift);
  pad.addEventListener("pointercancel", lift);

  // Touchpad: each finger lands where it is on the app's screen. While down, every finger's
  // place goes once a frame, in step with the screen, whether it moved or not: the phone only
  // reports a finger that moves, and the Mac must tell a finger held still from a gap in the
  // Wi-Fi, which it bridges. A finger landing or lifting goes at once.
  const surface = document.getElementById("surface");
  const touches = new Map(), places = new Map();
  let ticking = false;
  function where(e) {
    const box = surface.getBoundingClientRect();
    return { x: (e.clientX - box.left) / box.width, y: (e.clientY - box.top) / box.height };
  }
  function tick() {
    if (places.size === 0) { ticking = false; return; }
    places.forEach((p, id) => message({ t: "touch", a: "move", id, x: p.x, y: p.y }, true));
    requestAnimationFrame(tick);
  }
  surface.addEventListener("pointerdown", e => {
    let id = 0; while ([...touches.values()].includes(id)) id++;
    touches.set(e.pointerId, id); surface.setPointerCapture(e.pointerId);
    const p = where(e);
    places.set(id, p);
    message({ t: "touch", a: "down", id, x: p.x, y: p.y });
    if (!ticking) { ticking = true; requestAnimationFrame(tick); }
    e.preventDefault();
  });
  surface.addEventListener("pointermove", e => {
    if (!touches.has(e.pointerId)) return;
    places.set(touches.get(e.pointerId), where(e));
  });
  function release(e) {
    if (!touches.has(e.pointerId)) return;
    const id = touches.get(e.pointerId);
    places.delete(id);
    const p = where(e);
    message({ t: "touch", a: "up", id, x: p.x, y: p.y });
    touches.delete(e.pointerId);
  }
  surface.addEventListener("pointerup", release);
  surface.addEventListener("pointercancel", release);

  // Mac: the phone as the Mac's trackpad. One finger moves the pointer and taps to click, and a
  // touch right after a tap drags; two fingers scroll, tap for a right click, or pinch to zoom;
  // three swipe between desktops, up to Mission Control, down to the app's windows; one held
  // still is a force click, Look Up. Moves and scrolls go as running totals, so the Mac misses
  // none when one is lost.
  const trackpad = document.getElementById("trackpad");
  const points = new Map();
  let g = null, macSeq = 0, mx = 0, my = 0, sx = 0, sy = 0, lastTap = 0, macTicking = false;
  function mac(m, fast) { m.t = "mac"; message(m, fast); }
  // While the Mac tab is open, a few bytes go every 40 ms, so the phone's Wi-Fi doesn't doze
  // between strokes, and a finger set down again moves the pointer at once rather than after
  // the radio wakes.
  setInterval(() => { if (tab === "mac" && !points.size && channel && channel.readyState === "open") channel.send('{"t":"mac","k":"awake"}'); }, 40);
  function middle() {
    let x = 0, y = 0;
    points.forEach(p => { x += p.x; y += p.y; });
    return { x: x / points.size, y: y / points.size };
  }
  function spread() {
    const a = [...points.values()];
    return a.length < 2 ? 0 : Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y);
  }
  function macFrame() {
    if (!points.size) { macTicking = false; return; }
    const c = middle(), n = points.size, key = [...points.keys()].join(","), d = spread();
    // Only while the same fingers are down, so a finger landing or lifting doesn't jump.
    if (g.prev && g.prev.key === key) {
      const dx = c.x - g.prev.x, dy = c.y - g.prev.y;
      if (n === 1 && g.most === 1) {
        // The finger's moves go as they come (below); a finger held still is told once a frame
        // too, as the Mac must tell it from a gap in the Wi-Fi, which it bridges.
        if (!g.sent) mac({ k: "move", s: ++macSeq, x: mx, y: my, ts: performance.now() }, true);
        g.sent = false;
      } else if (n === 2) {
        if (!g.mode) {
          g.slide += Math.abs(dx) + Math.abs(dy); g.pinch += Math.abs(d - g.prev.d);
          if (g.slide + g.pinch > 8) { g.mode = g.pinch > g.slide * 1.5 ? "pinch" : "scroll"; g.d0 = d; }
        }
        if (g.mode === "scroll" && (dx || dy)) {
          sx += dx * 1.5; sy += dy * 1.5;
          mac({ k: "scroll", s: ++macSeq, x: sx, y: sy }, true);
        } else if (g.mode === "pinch" && g.d0 > 0) {
          if (d / g.d0 > 1.3) { mac({ k: "zoom", d: "in" }); g.d0 = d; }
          else if (d / g.d0 < 0.77) { mac({ k: "zoom", d: "out" }); g.d0 = d; }
        }
      } else if (n >= 3 && !g.swiped) {
        g.ax += dx; g.ay += dy;
        if (Math.max(Math.abs(g.ax), Math.abs(g.ay)) > 50) {
          g.swiped = true;
          mac({ k: "swipe", d: Math.abs(g.ax) > Math.abs(g.ay) ? (g.ax > 0 ? "right" : "left") : (g.ay > 0 ? "down" : "up") });
        }
      }
    }
    g.prev = { x: c.x, y: c.y, key, d };
    requestAnimationFrame(macFrame);
  }
  trackpad.addEventListener("pointerdown", e => {
    trackpad.setPointerCapture(e.pointerId);
    e.preventDefault();
    if (!points.size) {
      g = { start: Date.now(), most: 0, far: 0, slide: 0, pinch: 0, ax: 0, ay: 0 };
      mac({ k: "hold" });
      if (Date.now() - lastTap < 300) { g.drag = true; lastTap = 0; mac({ k: "down" }); }
      g.timer = setTimeout(() => {
        if (points.size === 1 && g.most === 1 && g.far < 8 && !g.drag) { g.used = true; mac({ k: "lookup" }); buzz(); }
      }, 600);
    }
    points.set(e.pointerId, { x: e.clientX, y: e.clientY, x0: e.clientX, y0: e.clientY });
    g.most = Math.max(g.most, points.size);
    if (!macTicking) { macTicking = true; requestAnimationFrame(macFrame); }
  });
  trackpad.addEventListener("pointermove", e => {
    const p = points.get(e.pointerId);
    if (!p) return;
    // One finger moves the pointer as soon as it moves, not at the next frame.
    // Not until it has gone 4 pixels, as the Mac's trackpad: a finger landing rolls a little,
    // which would move the pointer off what it taps.
    const far = Math.hypot(e.clientX - p.x0, e.clientY - p.y0);
    if (points.size === 1 && g.most === 1 && (g.moving || far >= 4)) {
      const dx = g.moving ? e.clientX - p.x : (e.clientX - p.x0) * (1 - 4 / far);
      const dy = g.moving ? e.clientY - p.y : (e.clientY - p.y0) * (1 - 4 / far);
      g.moving = true;
      mx += dx; my += dy;
      const ts = e.timeStamp || performance.now();
      g.recent = (g.recent || []).filter(r => ts - r.ts < 50).concat([{ ts, dx, dy }]);
      mac({ k: "move", s: ++macSeq, x: mx, y: my, ts }, true);
      g.sent = true;
    }
    p.x = e.clientX; p.y = e.clientY;
    g.far = Math.max(g.far, Math.hypot(p.x - p.x0, p.y - p.y0));
  });
  function macLift(e) {
    if (!points.delete(e.pointerId) || points.size) return;
    clearTimeout(g.timer);
    const tap = Date.now() - g.start < 250 && g.far < 10 && !g.used;
    // Where the finger stopped, which must arrive, and the pointer stops there: without its
    // last 30 ms, as a finger lifting slides a little, which would fling the pointer.
    if (g.most === 1) {
      const end = e.timeStamp || performance.now();
      (g.recent || []).forEach(r => { if (end - r.ts < 30) { mx -= r.dx; my -= r.dy; } });
      mac({ k: "move", s: ++macSeq, x: mx, y: my, ts: end, rest: 1 });
    }
    if (g.drag) mac({ k: "up" });
    else if (tap && g.most === 1) { mac({ k: "click" }); lastTap = Date.now(); buzz(); }
    else if (tap && g.most === 2) { mac({ k: "click", b: "right" }); buzz(); }
    if (g.mode === "scroll") mac({ k: "scrollEnd" });
  }
  trackpad.addEventListener("pointerup", macLift);
  trackpad.addEventListener("pointercancel", macLift);
  // Never zoom: a double tap or a pinch is input for the app, not for the page.
  ["gesturestart", "gesturechange", "gestureend", "dblclick"].forEach(type =>
    document.addEventListener(type, e => e.preventDefault(), { passive: false }));
  let lastEnd = 0;
  document.addEventListener("touchend", e => {
    const now = Date.now();
    if (now - lastEnd < 400) e.preventDefault();
    lastEnd = now;
  }, { passive: false });
  document.addEventListener("touchmove", e => { if (e.touches.length > 1 || e.scale !== 1) e.preventDefault(); }, { passive: false });

  // Full screen with the first touch, where the browser allows it, as an app; a controller
  // also stays sideways.
  document.addEventListener("pointerdown", () => {
    const root = document.documentElement;
    const request = root.requestFullscreen || root.webkitRequestFullscreen;
    if (request && !(document.fullscreenElement || document.webkitFullscreenElement)) {
      Promise.resolve(request.call(root, { navigationUI: "hide" })).then(() => {
        if (screen.orientation && screen.orientation.lock) screen.orientation.lock("landscape").catch(() => {});
      }).catch(() => {});
    }
  }, { capture: true });

  // Opened at the Mac's numeric address, which the router may change, the page moves to the
  // Mac's name when the phone finds it, so a home screen link keeps working.
  if (macName && /^\d+\.\d+\.\d+\.\d+$/.test(location.hostname)) {
    const abort = new AbortController();
    setTimeout(() => abort.abort(), 1500);
    fetch("http://" + macName + ":" + location.port + "/" + token + "/ping", { signal: abort.signal })
      .then(r => { if (r.ok) location.replace("http://" + macName + ":" + location.port + location.pathname); else connect(); })
      .catch(() => connect());
  } else {
    connect();
  }
})();
</script>
</body>
</html>
"""#
}
