/* REDMAGIC v3.1.0 —— 通信层：命令队列、状态快照、心跳、日志、自检
   数据契约（与 paths.sh 一致）：运行期文件全部在 <MODDIR>/run/ 下
     <MODDIR>/run/webui_cmd     命令队列（服务端每轮 mv 走再逐行分发）
     <MODDIR>/run/webui_status  服务端产出的快照：每行一条 key=value（不是 JSON）
     <MODDIR>/run/.webui_hb     前端心跳（服务端据此在 500ms / 2000ms 两档快照频率间切换）
     <MODDIR>/run/REDMAGIC.log  服务日志
   传输层优先走 KernelSU / ReSukiSU 的 window.ksu.exec；没有该桥接时才回落到
   旧的 HTTP ?cmd= 端点（便于在带自定义服务器的宿主里调试）。 */
(function (g) {
  'use strict';

  var state = { data: null, inflight: false, lastOk: 0, lastErr: '', polling: false, timer: 0 };
  var listeners = [];
  var MODDIR = '/data/adb/modules/REDMAGIC';
  var RUN_DIR = MODDIR + '/run';
  var CMD_FILE = RUN_DIR + '/webui_cmd';
  var STATUS_FILE = RUN_DIR + '/webui_status';
  var HB_FILE = RUN_DIR + '/.webui_hb';
  var LOG_FILE = RUN_DIR + '/REDMAGIC.log';

  function base() {
    var m = location.pathname.match(/^\/x\/([A-Za-z0-9_.-]+)\//);
    return m ? ('/x/' + m[1] + '/') : location.pathname.replace(/[^/]*$/, '');
  }

  /* ---- KernelSU JS 桥：window.ksu.exec(cmd) 同步返回 stdout ---- */
  function hasKsu() {
    return !!(g.ksu && typeof g.ksu.exec === 'function');
  }
  function sh(cmd) {
    if (!hasKsu()) return null;
    try {
      var out = g.ksu.exec(cmd);
      return out == null ? '' : String(out);
    } catch (e) {
      state.lastErr = 'exec: ' + ((e && e.message) || e);
      return null;
    }
  }
  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
  }
  function shellAppend(action, val) {
    var line = JSON.stringify({ action: action, value: val == null ? '' : String(val) });
    return sh("printf '%s\\n' " + q(line) + " >> " + q(CMD_FILE) +
              " && touch " + q(HB_FILE) + " && echo ok");
  }

  /* ---- 低层请求：KSU 走 fetch，其余环境自动回落 XHR ---- */
  function xhr(url) {
    return new Promise(function (resolve, reject) {
      var x = new XMLHttpRequest();
      x.open('GET', url, true);
      x.timeout = 15000;
      x.onload = function () {
        if (x.status >= 200 && x.status < 300) resolve(x.responseText);
        else reject(new Error('HTTP ' + x.status));
      };
      x.onerror = function () { reject(new Error('网络错误')); };
      x.ontimeout = function () { reject(new Error('超时')); };
      x.send();
    });
  }
  function httpGet(url) {
    if (typeof fetch === 'function') {
      return fetch(url, { cache: 'no-store' }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text();
      });
    }
    return xhr(url);
  }

  /* 文本协议：成功返回 "ok"，拒绝返回 "err:<原因>" */
  function send(cmd, val) {
    /* 心跳由 poll() 顺带 touch，不再入命令队列，避免每秒产生一条无效命令 */
    if (cmd === 'hb') {
      if (hasKsu()) { sh("touch " + q(HB_FILE)); return Promise.resolve(true); }
      var hbUrl = base() + '?cmd=send&c=hb&v=' + encodeURIComponent(String(val == null ? '' : val));
      return httpGet(hbUrl).then(function () { return true; }, function () { return true; });
    }
    if (hasKsu()) {
      var out = shellAppend(cmd, val);
      if (out != null && out.indexOf('ok') === 0) return Promise.resolve(true);
      return Promise.reject(new Error(out || state.lastErr || '命令写入失败'));
    }
    var url = base() + '?cmd=send&c=' + encodeURIComponent(cmd) + '&v=' + encodeURIComponent(val == null ? '' : String(val));
    return httpGet(url).then(function (txt) {
      if (txt.charAt(0) === 'o') return true;
      var msg = txt.slice(4) || 'rejected';
      throw new Error(msg);
    });
  }

  /* ---- 快照 ---- */
  function num(v) { var n = parseFloat(v); return isFinite(n) ? n : 0; }
  function flag(v) { return num(v) > 0; }
  function parse(txt) {
    var o = {};
    var parts = txt.split('\n');
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      var e = p.indexOf('=');
      if (e > 0) o[p.slice(0, e)] = p.slice(e + 1);
    }
    return o;
  }
  function poll() {
    if (state.inflight) return Promise.resolve(state.data);
    state.inflight = true;
    var req;
    if (hasKsu()) {
      req = Promise.resolve().then(function () {
        var txt = sh("touch " + q(HB_FILE) + " 2>/dev/null; cat " + q(STATUS_FILE) + " 2>/dev/null");
        if (txt == null) throw new Error(state.lastErr || 'exec 失败');
        return txt;
      });
    } else {
      req = httpGet(base() + '?cmd=status');
    }
    return req.then(function (txt) {
      var d = parse(txt);
      if (d.module_state == null && d.battery == null) throw new Error('空快照');
      state.data = d;
      state.lastOk = Date.now();
      state.lastErr = '';
      emit();
      return d;
    }).catch(function (e) {
      state.lastErr = (e && e.message) || 'poll failed';
      if (Date.now() - state.lastOk > 6000) {
        state.data = null;
        emit();
      }
      return state.data;
    }).then(function (d) {
      state.inflight = false;
      return d;
    });
  }
  function emit() { for (var i = 0; i < listeners.length; i++) { try { listeners[i](state.data); } catch (e) {} } }
  function onData(fn) { listeners.push(fn); if (state.data) { try { fn(state.data); } catch (e) {} } }

  /* 改动 → 立即拉一次快照，保证开关回弹正确 */
  function refreshSoon() { setTimeout(function () { poll(); }, 120); }

  /* ---- 心跳：服务端用 .webui_hb 判断 WebUI 是否还开着，决定轮询节奏与快照频率 ---- */
  function beat() {
    send('hb', Math.floor(Date.now() / 1000)).catch(function () {});
  }

  /* ---- 日志 / 自检 ---- */
  function readLog(tail) {
    var n = parseInt(tail, 10);
    if (!isFinite(n) || n < 1) n = 80;
    if (n > 2000) n = 2000;
    if (hasKsu()) {
      return Promise.resolve(sh("tail -n " + n + " " + q(LOG_FILE) + " 2>/dev/null") || '');
    }
    return httpGet(base() + '?cmd=read&n=' + n);
  }
  function runDiag() {
    if (hasKsu()) {
      /* 自检结果读回前端后立刻删掉临时文件，不在设备上留垃圾 */
      var out = '/data/local/tmp/REDMAGIC_debug_webui.log';
      var cmd = "MODDIR=" + q(MODDIR) + "; L=" + q(out) + "; export MODDIR L; " +
                "sh " + q(MODDIR + '/lib/diag.sh') + " >/dev/null 2>&1; " +
                "cat " + q(out) + " 2>/dev/null; rm -f " + q(out) + " 2>/dev/null";
      return Promise.resolve(sh(cmd) || '');
    }
    return httpGet(base() + '?cmd=read&d=1');
  }

  function start(ms) {
    if (state.polling) return;
    state.polling = true;
    poll();
    beat();
    state.timer = setInterval(function () { poll(); beat(); }, ms || 1000);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) { poll(); beat(); }
    });
  }

  g.API = {
    send: send, poll: poll, refreshSoon: refreshSoon, onData: onData,
    readLog: readLog, runDiag: runDiag,
    data: function () { return state.data; }
  };
})(window);
