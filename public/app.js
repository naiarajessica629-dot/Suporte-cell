// App compartilhado: o papel (viewer ou publisher) vem do ?role= no src do <script>.
(function () {
  "use strict";
  var ROLE = new URL(document.currentScript.src).searchParams.get("role");
  var $ = function (id) { return document.getElementById(id); };
  var wsProto = location.protocol === "https:" ? "wss" : "ws";

  var pc = null, ws = null, stream = null, statTimer = null, t0 = 0;

  function wsConnect(code, onJoined) {
    ws = new WebSocket(wsProto + "://" + location.host + "/signal");
    ws.onopen = function () { ws.send(JSON.stringify({ t: "join", code: code, role: ROLE })); };
    ws.onmessage = function (ev) {
      var m = JSON.parse(ev.data);
      if (m.t === "error") return onError(m.reason);
      if (m.t === "joined") return onJoined(m.iceServers);
      handle(m);
    };
    ws.onclose = function () {};
  }
  function sig(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }

  function makePC(iceServers) {
    pc = new RTCPeerConnection({ iceServers: iceServers });
    pc.onicecandidate = function (e) { if (e.candidate) sig({ t: "ice", candidate: e.candidate }); };
    pc.onconnectionstatechange = function () {
      if (pc.connectionState === "failed") pc.restartIce();
    };
    return pc;
  }

  // ===================================================================
  if (ROLE === "viewer") viewer();
  else publisher();
  // ===================================================================

  function viewer() {
    var statusState = "idle";
    function setPill(s) {
      var map = { pending: ["pending", "Em espera"], connected: ["connected", "Conectado"], ended: ["ended", "Encerrado"] };
      var d = map[s] || map.pending; statusState = s;
      $("pill").className = "pill " + d[0];
      $("pill").innerHTML = "<i></i>" + d[1];
    }
    function log(msg) {
      var r = document.createElement("div"), t = new Date();
      r.innerHTML = "<time>" + t.toLocaleTimeString("pt-BR") + "</time>" + msg;
      $("log").prepend(r);
    }

    var countTimer = null;
    $("gen").addEventListener("click", function () {
      $("gen").disabled = true;
      fetch("/api/sessions", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ label: $("label").value, minutes: parseInt($("exp").value, 10) }),
      }).then(function (r) {
        if (r.status === 401) { location.href = "/login"; throw new Error("auth"); }
        return r.json();
      }).then(function (d) {
        $("gen").disabled = false;
        $("link").textContent = d.url;
        $("invite").hidden = false;
        var msg = encodeURIComponent("Suporte técnico: toque no link para compartilhar sua tela. " + d.url);
        $("wa").href = "https://wa.me/?text=" + msg;
        $("sms").href = "sms:?body=" + msg;
        $("mail").href = "mailto:?subject=Acesso de suporte&body=" + msg;
        setPill("pending"); log("Convite gerado para <b>" + ($("label").value || "cliente") + "</b>");
        startCount(d.expiresInMin);
        connectRoom(d.url.split("/s/")[1]);
      }).catch(function () { $("gen").disabled = false; log("Falha ao gerar convite"); });
    });

    function startCount(min) {
      var end = Date.now() + min * 60000;
      clearInterval(countTimer);
      countTimer = setInterval(function () {
        var left = Math.max(0, end - Date.now());
        if (left <= 0 && statusState === "pending") { clearInterval(countTimer); $("count").textContent = "Link expirado"; setPill("ended"); return; }
        var m = Math.floor(left / 60000), s = Math.floor((left % 60000) / 1000);
        $("count").textContent = "Expira em " + m + ":" + String(s).padStart(2, "0");
      }, 1000);
    }

    function connectRoom(code) {
      wsConnect(code, function (ice) {
        makePC(ice);
        pc.ontrack = function (e) {
          $("remote").srcObject = e.streams[0];
          $("empty").hidden = true; $("remote").hidden = false; $("bar").hidden = false;
          setPill("connected"); log("Cliente conectou — <b>tela ao vivo</b>");
          $("conn").textContent = "WebRTC"; $("conn").style.color = "var(--good)";
          startStats();
        };
        log("Aguardando o cliente abrir o link…");
      });
    }

    window._handle = function (m) {
      if (m.t === "answer" || m.t === "offer") {
        var desc = new RTCSessionDescription({ type: m.t, sdp: m.sdp });
        if (m.t === "offer") {
          pc.setRemoteDescription(desc)
            .then(function () { return pc.createAnswer(); })
            .then(function (a) { return pc.setLocalDescription(a); })
            .then(function () { sig({ t: "answer", sdp: pc.localDescription.sdp }); });
        }
      } else if (m.t === "ice") {
        pc.addIceCandidate(new RTCIceCandidate(m.candidate)).catch(function () {});
      } else if (m.t === "bye") {
        endView(); log("Sessão encerrada (" + (m.reason || "") + ")");
      }
    };

    function startStats() {
      clearInterval(statTimer);
      statTimer = setInterval(function () {
        if (!pc) return;
        pc.getStats(null).then(function (stats) {
          var inbound, pair;
          stats.forEach(function (r) {
            if (r.type === "inbound-rtp" && r.kind === "video") inbound = r;
            if (r.type === "candidate-pair" && r.state === "succeeded" && r.nominated) pair = r;
          });
          if (inbound) {
            $("fps").innerHTML = (inbound.framesPerSecond ? Math.round(inbound.framesPerSecond) : "—") + " <small>fps</small>";
            if (inbound._lastBytes != null) {
              var kbps = (inbound.bytesReceived - inbound._lastBytes) * 8 / 1000;
              $("bit").innerHTML = (kbps / 1000).toFixed(1) + " <small>Mbps</small>";
            }
            inbound._lastBytes = inbound.bytesReceived;
          }
          if (pair && pair.currentRoundTripTime != null) {
            var ms = Math.round(pair.currentRoundTripTime * 1000);
            $("lat").innerHTML = ms + " <small>ms</small>";
            $("lat").style.color = ms > 400 ? "var(--crit)" : ms > 250 ? "var(--warn)" : "";
          }
        });
      }, 1000);
    }

    function endView() {
      if (statTimer) clearInterval(statTimer);
      if (pc) pc.close(), pc = null;
      $("remote").hidden = true; $("bar").hidden = true; $("empty").hidden = false;
      ["lat", "fps", "bit"].forEach(function (id) { $(id).innerHTML = "—"; });
      $("conn").textContent = "—"; $("conn").style.color = "";
      if (statusState === "connected") setPill("ended");
    }

    $("end").addEventListener("click", function () { sig({ t: "bye" }); endView(); log("Você encerrou a sessão"); });
    $("fs").addEventListener("click", function () {
      var el = $("stage");
      if (document.fullscreenElement) document.exitFullscreen();
      else if (el.requestFullscreen) el.requestFullscreen().catch(function () {});
    });

    // ---- Guia visual: apontar sobre a tela do cliente ----
    var pointing = false, lastSent = 0;
    var video = $("remote"), stage = $("stage"), marker = $("marker");
    function setPointing(on) {
      pointing = on;
      $("pointBtn").style.background = on ? "rgba(75,147,255,.9)" : "";
      $("pointBtn").style.borderColor = on ? "transparent" : "";
      $("clearBtn").hidden = !on;
      stage.style.cursor = on ? "crosshair" : "";
      if (!on) { marker.hidden = true; sig({ t: "clear" }); }
    }
    $("pointBtn").addEventListener("click", function () { setPointing(!pointing); });
    $("clearBtn").addEventListener("click", function () { marker.hidden = true; sig({ t: "clear" }); });
    function norm(ev) {
      var r = video.getBoundingClientRect(), vw = video.videoWidth, vh = video.videoHeight;
      if (!vw || !vh) return null;
      var scale = Math.min(r.width / vw, r.height / vh);
      var dw = vw * scale, dh = vh * scale;
      var ox = r.left + (r.width - dw) / 2, oy = r.top + (r.height - dh) / 2;
      var x = (ev.clientX - ox) / dw, y = (ev.clientY - oy) / dh;
      if (x < 0 || x > 1 || y < 0 || y > 1) return null;
      return { x: x, y: y };
    }
    function onMove(ev) {
      if (!pointing || video.hidden) return;
      var n = norm(ev);
      if (!n) { marker.hidden = true; return; }
      var sr = stage.getBoundingClientRect();
      marker.style.left = (ev.clientX - sr.left) + "px";
      marker.style.top = (ev.clientY - sr.top) + "px";
      marker.hidden = false;
      var now = Date.now();
      if (now - lastSent > 60) { lastSent = now; sig({ t: "point", x: +n.x.toFixed(4), y: +n.y.toFixed(4) }); }
    }
    stage.addEventListener("pointermove", onMove);
    stage.addEventListener("pointerdown", onMove);
    $("copy").addEventListener("click", function () {
      var txt = $("link").textContent, b = $("copy");
      function ok() { b.style.color = "var(--good)"; setTimeout(function () { b.style.color = ""; }, 1200); }
      if (navigator.clipboard) navigator.clipboard.writeText(txt).then(ok).catch(sel); else sel();
      function sel() { var r = document.createRange(); r.selectNodeContents($("link")); var s = getSelection(); s.removeAllRanges(); s.addRange(r); ok(); }
    });

    var pb = $("pairBtn");
    if (pb) pb.addEventListener("click", function () {
      var code = ($("pairCode").value || "").replace(/\D/g, "");
      if (code.length !== 6) { log("Código inválido — são 6 dígitos."); return; }
      $("inviteBox").hidden = true;
      setPill("pending");
      log("Conectando ao cliente — código " + code);
      connectRoom(code);
    });

    $("logout").addEventListener("click", function () {
      fetch("/api/logout", { method: "POST" }).then(function () { location.href = "/login"; });
    });
    fetch("/api/me").then(function (r) { return r.json(); }).then(function (d) {
      if (d && d.defaultPass) $("passwarn").hidden = false;
    }).catch(function () {});

    setPill("pending");
  }

  function publisher() {
    var code = location.pathname.split("/s/")[1] || "";
    $("code").textContent = code;
    var canShare = !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia);
    var isMobile = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
    if (isMobile || !canShare) {
      $("mobileWarn").hidden = false;
      $("share").disabled = true;
      var cs = document.getElementById("codeShow");
      if (cs) cs.textContent = code;
    }

    function setStatus(t) { $("status").textContent = t; }

    $("share").addEventListener("click", function () {
      $("share").disabled = true;
      setStatus("Abrindo a permissão do navegador…");
      navigator.mediaDevices.getDisplayMedia({
        video: { frameRate: 15, width: { ideal: 1280 } }, audio: false,
      }).then(function (s) {
        stream = s;
        setStatus("Permissão concedida. Conectando ao atendente…");
        s.getVideoTracks()[0].addEventListener("ended", stopShare);
        connect();
      }).catch(function () {
        $("share").disabled = false;
        setStatus("Você cancelou ou o navegador negou o compartilhamento.");
      });
    });

    function connect() {
      wsConnect(code, function (ice) {
        makePC(ice);
        stream.getTracks().forEach(function (tk) { pc.addTrack(tk, stream); });
        var sender = pc.getSenders()[0];
        try {
          var p = sender.getParameters();
          p.degradationPreference = "maintain-resolution";
          p.encodings = [{ maxBitrate: 1500000, maxFramerate: 15 }];
          sender.setParameters(p);
        } catch (e) {}
      });
    }

    window._handle = function (m) {
      if (m.t === "viewer-ready") {
        pc.createOffer().then(function (o) { return pc.setLocalDescription(o); })
          .then(function () { sig({ t: "offer", sdp: pc.localDescription.sdp }); });
        showSharing();
      } else if (m.t === "answer") {
        pc.setRemoteDescription(new RTCSessionDescription({ type: "answer", sdp: m.sdp }));
      } else if (m.t === "ice") {
        pc.addIceCandidate(new RTCIceCandidate(m.candidate)).catch(function () {});
      } else if (m.t === "bye") {
        stopShare();
      }
    };

    function showSharing() {
      $("preShare").hidden = true; $("sharing").hidden = false;
      t0 = Date.now();
      statTimer = setInterval(function () {
        var s = Math.floor((Date.now() - t0) / 1000);
        $("cTime").textContent = Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
        $("cState").textContent = pc && pc.connectionState === "connected" ? "Ao vivo" : "Conectando";
      }, 1000);
    }

    function stopShare() {
      if (statTimer) clearInterval(statTimer);
      if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
      sig({ t: "bye" });
      if (pc) pc.close(), pc = null;
      if (ws) ws.close();
      $("sharing").hidden = true; $("preShare").hidden = false;
      $("share").disabled = false;
      setStatus("Compartilhamento encerrado. Você pode iniciar de novo se precisar.");
    }
    $("stop").addEventListener("click", stopShare);
  }

  function handle(m) { if (window._handle) window._handle(m); }
  function onError(reason) {
    if (ROLE === "publisher") { try { $("status").textContent = "Erro: " + reason; $("share").disabled = false; } catch (e) {} }
    else { try { var r = document.createElement("div"); r.innerHTML = "<time>" + new Date().toLocaleTimeString("pt-BR") + "</time>Erro: " + reason; $("log").prepend(r); } catch (e) {} }
  }
})();
