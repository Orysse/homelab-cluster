// abe.lc: the vitrine's moving grounds, ported (Orysse/vitrine src/scripts/grounds.ts, main.ts).
//   liquid  blurred colour blobs drifting behind everything, pushed away by the pointer
//   waves   an op-art band fixed at the bottom, with a marquee of the stack
//   warp    the melted title (SVG turbulence displacement, animated)
//   trip    how strong all of it is (slider), pause; both remembered in this browser
// Everything is added outside Homepage's React tree. No "dollar + brace" anywhere in this
// file: Flux substitutes those.
(function () {
  if (window.__abeTrip) return;
  window.__abeTrip = true;

  var store = {
    get: function (k, d) { try { var v = localStorage.getItem("home." + k); return v === null ? d : v; } catch (e) { return d; } },
    set: function (k, v) { try { localStorage.setItem("home." + k, v); } catch (e) { /* storage blocked */ } },
  };
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var state = {
    running: store.get("running", reduced ? "0" : "1") === "1",
    trip: parseFloat(store.get("trip", "0.6")),
  };

  function el(tag, attrs, parent) {
    var n = document.createElement(tag);
    for (var k in attrs) n.setAttribute(k, attrs[k]);
    (parent || document.body).appendChild(n);
    return n;
  }
  function fit(cv, scale) {
    var r = cv.getBoundingClientRect();
    var d = Math.min(window.devicePixelRatio || 1, 2) * scale;
    var w = Math.max(1, Math.round(r.width * d)), h = Math.max(1, Math.round(r.height * d));
    if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
    return [w, h];
  }

  document.documentElement.classList.add("abe-trip");

  // Liquid light show
  var liquidCv = el("canvas", { id: "abe-liquid", "aria-hidden": "true" });
  var lx = liquidCv.getContext("2d");
  var lph = Math.random() * 10;
  var push = { x: 0.5, y: 0.5, k: 0 };
  var blobs = ["#e2135f", "#ff7a1a", "#ffcf5a", "#18b39b", "#7b2ff7", "#ff4fb0"].map(function (c) {
    return { c: c, fx: 0.3 + Math.random() * 0.6, fy: 0.3 + Math.random() * 0.6,
      px: Math.random() * 6.28, py: Math.random() * 6.28, r: 0.26 + Math.random() * 0.18 };
  });
  window.addEventListener("pointermove", function (e) {
    push = { x: e.clientX / window.innerWidth, y: e.clientY / window.innerHeight, k: 1 };
  });
  function liquid(dt) {
    var s = fit(liquidCv, 0.5), W = s[0], H = s[1];
    lph += dt * (0.08 + state.trip * 0.35);
    push.k *= 0.97;
    lx.filter = "none"; lx.globalAlpha = 1;
    lx.fillStyle = "#1a0b2e"; lx.fillRect(0, 0, W, H);
    lx.filter = "blur(" + Math.round(Math.min(W, H) * 0.06) + "px)";
    blobs.forEach(function (b, i) {
      var cx = 0.5 + 0.4 * Math.sin(lph * b.fx + b.px);
      var cy = 0.5 + 0.38 * Math.cos(lph * b.fy + b.py);
      cx += (cx - push.x) * 0.3 * push.k;
      cy += (cy - push.y) * 0.3 * push.k;
      lx.fillStyle = b.c; lx.globalAlpha = 0.9;
      lx.beginPath();
      lx.ellipse(cx * W, cy * H, b.r * W * (1 + 0.2 * Math.sin(lph * 2 + i)), b.r * H * (1 + 0.2 * Math.cos(lph * 1.7 + i)), lph * 0.3 + i, 0, 6.283);
      lx.fill();
    });
    lx.filter = "none"; lx.globalAlpha = 1;
  }

  // Waves band + marquee + trip controls
  var band = el("div", { id: "abe-band" });
  var wavesCv = el("canvas", { "aria-hidden": "true" }, band);
  var wx = wavesCv.getContext("2d");
  var wph = Math.random() * 10;
  var pal = ["#ff7a1a", "#1d1813", "#ff4fb0", "#1d1813", "#ffe23a", "#1d1813", "#18b3e0", "#1d1813"];
  function waves(dt) {
    var s = fit(wavesCv, 0.7), W = s[0], H = s[1];
    wph += dt * (0.25 + state.trip * 1.2);
    var bh = 18 * Math.min(window.devicePixelRatio || 1, 2) * 0.7;
    var n = Math.ceil(H / bh);
    var amp = bh * (0.6 + state.trip * 2.2);
    var fq = (2.2 * Math.PI) / Math.max(W, 600);
    function y(X, i) { return i * bh + amp * Math.sin(X * fq + wph + i * 0.35) + amp * 0.5 * Math.sin(X * fq * 0.37 - wph * 0.6); }
    for (var i = -4; i < n + 4; i++) {
      wx.beginPath();
      for (var X = 0; X <= W; X += 8) X === 0 ? wx.moveTo(X, y(X, i)) : wx.lineTo(X, y(X, i));
      for (var X2 = W; X2 >= 0; X2 -= 8) wx.lineTo(X2, y(X2, i + 1) + 1);
      wx.closePath();
      wx.fillStyle = pal[(i + 400) % pal.length];
      wx.fill();
    }
  }
  var words = ["abe.lc", "nixos", "microvm", "k3s", "cilium", "flux", "openbao", "pocket-id", "headscale", "crowdsec", "tetragon", "victoriametrics", "traefik"];
  var line = words.join("  ✺  ") + "  ✺  ";
  var marquee = el("div", { class: "abe-marquee", "aria-hidden": "true" }, band);
  el("span", {}, marquee).textContent = line + line;
  el("span", {}, marquee).textContent = line + line;

  var ctl = el("div", { class: "abe-ctl" }, band);
  var lab = el("label", { for: "abe-trip-range" }, ctl); lab.textContent = "trip";
  var range = el("input", { id: "abe-trip-range", type: "range", min: "0", max: "1", step: "0.01" }, ctl);
  range.value = String(state.trip);
  var btn = el("button", { type: "button" }, ctl);

  // Melted title
  var svgNS = "http://www.w3.org/2000/svg";
  var svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("style", "position:absolute;width:0;height:0");
  svg.innerHTML = '<filter id="abe-warp" x="-5%" y="-15%" width="110%" height="140%">' +
    '<feTurbulence id="abe-warpT" type="turbulence" baseFrequency="0.006 0.022" numOctaves="2" seed="2" result="n"/>' +
    '<feDisplacementMap id="abe-warpD" in="SourceGraphic" in2="n" scale="18" xChannelSelector="R" yChannelSelector="B"/></filter>';
  document.body.appendChild(svg);
  var warpT = document.getElementById("abe-warpT"), warpD = document.getElementById("abe-warpD");

  // Spinning rings, half off screen
  el("div", { class: "abe-rings", "aria-hidden": "true" });

  function applyTrip() {
    warpD.setAttribute("scale", (4 + state.trip * 40).toFixed(1));
    document.documentElement.style.setProperty("--trip", String(state.trip));
  }
  function applyRunning() {
    document.documentElement.classList.toggle("abe-calm", !state.running);
    btn.textContent = state.running ? "pause" : "play";
    btn.setAttribute("aria-pressed", String(state.running));
  }
  range.addEventListener("input", function () { state.trip = Number(range.value); store.set("trip", String(state.trip)); applyTrip(); });
  btn.addEventListener("click", function () { state.running = !state.running; store.set("running", state.running ? "1" : "0"); applyRunning(); });
  applyTrip(); applyRunning();
  liquid(0); waves(0);

  // One loop at ~30 fps; idle when hidden or paused.
  var last = performance.now(), acc = 0;
  function loop(now) {
    requestAnimationFrame(loop);
    var dt = Math.min(0.1, (now - last) / 1000);
    last = now; acc += dt;
    if (acc < 1 / 30 || document.hidden) return;
    var step = acc; acc = 0;
    if (!state.running) return;
    liquid(step); waves(step);
    var k = (now / 1000) * (0.5 + state.trip);
    warpT.setAttribute("baseFrequency", (0.006 + 0.003 * Math.sin(k * 0.35)).toFixed(4) + " " + (0.022 + 0.008 * Math.sin(k * 0.27)).toFixed(4));
  }
  requestAnimationFrame(loop);
})();
