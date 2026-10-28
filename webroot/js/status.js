/* REDMAGIC v3.1.0 —— 状态页 + 日志页
   模块健康直接来自服务端 module_state（2 正常 / 1 部分异常 / 0 未运行），
   前端不自己推断，避免两边口径不一致。 */
(function (g) {
  'use strict';
  var t = g.t;
  var C = null;
  var logBusy = false;

  function flags(d, k) { return (d[k] || '') === '1'; }

  function paint(id, on1, warn) {
    var e = document.getElementById(id);
    if (!e) return;
    e.textContent = on1 ? t('on') : t('off_s');
    e.className = 'n ' + (on1 ? (warn ? 'warn' : 'ok') : '');
  }

  function render(d) {
    if (!d) {
      C.setText('stFail', t('status_offline'));
      C.dot('modDot', '');
      return;
    }
    var ms = parseInt(d.module_state, 10);
    var m = document.getElementById('stModule');
    if (m) {
      m.textContent = ms === 2 ? t('health_ok') : ms === 1 ? t('health_partial') : t('health_dead');
      m.className = 'n ' + (ms === 2 ? 'ok' : ms === 1 ? 'warn' : 'bad');
    }
    var dotKind = ms === 2 ? 'on' : ms === 1 ? 'warn' : '';
    C.dot('modDot', dotKind);

    paint('stCs', flags(d, 'cs'));
    paint('stThermal', flags(d, 'thermal_effective'), flags(d, 'thermal_on') && !flags(d, 'thermal_effective'));
    paint('stBoost', flags(d, 'boost_on') && flags(d, 'boost_ready'), flags(d, 'boost_on') && !flags(d, 'boost_ready'));
    paint('stRate', flags(d, 'rate_on'));
    paint('stTouch', flags(d, 'touch_on'));
    var freqOn = (d.cpu0_sel && d.cpu0_sel !== '0') || (d.cpu1_sel && d.cpu1_sel !== '0') || (d.gpu_sel && d.gpu_sel !== '0');
    var freqOk = flags(d, 'cpu_ok') || flags(d, 'gpu_ok');
    paint('stCpu', !!freqOn && freqOk, !!freqOn && !freqOk);

    var need = 0, have = 0, keys = ['fan_on', 'pump_on', 'charge_on', 'thermal_on', 'boost_on', 'touch_on', 'rate_on', 'bright_on'];
    for (var i = 0; i < keys.length; i++) { need++; if (flags(d, keys[i])) have++; }
    var bar = document.getElementById('stBar');
    if (bar) bar.style.width = (need ? Math.round(have * 100 / need) : 0) + '%';

    /* 有失败项就只报失败项；没有就报「已开 x/8」*/ 
    var f = (d.module_fail || '').trim();
    C.setText('stFail', f ? (t('st_fail') + ': ' + f) : (have + '/' + need + ' · ' + t('fail_none')));

    /* ---- 电池健康（内核直读，读不到就留 --）---- */
    var soh = parseInt(d.soh, 10);
    var sohEl = document.getElementById('bhSoh');
    if (sohEl) {
      if (isFinite(soh) && soh > 0) {
        sohEl.textContent = soh + '%';
        sohEl.className = 'n ' + (soh >= 80 ? 'ok' : soh >= 60 ? 'warn' : 'bad');
      } else { sohEl.textContent = '--'; sohEl.className = 'n'; }
    }
    C.setText('bhCycle', (d.cycle && d.cycle !== '') ? d.cycle + ' 次' : '--');
    var full = (d.full_mah && d.design_mah) ? (d.full_mah + '/' + d.design_mah + ' mAh') : '--';
    C.setText('bhFull', full);
    C.setText('bhRes', (d.res_mohm && d.res_mohm !== '') ? d.res_mohm + ' mΩ' : '--');
  }

  function setLog(txt) {
    var e = document.getElementById('log');
    if (!e) return;
    e.textContent = (txt && txt.replace(/\s+$/, '')) || t('log_empty');
  }

  function readLog() {
    if (logBusy) return;
    logBusy = true;
    g.API.readLog(80).then(function (txt) {
      setLog(txt);
      C.toast(t('toast_log'), 'ok');
    }, function (e) { C.toastErr(e); }).then(function () { logBusy = false; });
  }

  function runDiag() {
    if (logBusy) return;
    logBusy = true;
    g.API.runDiag().then(function (txt) {
      setLog(txt);
      C.toast(t('toast_diag'), 'ok');
    }, function (e) { C.toastErr(e); }).then(function () { logBusy = false; });
  }

  function init() {
    C = g.CARDS;
    setLog('');
    var a = document.getElementById('logRefresh');
    var b = document.getElementById('logDiag');
    if (a) a.addEventListener('click', readLog);
    if (b) b.addEventListener('click', runDiag);
  }

  g.STATUS = { init: init, render: render };
})(window);
