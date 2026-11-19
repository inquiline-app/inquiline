import Foundation

/// The page a phone opens from a window's QR code (PhoneRemote): a controller, a touchpad and
/// the assistant, for that window's app. One page, with no files around it, as the phone loads
/// it from the Mac alone.
enum PhoneRemotePage {
    static func html(title: String, port: Int, token: String) -> String {
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return template
            .replacingOccurrences(of: "{{TITLE}}", with: safeTitle)
            .replacingOccurrences(of: "{{PORT}}", with: String(port))
            .replacingOccurrences(of: "{{TOKEN}}", with: token)
    }

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#111214">
<title>{{TITLE}} · Inquiline</title>
<style>
  :root { --bg: #111214; --panel: #1c1d21; --key: #2a2c31; --key-on: #4b7bec; --text: #f2f2f4; --dim: #8b8d94; }
  * { box-sizing: border-box; -webkit-user-select: none; user-select: none; -webkit-tap-highlight-color: transparent;
      touch-action: none; -webkit-touch-callout: none; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
    font: 15px -apple-system, system-ui, sans-serif; overflow: hidden; touch-action: none; }
  body { display: flex; flex-direction: column; padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  header { display: flex; align-items: center; gap: 8px; padding: 8px 12px; }
  #dot { width: 9px; height: 9px; border-radius: 50%; background: #e5534b; flex: none; }
  #dot.on { background: #3fb950; }
  #title { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 1; }
  nav { display: flex; gap: 4px; background: var(--panel); border-radius: 9px; padding: 3px; }
  nav button { border: 0; background: none; color: var(--dim); font: inherit; padding: 5px 12px; border-radius: 7px; }
  nav button.on { background: var(--key); color: var(--text); }
  main { flex: 1; position: relative; }
  section { position: absolute; inset: 0; display: none; }
  section.on { display: block; }
  footer { display: flex; justify-content: center; padding: 8px; }
  #assistant { border: 0; border-radius: 22px; padding: 10px 22px; font: inherit; font-weight: 600; color: var(--text);
    background: linear-gradient(135deg, #4b7bec, #a55eea); }
  .key { position: absolute; display: flex; align-items: center; justify-content: center; background: var(--key);
    color: var(--text); font-weight: 600; border-radius: 50%; }
  .key.on { background: var(--key-on); }
  .pill { border-radius: 12px; }
  .stick { position: absolute; border-radius: 50%; background: var(--panel); border: 2px solid var(--key); }
  .knob { position: absolute; left: 50%; top: 50%; width: 44%; height: 44%; margin: -22% 0 0 -22%; border-radius: 50%;
    background: var(--key); }
  .stick.on .knob { background: var(--key-on); }
  #turn { display: none; position: absolute; inset: 0; align-items: center; justify-content: center; text-align: center;
    color: var(--dim); padding: 24px; }
  @media (orientation: portrait) { #pad .key, #pad .stick { display: none; } #turn { display: flex; } }
  #surface { position: absolute; inset: 8px; border-radius: 14px; background: var(--panel); display: flex;
    align-items: center; justify-content: center; color: var(--dim); }
  #gone { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.85); align-items: center; justify-content: center;
    text-align: center; padding: 24px; z-index: 9; }
  #gone.on { display: flex; }
  #gone button { margin-top: 14px; border: 0; border-radius: 10px; padding: 9px 18px; font: inherit; background: var(--key); color: var(--text); }
</style>
</head>
<body>
<header>
  <span id="dot"></span><span id="title">{{TITLE}}</span>
  <nav><button data-tab="pad" class="on">Controller</button><button data-tab="touch">Touchpad</button></nav>
</header>
<main>
  <section id="pad" class="on">
    <div id="turn">Turn your phone sideways to use it as a controller.</div>
    <div class="key pill" data-b="lt" style="left:3%;top:2%;width:16%;height:13%">LT</div>
    <div class="key pill" data-b="lb" style="left:21%;top:2%;width:16%;height:13%">LB</div>
    <div class="key pill" data-b="rb" style="right:21%;top:2%;width:16%;height:13%">RB</div>
    <div class="key pill" data-b="rt" style="right:3%;top:2%;width:16%;height:13%">RT</div>
    <div class="stick" data-s="l" style="left:5%;top:24%;width:34vh;height:34vh"><div class="knob"></div></div>
    <div class="key" data-b="up" style="left:25%;top:62%;width:9vh;height:9vh">▲</div>
    <div class="key" data-b="left" style="left:19%;top:75%;width:9vh;height:9vh">◀</div>
    <div class="key" data-b="right" style="left:31%;top:75%;width:9vh;height:9vh">▶</div>
    <div class="key" data-b="down" style="left:25%;top:88%;width:9vh;height:9vh">▼</div>
    <div class="key pill" data-b="back" style="left:43%;top:24%;width:7%;height:11%">⧉</div>
    <div class="key pill" data-b="start" style="right:43%;top:24%;width:7%;height:11%">≡</div>
    <div class="key" data-b="y" style="right:14%;top:22%;width:15vh;height:15vh">Y</div>
    <div class="key" data-b="x" style="right:24%;top:40%;width:15vh;height:15vh">X</div>
    <div class="key" data-b="b" style="right:4%;top:40%;width:15vh;height:15vh">B</div>
    <div class="key" data-b="a" style="right:14%;top:58%;width:15vh;height:15vh">A</div>
    <div class="stick" data-s="r" style="right:42%;top:55%;width:28vh;height:28vh"><div class="knob"></div></div>
  </section>
  <section id="touch"><div id="surface">Touch here as on the app's screen</div></section>
</main>
<footer><button id="assistant">✨ Ask Gemini</button></footer>
<div id="gone"><div><div id="goneText">Not connected to your Mac.</div><button onclick="location.reload()">Try Again</button></div></div>
<script>
(() => {
  const token = "{{TOKEN}}";
  let socket, ready = false;
  const dot = document.getElementById("dot"), gone = document.getElementById("gone");
  function connect() {
    socket = new WebSocket("ws://" + location.hostname + ":{{PORT}}/");
    socket.onopen = () => { socket.send(JSON.stringify({ t: "hello", token })); ready = true; dot.classList.add("on"); send(true); };
    socket.onclose = () => { ready = false; dot.classList.remove("on"); gone.classList.add("on"); };
  }
  function message(m) { if (ready && socket.readyState === 1) socket.send(JSON.stringify(m)); }
  function buzz() { if (navigator.vibrate) navigator.vibrate(8); }

  // Tabs
  document.querySelectorAll("nav button").forEach(b => b.onclick = () => {
    document.querySelectorAll("nav button").forEach(x => x.classList.toggle("on", x === b));
    document.querySelectorAll("section").forEach(s => s.classList.toggle("on", s.id === b.dataset.tab));
  });
  document.getElementById("assistant").onclick = () => { buzz(); message({ t: "assistant" }); };

  // Controller: GamepadBridge's report bits and hat.
  const bits = { a: 0x0001, b: 0x0002, x: 0x0008, y: 0x0010, lb: 0x0040, rb: 0x0080, back: 0x0400, start: 0x0800 };
  const state = { lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0 };
  const held = new Set();
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
      if (text !== last || force) { last = text; message(m); }
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

  // Touchpad: each finger lands where it is on the app's screen.
  const surface = document.getElementById("surface");
  const touches = new Map();
  function point(e, a) {
    const box = surface.getBoundingClientRect();
    message({ t: "touch", a, id: touches.get(e.pointerId),
              x: (e.clientX - box.left) / box.width, y: (e.clientY - box.top) / box.height });
  }
  surface.addEventListener("pointerdown", e => {
    let id = 0; while ([...touches.values()].includes(id)) id++;
    touches.set(e.pointerId, id); surface.setPointerCapture(e.pointerId); point(e, "down"); e.preventDefault();
  });
  surface.addEventListener("pointermove", e => { if (touches.has(e.pointerId)) point(e, "move"); });
  function release(e) { if (!touches.has(e.pointerId)) return; point(e, "up"); touches.delete(e.pointerId); }
  surface.addEventListener("pointerup", release);
  surface.addEventListener("pointercancel", release);

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
  connect();
})();
</script>
</body>
</html>
"""#
}
