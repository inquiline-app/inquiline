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
         "display": "fullscreen", "orientation": "any", "background_color": "#000000", "theme_color": "#000000",
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
<meta name="theme-color" content="#000000">
<title>Inquiline</title>
<style>
  /* After Apple's TV Remote: black, soft grey rounds with thin icons, one large touch surface. */
  :root { --bg: #000; --key: #1c1c1e; --press: #3a3a3c; --edge: rgba(255,255,255,.07); --text: #f5f5f7; --dim: #8e8e93;
    --glow: rgba(10,132,255,.5); }
  * { box-sizing: border-box; -webkit-user-select: none; user-select: none; -webkit-tap-highlight-color: transparent;
      touch-action: none; -webkit-touch-callout: none; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
    font: 15px -apple-system, system-ui, sans-serif; overflow: hidden; touch-action: none; }
  body { display: flex; flex-direction: column; padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  svg { width: 46%; height: 46%; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
  .round { flex: none; width: 52px; height: 52px; border-radius: 50%; border: 1px solid var(--edge); background: var(--key);
    color: var(--text); display: flex; align-items: center; justify-content: center; padding: 0;
    transition: background .12s, transform .08s; }
  .round:active { background: var(--press); transform: scale(.95); }
  /* On, as iOS shows a switched control: white with a dark icon. */
  .round.on { background: var(--text); color: #000; }
  header { display: flex; align-items: center; gap: 12px; padding: 10px 16px; }
  #pill { flex: 1; min-width: 0; height: 40px; margin: 0 auto; max-width: 60%; display: flex; align-items: center; justify-content: center;
    gap: 8px; padding: 0 16px; border-radius: 20px; background: var(--key); border: 1px solid var(--edge); }
  #dot { width: 8px; height: 8px; border-radius: 50%; background: #ff453a; flex: none; }
  #dot.on { background: #30d158; }
  #pill:active { background: var(--press); }
  #pill svg { width: 14px; height: 14px; flex: none; color: var(--dim); stroke-width: 2.4; }
  #title { font-weight: 600; font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  #assistant { color: #bf9dff; }
  main { flex: 1; position: relative; }
  section { position: absolute; inset: 0; display: none; }
  section.on { display: block; }
  footer { display: flex; align-items: center; justify-content: center; gap: 28px; padding: 14px 16px 18px; }
  footer .round { width: 64px; height: 64px; }
  footer #back { width: 84px; height: 84px; }
  body.pad footer { display: none; }

  /* The controller, laid out as an Xbox pad on a body of one shape, 2.1 wide for 1 high, as
     large as fits and centered, so it looks the same on any phone and nothing stretches:
     positions in percent of the body's width and height, sizes in its height. */
  #deck { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%);
    width: min(100%, calc((100vh - 72px) * 2.1)); aspect-ratio: 2.1 / 1; max-height: 100%; container-type: size; }
  .at { position: absolute; left: calc(var(--x) * 1cqw + var(--dx, 0) * 1cqh); top: calc(var(--y) * 1cqh);
    width: calc(var(--d) * 1cqh); height: calc(var(--d) * 1cqh); transform: translate(-50%, -50%); }
  .key { display: flex; align-items: center; justify-content: center; background: var(--key);
    border: 1px solid var(--edge); color: var(--text); font-weight: 600; border-radius: 50%;
    transition: transform .06s, background .06s, box-shadow .06s; }
  .key.on { transform: translate(-50%, -50%) scale(.93); background: var(--press); box-shadow: 0 0 calc(4cqh) var(--glow); }
  .face { font-size: calc(7cqh); }
  .face[data-b="a"] { color: #30d158; } .face[data-b="b"] { color: #ff453a; }
  .face[data-b="x"] { color: #0a84ff; } .face[data-b="y"] { color: #ffd60a; }
  .bumper { width: calc(var(--w) * 1cqw); height: calc(var(--h) * 1cqh); border-radius: calc(4.5cqh); font-size: calc(4.5cqh); color: var(--dim); }
  .small { font-size: calc(4.5cqh); color: var(--dim); }
  .stick { border-radius: 50%; background: #0d0d0e; border: 1px solid var(--edge); }
  .knob { position: absolute; left: 50%; top: 50%; width: 46%; height: 46%; margin: -23% 0 0 -23%; border-radius: 50%;
    background: var(--key); border: 1px solid rgba(255,255,255,.12); box-shadow: 0 4px 14px rgba(0,0,0,.6); }
  .stick.on .knob { background: var(--press); box-shadow: 0 0 calc(4cqh) var(--glow); }
  .dpad { pointer-events: none; }
  .dpad::before, .dpad::after { content: ""; position: absolute; background: var(--key); border: 1px solid var(--edge);
    border-radius: calc(3cqh); }
  .dpad::before { left: 33%; top: 0; width: 34%; height: 100%; }
  .dpad::after { left: 0; top: 33%; width: 100%; height: 34%; }
  .arrow { background: transparent; border: 0; border-radius: calc(2cqh); font-size: calc(4cqh); color: var(--dim); }
  .arrow.on { background: rgba(10,132,255,.25); box-shadow: none; }
  #turn { display: none; position: absolute; inset: 0; align-items: center; justify-content: center; text-align: center;
    color: var(--dim); padding: 24px; }
  @media (orientation: portrait) { #deck { display: none; } #turn { display: flex; } }
  #surface { position: absolute; inset: 0 16px; border-radius: 28px; background: var(--key); border: 1px solid var(--edge);
    display: flex; align-items: center; justify-content: center; color: #48484a; font-size: 14px; overflow: hidden; }
  #surface .spot { position: absolute; width: 64px; height: 64px; margin: -32px 0 0 -32px; border-radius: 50%;
    background: radial-gradient(circle, rgba(255,255,255,.16), rgba(255,255,255,0) 70%); pointer-events: none; }
  /* Inquiline's apps, as the Dock shows them, in a sheet from the bottom as iOS's. */
  #apps { position: fixed; inset: 0; z-index: 8; background: rgba(0,0,0,0); display: flex; align-items: flex-end;
    pointer-events: none; transition: background .25s; }
  #apps.on { background: rgba(0,0,0,.55); pointer-events: auto; }
  #sheet { width: 100%; max-height: 78%; overflow-y: auto; background: rgba(28,28,30,.96); border-radius: 28px 28px 0 0;
    border-top: 1px solid var(--edge); padding: 8px 16px calc(20px + env(safe-area-inset-bottom));
    transform: translateY(100%); transition: transform .3s cubic-bezier(.2,.9,.3,1); -webkit-backdrop-filter: blur(30px); backdrop-filter: blur(30px); }
  #apps.on #sheet { transform: none; }
  #sheet, #sheet * { touch-action: pan-y; }
  #grab { width: 38px; height: 5px; border-radius: 3px; background: #48484a; margin: 4px auto 14px; }
  #grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(78px, 1fr)); gap: 18px 8px; }
  .app { display: flex; flex-direction: column; align-items: center; gap: 7px; min-width: 0; }
  .app img { width: 62px; height: 62px; border-radius: 22%; background: var(--key); transition: transform .1s; }
  .app:active img { transform: scale(.9); }
  .app span { font-size: 12px; color: var(--text); max-width: 100%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  /* The window itself, full screen: touched as the app's screen. */
  #screen { position: fixed; inset: 0; z-index: 7; background: #000; display: none; }
  #screen.on { display: block; }
  /* Below the notch, and beside it when turned, as iOS lays apps out (its safe area); the home
     bar's strip at the bottom stays the picture's, as games draw under it. */
  #screen video { position: absolute; top: env(safe-area-inset-top); left: env(safe-area-inset-left);
    right: env(safe-area-inset-right); bottom: 0; width: calc(100% - env(safe-area-inset-left) - env(safe-area-inset-right));
    height: calc(100% - env(safe-area-inset-top)); object-fit: contain; }
  #hint { position: absolute; left: 50%; bottom: calc(24px + env(safe-area-inset-bottom)); transform: translateX(-50%);
    padding: 8px 16px; border-radius: 18px; background: rgba(28,28,30,.85); color: var(--text); font-size: 14px;
    white-space: nowrap; pointer-events: none; opacity: 0; transition: opacity .4s; z-index: 1; }
  #hint.on { opacity: 1; }
  #screen #waiting { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; color: var(--dim); }
  #gone { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.88); align-items: center; justify-content: center;
    text-align: center; padding: 24px; z-index: 9; }
  #gone.on { display: flex; }
  #gone button { margin-top: 14px; border: 0; border-radius: 20px; padding: 10px 22px; font: inherit; font-weight: 600; background: var(--key); color: var(--text); }
</style>
</head>
<body>
<header>
  <button class="round" id="mode" aria-label="Controller"><svg viewBox="0 0 24 24"><path d="M7 8h10a4 4 0 0 1 4 4.5l-.6 3.6a2.3 2.3 0 0 1-4 1L14.6 15H9.4l-1.8 2.1a2.3 2.3 0 0 1-4-1L3 12.5A4 4 0 0 1 7 8z"/><path d="M7.5 10.5v3M6 12h3"/><circle cx="16" cy="11.2" r=".6"/><circle cx="17.6" cy="12.8" r=".6"/></svg></button>
  <div id="pill"><span id="dot"></span><span id="title">Connecting…</span><svg viewBox="0 0 24 24"><path d="M9 5l7 7-7 7"/></svg></div>
  <button class="round" id="show" aria-label="Show the window"><svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 20h8M12 17v3"/></svg></button>
  <button class="round" id="assistant" aria-label="Gemini"><svg viewBox="0 0 24 24"><path d="M12 3c.6 4.6 3.4 7.4 9 9-5.6 1.6-8.4 4.4-9 9-.6-4.6-3.4-7.4-9-9 5.6-1.6 8.4-4.4 9-9z"/></svg></button>
</header>
<main>
  <section id="pad">
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
  <section id="touch"><div id="surface">Touch as on the app's screen</div></section>
</main>
<footer>
  <button class="round" data-k="mute" aria-label="Sound"><svg viewBox="0 0 24 24"><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path class="waves" d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/><path class="cross" style="display:none" d="M16 9.5l5 5M21 9.5l-5 5"/></svg></button>
  <button class="round" id="back" data-k="back" aria-label="Back"><svg viewBox="0 0 24 24" style="width:36%;height:36%"><path d="M15 4.5L7.5 12l7.5 7.5"/></svg></button>
  <button class="round" data-k="playpause" aria-label="Play or Pause"><svg viewBox="0 0 24 24"><path d="M4.5 6v12l7-6z"/><path d="M15 6.5v11M19.5 6.5v11"/></svg></button>
</footer>
<div id="screen"><div id="waiting">Connecting to the window…</div><video id="video" autoplay playsinline muted></video>
  <div id="hint">Swipe up with three fingers to go back</div></div>
<div id="apps"><div id="sheet"><div id="grab"></div><div id="grid"></div></div></div>
<div id="gone"><div><div id="goneText">Not connected to your Mac.</div><button onclick="location.reload()">Try Again</button></div></div>
<script>
(() => {
  const token = "{{TOKEN}}", macName = "{{NAME}}";
  const dot = document.getElementById("dot"), gone = document.getElementById("gone"), title = document.getElementById("title");
  // Inquiline says which windows there are and which is in front; the page works that one,
  // over the window's own socket, and follows when another comes to the front.
  let control, app = null, appPid = 0, ready = false;
  function connect() {
    control = new WebSocket("ws://" + location.hostname + ":{{PORT}}/");
    control.onopen = () => control.send(JSON.stringify({ t: "hello", token }));
    control.onmessage = e => {
      const m = JSON.parse(e.data);
      if (m.t === "apps") listApps(m.apps); else follow(m);
    };
    control.onclose = () => { closeApp(); gone.classList.add("on"); };
  }
  function follow(s) {
    const w = (s.windows || []).find(w => w.pid === s.active);
    if (!w) { title.textContent = "Open an app on your Mac"; closeApp(); return; }
    title.textContent = w.title;
    if (w.pid !== appPid) openApp(w);
  }
  function closeApp() {
    if (app) { app.onclose = null; app.close(); }
    if (peer) { peer.close(); peer = null; }
    endScreen();
    signaled = null;
    channel = null;
    app = null; appPid = 0; ready = false; dot.classList.remove("on");
  }

  // A WebRTC data channel to the window, over UDP, unordered and never resent: a finger's moves
  // and the controller's state go there, so one lost on Wi-Fi doesn't hold back the next. The
  // WebSocket carries the offer and answer, and whatever must arrive: landing, lifting, letting
  // go. Without WebRTC everything goes over the WebSocket.
  let peer = null, channel = null, signaled = null;
  // The app's own mute, as the Mac has it: the key shows a crossed speaker when it's muted.
  function muted(on) {
    const key = document.querySelector('[data-k="mute"]');
    key.classList.toggle("on", !!on);
    key.querySelector(".waves").style.display = on ? "none" : "";
    key.querySelector(".cross").style.display = on ? "" : "none";
  }
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
      signaled = m => {
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
    socket.onopen = () => {
      socket.send(JSON.stringify({ t: "hello", token: w.token })); ready = true; dot.classList.add("on"); send(true); startRtc(socket);
      // Showing the window, the phone shows the one now in front.
      if (showing) askScreen();
    };
    socket.onmessage = e => {
      const m = JSON.parse(e.data);
      if (m.t === "state") muted(m.muted);
      else if (m.t.startsWith("screen-")) screenSignal(m, socket);
      else if (signaled) signaled(m);
    };
    socket.onclose = () => { if (app === socket) { app = null; appPid = 0; ready = false; dot.classList.remove("on"); } };
  }
  function message(m, fast) {
    const text = JSON.stringify(m);
    if (fast && channel && channel.readyState === "open") { channel.send(text); return; }
    if (ready && app && app.readyState === 1) app.send(text);
  }
  function buzz() { if (navigator.vibrate) navigator.vibrate(8); }

  // Touchpad first, as Apple's remote; the round key at the top left turns it into a
  // controller and back. The phone remembers which.
  const modeKey = document.getElementById("mode");
  let padMode = false;
  try { padMode = localStorage.getItem("mode") === "pad"; } catch (e) {}
  function show() {
    document.body.classList.toggle("pad", padMode);
    modeKey.classList.toggle("on", padMode);
    document.getElementById("pad").classList.toggle("on", padMode);
    document.getElementById("touch").classList.toggle("on", !padMode);
  }
  show();
  modeKey.onclick = () => {
    buzz(); padMode = !padMode; show();
    try { localStorage.setItem("mode", padMode ? "pad" : "touch"); } catch (e) {}
    if (screen.orientation && screen.orientation.lock && (document.fullscreenElement || document.webkitFullscreenElement)) {
      if (padMode) screen.orientation.lock("landscape").catch(() => {}); else if (screen.orientation.unlock) screen.orientation.unlock();
    }
  };
  document.getElementById("assistant").onclick = () => { buzz(); message({ t: "assistant" }); };
  document.querySelectorAll("footer [data-k]").forEach(b => b.onclick = () => { buzz(); message({ t: "key", k: b.dataset.k }); });

  // The title opens Inquiline's apps, as the Dock shows them; one tapped opens on the Mac, in
  // front, and the page follows it there.
  const appsSheet = document.getElementById("apps"), grid = document.getElementById("grid");
  document.getElementById("pill").onclick = () => {
    buzz();
    if (control && control.readyState === 1) control.send(JSON.stringify({ t: "apps" }));
    appsSheet.classList.add("on");
  };
  appsSheet.onclick = e => { if (e.target === appsSheet) appsSheet.classList.remove("on"); };
  function listApps(apps) {
    grid.textContent = "";
    apps.forEach(a => {
      const item = document.createElement("div");
      item.className = "app";
      const icon = document.createElement("img");
      icon.src = "/" + token + "/app-icon/" + encodeURIComponent(a.p);
      icon.alt = "";
      const name = document.createElement("span");
      name.textContent = a.n;
      item.append(icon, name);
      item.onclick = () => {
        buzz();
        control.send(JSON.stringify({ t: "launch", p: a.p }));
        appsSheet.classList.remove("on");
      };
      grid.appendChild(item);
    });
  }

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

  // The window on the phone: the Mac offers its picture as a video track on a connection of its
  // own (PhoneRemote's screen), which plays here; touches on it are the app's, where they land.
  const screenView = document.getElementById("screen"), video = document.getElementById("video");
  const waiting = document.getElementById("waiting");
  let showing = false, screenPc = null, windowFits = false;
  // A window that takes the phone's shape (a flexible app) is told it, upright or turned; one that
  // doesn't keeps the phone turned to the picture's shape, as a video does.
  function tellShape() {
    if (showing && windowFits && ready && app && app.readyState === 1)
      app.send(JSON.stringify({ t: "screen-fit", w: video.clientWidth, h: video.clientHeight }));
  }
  let shapeTimer = 0;
  window.addEventListener("resize", () => { clearTimeout(shapeTimer); shapeTimer = setTimeout(tellShape, 150); });
  function askScreen() {
    endScreen();
    waiting.style.display = "";
    if (ready && app && app.readyState === 1) app.send(JSON.stringify({ t: "screen-start" }));
  }
  function endScreen() {
    if (screenPc) { screenPc.close(); screenPc = null; }
    video.srcObject = null;
  }
  function screenSignal(m, socket) {
    if (m.t === "screen-offer") {
      endScreen();
      windowFits = !!m.fits;
      tellShape();
      const pc = new RTCPeerConnection({ iceServers: [] });
      screenPc = pc;
      pc.ontrack = e => {
        video.srcObject = e.streams[0] || new MediaStream([e.track]);
        video.play().catch(() => {});
      };
      pc.onicecandidate = e => {
        if (e.candidate && socket.readyState === 1)
          socket.send(JSON.stringify({ t: "screen-candidate", cand: e.candidate.candidate, mid: e.candidate.sdpMid }));
      };
      pc.setRemoteDescription({ type: "offer", sdp: m.sdp })
        .then(() => pc.createAnswer()).then(a => pc.setLocalDescription(a))
        .then(() => socket.send(JSON.stringify({ t: "screen-answer", sdp: pc.localDescription.sdp }))).catch(() => {});
    } else if (m.t === "screen-candidate" && screenPc) {
      screenPc.addIceCandidate({ candidate: m.cand, sdpMid: m.mid }).catch(() => {});
    }
  }
  video.addEventListener("playing", () => { waiting.style.display = "none"; });
  document.getElementById("show").onclick = () => {
    buzz();
    showing = true;
    screenView.classList.add("on");
    showHint();
    askScreen();
    // Sideways for a sideways app, as a phone turns for a video.
    const lock = () => {
      if (windowFits || !screen.orientation || !screen.orientation.lock || !video.videoWidth) return;
      screen.orientation.lock(video.videoWidth > video.videoHeight ? "landscape" : "portrait").catch(() => {});
    };
    video.onresize = lock;
  };
  // Back to the remote: three fingers swiped up, a gesture apps hardly use, as iPadOS and
  // Android take three fingers for the system's own.
  const hint = document.getElementById("hint");
  let hintTimer = 0;
  function showHint() {
    hint.classList.add("on");
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => hint.classList.remove("on"), 2500);
  }
  const swipe = new Map(); // pointerId -> {y, time}
  video.addEventListener("pointerdown", e => swipe.set(e.pointerId, { y: e.clientY, time: e.timeStamp }));
  video.addEventListener("pointermove", e => {
    if (swipe.size < 3 || !showing) return;
    const now = e.timeStamp;
    const all = [...swipe.entries()];
    const latest = all.every(([id, s]) => now - s.time < 800);
    const moved = all.map(([id, s]) => (lastY.get(id) ?? s.y) - s.y);
    lastY.set(e.pointerId, e.clientY);
    if (latest && moved.length >= 3 && moved.every(d => d < -60)) leaveScreen();
  });
  const lastY = new Map();
  for (const type of ["pointerup", "pointercancel"]) {
    video.addEventListener(type, e => { swipe.delete(e.pointerId); lastY.delete(e.pointerId); });
  }
  // The phone locked, or the page left: the window is the Mac's again, and the remote shows
  // when the page comes back.
  document.addEventListener("visibilitychange", () => { if (document.hidden && showing) leaveScreen(); });
  window.addEventListener("pagehide", () => { if (showing) leaveScreen(); });
  function leaveScreen() {
    // The fingers lift for the app too.
    touches.forEach((id, pointer) => {
      const p = places.get(id) || { x: 0, y: 0 };
      places.delete(id);
      message({ t: "touch", a: "up", id, x: p.x, y: p.y });
    });
    touches.clear();
    swipe.clear();
    lastY.clear();
    buzz();
    showing = false;
    screenView.classList.remove("on");
    if (ready && app && app.readyState === 1) app.send(JSON.stringify({ t: "screen-stop" }));
    endScreen();
    if (screen.orientation && screen.orientation.lock && !padMode && screen.orientation.unlock) screen.orientation.unlock();
  };
  /// Where the picture is within the video element, as it's fitted (object-fit: contain).
  function pictureBox() {
    const box = video.getBoundingClientRect();
    if (!video.videoWidth) return box;
    const scale = Math.min(box.width / video.videoWidth, box.height / video.videoHeight);
    const width = video.videoWidth * scale, height = video.videoHeight * scale;
    return { left: box.left + (box.width - width) / 2, top: box.top + (box.height - height) / 2, width, height };
  }

  // Touchpad: each finger lands where it is on the app's screen. While down, every finger's
  // place goes once a frame, in step with the screen, whether it moved or not: the phone only
  // reports a finger that moves, and the Mac must tell a finger held still from a gap in the
  // Wi-Fi, which it bridges. A finger landing or lifting goes at once.
  const surface = document.getElementById("surface");
  const touches = new Map(), places = new Map(), spots = new Map();
  function place(spot, p) { if (spot) { spot.style.left = (p.x * 100) + "%"; spot.style.top = (p.y * 100) + "%"; } }
  let ticking = false;
  function where(e) {
    const box = e.currentTarget === video ? pictureBox() : surface.getBoundingClientRect();
    return { x: Math.min(Math.max((e.clientX - box.left) / box.width, 0), 1),
             y: Math.min(Math.max((e.clientY - box.top) / box.height, 0), 1) };
  }
  function tick() {
    if (places.size === 0) { ticking = false; return; }
    places.forEach((p, id) => message({ t: "touch", a: "move", id, x: p.x, y: p.y }, true));
    requestAnimationFrame(tick);
  }
  function land(e) {
    let id = 0; while ([...touches.values()].includes(id)) id++;
    touches.set(e.pointerId, id); e.currentTarget.setPointerCapture(e.pointerId);
    const p = where(e);
    places.set(id, p);
    if (e.currentTarget === surface) {
      const spot = document.createElement("div");
      spot.className = "spot"; spots.set(id, spot); surface.appendChild(spot); place(spot, p);
    }
    message({ t: "touch", a: "down", id, x: p.x, y: p.y });
    if (!ticking) { ticking = true; requestAnimationFrame(tick); }
    e.preventDefault();
  }
  function slide(e) {
    if (!touches.has(e.pointerId)) return;
    const id = touches.get(e.pointerId), p = where(e);
    places.set(id, p); place(spots.get(id), p);
  }
  function release(e) {
    if (!touches.has(e.pointerId)) return;
    const id = touches.get(e.pointerId);
    places.delete(id);
    if (spots.has(id)) { spots.get(id).remove(); spots.delete(id); }
    const p = where(e);
    message({ t: "touch", a: "up", id, x: p.x, y: p.y });
    touches.delete(e.pointerId);
  }
  for (const target of [surface, video]) {
    target.addEventListener("pointerdown", land);
    target.addEventListener("pointermove", slide);
    target.addEventListener("pointerup", release);
    target.addEventListener("pointercancel", release);
  }

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

  // Full screen with the first touch, where the browser allows it, as an app; the controller
  // also stays sideways.
  document.addEventListener("pointerdown", () => {
    const root = document.documentElement;
    const request = root.requestFullscreen || root.webkitRequestFullscreen;
    if (request && !(document.fullscreenElement || document.webkitFullscreenElement)) {
      Promise.resolve(request.call(root, { navigationUI: "hide" })).then(() => {
        if (padMode && screen.orientation && screen.orientation.lock) screen.orientation.lock("landscape").catch(() => {});
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
