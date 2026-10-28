/* REDMAGIC v3.1.0 —— 入口：导航、语言、轮询
   轮询节奏（与服务端 loop.sh 的心跳判断配套）：
     页面可见 → 1000ms 一次快照 + 一次心跳，服务端因此以 500ms 出快照；
     页面隐藏 → 停掉轮询（省电，服务端 3 秒内自动切到 2000ms 的省电节奏）。 */
(function (g) {
  'use strict';
  var t = g.t;
  var VISIBLE_MS = 1000;
  var PANELS = ['fan', 'pump', 'charge', 'thermal', 'touch', 'rate', 'perf', 'bright', 'status'];
  var timer = 0;

  function $(id) { return document.getElementById(id); }

  /* ---------------- 导航 ---------------- */
  function buildNav() {
    var nav = $('nav');
    if (!nav) return;
    var html = '';
    for (var i = 0; i < PANELS.length; i++) {
      html += '<button type="button" data-p="' + PANELS[i] + '">' + t('nav_' + PANELS[i]) + '</button>';
    }
    nav.innerHTML = html;
    nav.addEventListener('click', function (ev) {
      var b = ev.target;
      while (b && b !== nav && b.tagName !== 'BUTTON') b = b.parentNode;
      if (!b || b === nav) return;
      show(b.getAttribute('data-p'));
    });
  }

  function show(p) {
    if (PANELS.indexOf(p) < 0) p = 'fan';
    try { localStorage.setItem('rm_panel', p); } catch (e) {}
    var secs = document.querySelectorAll('section.card');
    for (var i = 0; i < secs.length; i++) {
      var isOn = secs[i].getAttribute('data-panel') === p;
      secs[i].style.display = isOn ? '' : 'none';
    }
    var nav = $('nav');
    var bs = nav ? nav.getElementsByTagName('button') : [];
    for (var j = 0; j < bs.length; j++) {
      if (bs[j].getAttribute('data-p') === p) bs[j].classList.add('on');
      else bs[j].classList.remove('on');
    }
    window.scrollTo(0, 0);
  }

  /* ---------------- 渲染分发 ---------------- */
  function render(d) {
    if (!d) return;
    g.CARDS.render(d);
    g.TOUCH.render(d);
    g.STATUS.render(d);
  }

  /* ---------------- 轮询 ---------------- */
  function tick() {
    g.API.poll();
    g.API.send('hb', Math.floor(Date.now() / 1000)).catch(function () {});
  }
  function startPolling() {
    if (timer) return;
    tick();
    timer = setInterval(tick, VISIBLE_MS);
  }
  function stopPolling() {
    if (!timer) return;
    clearInterval(timer);
    timer = 0;
  }

  /* ---------------- 版本号 ----------------
     真源是 module.prop，webroot 读不到它，所以安装校验脚本把版本写进
     webroot/version.txt，这里 fetch 回来填到标题行。文件不存在就保持原样。 */
  function loadVersion() {
    var sub = $('appSub');
    if (!sub || !g.XMLHttpRequest) return;
    try {
      var x = new XMLHttpRequest();
      x.open('GET', 'version.txt?_=' + Date.now(), true);
      x.onload = function () {
        if (x.status >= 200 && x.status < 300) {
          var v = (x.responseText || '').replace(/\s+/g, '');
          if (v) sub.textContent = sub.textContent.split(' · ')[0] + ' · ' + v;
        }
      };
      x.send();
    } catch (e) {}
  }

  function init() {
    /* HTML 里写的是中文默认文案，首屏必须先按当前语言刷一遍，
       否则英文环境下只有动态生成的文字是英文，静态标签仍是中文。 */
    g.I18N.applyLang();
    g.CARDS.init();
    g.TOUCH.init();
    g.STATUS.init();
    buildNav();

    var saved = null;
    try { saved = localStorage.getItem('rm_panel'); } catch (e) {}
    show(saved || 'fan');
    loadVersion();

    var lb = $('langBtn');
    if (lb) lb.addEventListener('click', function () {
      g.I18N.setLang(g.I18N.lang() === 'en' ? 'zh' : 'en');
      location.reload();
    });

    g.API.onData(render);
    startPolling();

    document.addEventListener('visibilitychange', function () {
      if (document.hidden) stopPolling();
      else { startPolling(); g.API.poll(); }
    });

    /* 离开页面：把「息屏保持」这类临时接管还回去，服务端按记忆继续跑 */
    window.addEventListener('pagehide', function () {
      /* KSU 环境下 send 走 window.ksu.exec（同步），HTTP 只作为其他宿主里的兜底 */
      try { g.API.send('release', ''); } catch (e) {}
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})(window);
