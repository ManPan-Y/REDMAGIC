/* REDMAGIC v3.1.0 —— 通用控件 + 六张功能卡：风扇 / 液冷 / 充电 / 温控 / 采样率 / 亮度
   规矩：任何一次点击都只发命令，状态一律等快照回来再渲染（不做乐观更新），
   这样节点写失败、系统开关没开时，界面显示的和真机一致。 */
(function (g) {
  'use strict';
  var t = g.t;

  /* ---------------- DOM 小工具 ---------------- */
  function $(id) { return document.getElementById(id); }
  function setText(id, s) { var e = $(id); if (e && e.textContent !== s) e.textContent = s; }
  function setVal(id, v) {
    var e = $(id);
    if (!e) return;
    if (e.type === 'checkbox') { var b = !!v; if (e.checked !== b) e.checked = b; return; }
    if (document.activeElement === e) return;   // 正在拖的滑杆不回写
    if (v == null) return;
    if (e.value !== String(v)) e.value = String(v);
  }
  function show(id, on) { var e = $(id); if (e) e.style.display = on ? '' : 'none'; }
  function dot(id, s) {
    var e = $(id);
    if (!e) return;
    e.className = 'dot' + (s === 'on' ? ' on' : s === 'warn' ? ' warn' : '');
  }

  /* ---------------- 吐司 ---------------- */
  var toastTimer = 0;
  function toast(msg, kind) {
    var e = $('toast');
    if (!e) return;
    e.textContent = msg;
    e.className = 'toast show' + (kind ? ' ' + kind : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { e.className = 'toast'; }, 1900);
  }
  function toastErr(e) { toast((e && e.message) || t('toast_fail'), 'bad'); }

  /* ---------------- 命令 ---------------- */
  function cmd(c, v) {
    return g.API.send(c, v).then(function () {
      g.API.refreshSoon();
      return true;
    }, function (e) {
      toastErr(e);
      g.API.refreshSoon();
      return false;
    });
  }

  /* ---------------- 开关：勾上才发命令 ---------------- */
  function bindSwitch(id, action) {
    var el = $(id);
    if (!el) return;
    el.addEventListener('change', function () {
      var on = el.checked;
      cmd(action, on ? 'on' : 'off').then(function (ok) {
        if (ok) toast(t(on ? 'toast_on' : 'toast_off'), 'ok');
        else g.API.refreshSoon();
      });
    });
  }

  /* ---------------- 滑杆：松手才发（拖动过程只在本地显示） ---------------- */
  function bindRange(id, labelId, action, suffix) {
    var el = $(id);
    if (!el) return;
    var fmt = function (v) { return String(v) + (suffix || ''); };
    el.addEventListener('input', function () { setText(labelId, fmt(el.value)); });
    el.addEventListener('change', function () {
      var v = parseInt(el.value, 10);
      if (!isFinite(v)) return;
      cmd(action, v).then(function (ok) { if (ok) toast(t('toast_applied'), 'ok'); });
    });
  }

  /* ---------------- 分段按钮：off / auto / custom ---------------- */
  function paintSeg(id, v) {
    var box = $(id);
    if (!box) return;
    var bs = box.getElementsByTagName('button');
    for (var i = 0; i < bs.length; i++) {
      if (bs[i].getAttribute('data-v') === v) bs[i].classList.add('on');
      else bs[i].classList.remove('on');
    }
  }
  function bindSeg(id, pick, label) {
    var box = $(id);
    if (!box) return;
    box.addEventListener('click', function (ev) {
      var b = ev.target;
      while (b && b !== box && b.tagName !== 'BUTTON') b = b.parentNode;
      if (!b || b === box) return;
      var v = b.getAttribute('data-v');
      if (!v) return;
      cmd(pick, v).then(function (ok) {
        if (!ok) return;
        paintSeg(id, v);
        if (label && label.thr) show(label.thr, v === 'custom');
        toast(t('toast_applied'), 'ok');
      });
    });
  }

  /* ---------------- 数字输入 + 应用按钮 ---------------- */
  function bindNum(id, btnId, action, lo, hi, labelId, suffix) {
    var el = $(id), btn = $(btnId);
    if (!el || !btn) return;
    btn.addEventListener('click', function () {
      var v = parseInt(String(el.value).replace(/[^0-9]/g, ''), 10);
      if (!isFinite(v) || v < lo || v > hi) { toast(t('toast_bad'), 'bad'); return; }
      cmd(action, v).then(function (ok) {
        if (ok) { if (labelId) setText(labelId, String(v) + (suffix || '')); toast(t('toast_applied'), 'ok'); }
      });
    });
  }

  /* ---------------- 下拉：选中即发命令（prefix 用于 "0=频率" 这种复合值） ---------------- */
  function bindSel(id, action, prefix) {
    var el = $(id);
    if (!el) return;
    el.addEventListener('change', function () {
      var v = prefix == null ? el.value : (prefix + '=' + el.value);
      cmd(action, v).then(function (ok) { if (ok) toast(t('toast_applied'), 'ok'); });
    });
  }

  /* ---------------- 渲染：快照 -> 界面 ---------------- */
  function num(d, k) { var v = parseInt(d[k], 10); return isFinite(v) ? v : 0; }
  function on(d, k) { return num(d, k) === 1; }

  function renderFan(d) {
    var enabled = on(d, 'fan_on'), sys = on(d, 'fan_enabled'), avail = on(d, 'fan_available');
    var lvl = d.fan_level_saved || '';
    var tmode = d.fan_temp_ctrl === '1' ? (d.fan_temp_mode || 'auto') : 'off';
    var lvNow = d.fan_level;

    dot('fanDot', !avail ? 'warn' : enabled ? (sys ? 'on' : 'warn') : '');
    setVal('fanOn', enabled);
    setVal('fanKeep', on(d, 'fan_keep'));

    var s;
    if (!avail) s = t('t_disabled');
    else if (!enabled) s = t('t_idle');
    else if (!sys) s = t('t_wait');
    else if (lvNow) s = t('t_active') + ' · ' + lvNow + ' / 5';
    else s = t('t_applying');
    setText('fanStateDesc', s);

    if (lvl) {
      setVal('fanLevel', lvl);
      setText('fanLevelVal', lvl + ' / 5');
    } else if (lvNow) {
      setText('fanLevelVal', lvNow + ' / 5');
    }
    $('fanLevel').disabled = !avail;

    paintSeg('fanTempSeg', tmode);
    setVal('fanTempThr', d.fan_temp_thr || 40);
    setText('fanTempThrVal', (d.fan_temp_thr || '40') + ' ' + t('deg'));
    show('fanTempThrWrap', tmode === 'custom');
  }

  function renderPump(d) {
    var enabled = on(d, 'pump_on'), avail = on(d, 'pump_available');
    var lvl = d.pump_level_saved || '';
    var tmode = d.pump_temp_ctrl === '1' ? (d.pump_temp_mode || 'auto') : 'off';
    var lvNow = d.pump_level;

    dot('pumpDot', !avail ? 'warn' : enabled ? 'on' : '');
    setVal('pumpOn', enabled);
    setVal('pumpKeep', on(d, 'pump_keep'));

    var s;
    if (!avail) s = t('t_disabled');
    else if (!enabled) s = t('t_idle');
    else if (lvNow) s = t('t_active') + ' · ' + lvNow + ' / 4';
    else s = t('t_applying');
    setText('pumpStateDesc', s);

    if (lvl) { setVal('pumpLevel', lvl); setText('pumpLevelVal', lvl + ' / 4'); }
    else if (lvNow) { setText('pumpLevelVal', lvNow + ' / 4'); }
    $('pumpLevel').disabled = !avail;

    paintSeg('pumpTempSeg', tmode);
    setVal('pumpTempThr', d.pump_temp_thr || 40);
    setText('pumpTempThrVal', (d.pump_temp_thr || '40') + ' ' + t('deg'));
    show('pumpTempThrWrap', tmode === 'custom');
  }

  function renderCharge(d) {
    var sep = d.cs === '1', armed = on(d, 'charge_on'), cap = num(d, 'battery'), thr = num(d, 'threshold');
    var boost = on(d, 'boost_on'), ready = on(d, 'boost_ready'), thermal = on(d, 'thermal_on');

    dot('chargeDot', sep ? 'on' : armed ? 'warn' : '');
    setVal('chargeOn', armed);
    setVal('chargeThr', thr || 100);
    setText('chargeThrVal', (thr || 100) + ' ' + t('pct'));

    var s;
    if (!armed) s = t('t_split_off');
    else if (sep) s = t('t_split_on');
    else s = t('t_split_wait');
    if (armed) s += ' · ' + cap + t('pct') + ' / ' + thr + t('pct');
    setText('chargeSepDesc', s);

    setVal('boostOn', boost);
    var b;
    if (!thermal) b = t('t_boost_blocked') + ' · ' + t('thermal_title');
    else if (!boost) b = t('t_boost_off');
    else if (ready) b = t('t_boost_on');
    else b = t('t_boost_blocked');
    setText('boostDesc', b);
    setVal('boostThr', d.boost_thr || 42);
    setText('boostThrVal', (d.boost_thr || '42') + ' ' + t('deg'));
    setVal('boostHeat', on(d, 'boost_heat'));

    /* 熄屏提速：开关开着但守卫没过时显示待命，节点确实为 0 才显示生效 */
    var fast = on(d, 'fast_on'), fastReady = on(d, 'fast_ready'), fastAvail = on(d, 'fast_avail');
    setVal('fastOn', fast && fastAvail);
    setText('fastDesc', !fastAvail ? t('t_disabled') : !fast ? t('t_idle') : fastReady ? t('t_fast_on') : t('t_fast_wait'));
  }

  function renderThermal(d) {
    var want = on(d, 'thermal_on'), eff = on(d, 'thermal_effective');
    dot('thermalDot', eff ? 'on' : want ? 'warn' : '');
    setVal('thermalOn', want);
    setText('thermalDesc', !want ? t('t_thermal_off') : eff ? t('t_thermal_on') : t('t_applying'));
  }

  function renderRate(d) {
    var onx = on(d, 'rate_on'), cur = num(d, 'rate_value'), tgt = num(d, 'rate_target');
    var avail = on(d, 'rate_avail'), paused = on(d, 'rate_paused'), ok = on(d, 'rate_ok');
    /* 回读值可能只是驱动缓存，真正生效要看 rate_ok（驱动确认过） */
    dot('rateDot', !avail ? 'warn' : onx ? (ok ? 'on' : 'warn') : '');
    setVal('rateOn', onx && avail);
    /* 上限留空 = 自动（硬件最高档 720Hz），所以空串要回填，不能保留旧值 */
    setVal('rateMax', d.rate_max || '');
    var s;
    if (!avail) s = t('t_disabled');
    else if (!onx) s = t('t_idle');
    else if (paused) s = t('t_rate_pause');
    else s = t('t_active') + (tgt ? ' · ' + tgt : '');
    setText('rateDesc', s);
    var e = $('rateCur');
    if (e) e.textContent = cur ? (cur + ' ' + t('t_rate_hz')) : '--';
    if (e) e.className = 'pill' + (onx && avail ? (ok ? ' ok' : ' warn') : '');
  }

  function renderPerf(d) {
    /* CPU / GPU：select 的选项由后端频率表生成，单位 MHz，0 = 不接管 */
    var lock = on(d, 'freq_lock');
    setVal('freqLock', lock);
    var spin = lock ? t('t_pinned') : '';

    fillSel('cpu0Sel', d.cpu0_list, d.cpu0_sel);
    fillSel('cpu1Sel', d.cpu1_list, d.cpu1_sel);
    fillSel('gpuSel', d.gpu_list, d.gpu_sel);

    var c0 = d.cpu0_sel || '0', c1 = d.cpu1_sel || '0', gv = d.gpu_sel || '0';
    var cok = on(d, 'cpu_ok'), gok = on(d, 'gpu_ok'), gp = on(d, 'gpu_paused');
    setText('cpu0Desc', freqText(c0, cok, spin, d.cpu0_cur));
    setText('cpu1Desc', freqText(c1, cok, spin, d.cpu1_cur));
    setText('gpuDesc', !gv || gv === '0' ? t('t_idle') :
      (gp ? t('t_gpu_pause') : (gok ? t('t_active') + ' · ' + gv + ' MHz' + spin : t('t_applying'))));

    dot('perfDot', ((c0 !== '0' || c1 !== '0') && cok) || (gv !== '0' && gok) ? 'on'
      : (c0 !== '0' || c1 !== '0' || gv !== '0') ? 'warn' : '');
  }

  function freqText(sel, ok, spin, cur) {
    if (!sel || sel === '0') return t('t_idle');
    if (ok) return t('t_active') + ' · ' + sel + ' MHz' + spin + (cur && cur !== sel ? ' (' + cur + ')' : '');
    return t('t_applying');
  }

  /* 频率下拉：选项来自后端频率表（逗号分隔 MHz），列表变了才重建 */
  function fillSel(id, list, sel) {
    var e = $(id);
    if (!e) return;
    var sig = String(list == null ? '' : list);
    if (e.getAttribute('data-sig') !== sig) {
      var parts = sig ? sig.split(',') : [];
      var html = '<option value="0">' + t('no_limit') + '</option>';
      for (var i = 0; i < parts.length; i++) {
        html += '<option value="' + parts[i] + '">' + parts[i] + ' MHz</option>';
      }
      e.innerHTML = html;
      e.setAttribute('data-sig', sig);
      e.disabled = parts.length === 0;
    }
    if (document.activeElement !== e) e.value = String(sel || '0');
  }

  function renderBright(d) {
    var avail = on(d, 'bright_available'), onx = on(d, 'bright_on');
    var cur = num(d, 'bright_cur'), mx = num(d, 'bright_max'), goal = num(d, 'bright_goal');
    dot('brightDot', !avail ? 'warn' : onx ? 'on' : '');
    setVal('brightOn', onx && avail);
    var s;
    if (!avail) s = t('t_disabled');
    else if (!onx) s = t('t_idle');
    else if (cur && goal) s = t('t_active') + ' · ' + cur + ' → ' + goal;
    else s = t('t_applying');
    setText('brightDesc', s);
    setVal('brightGoal', d.bright_goal_set || '');
    var info = 'max ' + (mx || '--');
    if (goal) info += ' · goal ' + goal;
    setText('brightInfo', info);
  }

  function renderBattery(d) {
    setText('sysBattery', (d.battery || '--') + t('pct'));
    setText('sysTemp', (d.temp_deg || '--') + t('deg'));
    var p = d.power;
    setText('sysPower', (p && p !== '0.0' ? p : '--') + ' ' + t('watt'));
    /* 皮肤温度：读不到就留 --；风扇/液冷联动取它与电池温度的较高者 */
    setText('bhSkin', (d.temp_skin !== '' && d.temp_skin != null) ? d.temp_skin + t('deg') : '--');
  }

  function init() {
    bindSwitch('fanOn', 'fan_on');
    bindSwitch('fanKeep', 'fan_keep');
    bindRange('fanLevel', 'fanLevelVal', 'fan_level', ' / 5');
    bindSeg('fanTempSeg', 'fan_temp', { thr: 'fanTempThrWrap' });
    bindRange('fanTempThr', 'fanTempThrVal', 'fan_temp_thr', ' ' + t('deg'));

    bindSwitch('pumpOn', 'pump_on');
    bindSwitch('pumpKeep', 'pump_keep');
    bindRange('pumpLevel', 'pumpLevelVal', 'pump_level', ' / 4');
    bindSeg('pumpTempSeg', 'pump_temp', { thr: 'pumpTempThrWrap' });
    bindRange('pumpTempThr', 'pumpTempThrVal', 'pump_temp_thr', ' ' + t('deg'));

    bindSwitch('chargeOn', 'charge_on');
    bindRange('chargeThr', 'chargeThrVal', 'charge_thr', ' ' + t('pct'));
    bindSwitch('boostOn', 'boost_on');
    bindRange('boostThr', 'boostThrVal', 'boost_thr', ' ' + t('deg'));
    bindSwitch('boostHeat', 'boost_heat');
    bindSwitch('fastOn', 'fast_on');

    bindSwitch('thermalOn', 'thermal_on');

    bindSwitch('rateOn', 'rate_on');
    bindNum('rateMax', 'rateApply', 'rate_max', 120, 720, null, '');

    bindSel('cpu0Sel', 'cpu_freq', '0');
    bindSel('cpu1Sel', 'cpu_freq', '1');
    bindSel('gpuSel', 'gpu_freq');
    bindSwitch('freqLock', 'freq_lock');

    bindSwitch('brightOn', 'bright_on');
    bindNum('brightGoal', 'brightApply', 'bright_goal', 1, 20000, null, '');
  }

  g.CARDS = {
    init: init,
    render: function (d) {
      if (!d) return;
      renderFan(d); renderPump(d); renderCharge(d);
      renderThermal(d); renderRate(d); renderPerf(d); renderBright(d); renderBattery(d);
    },
    bindSwitch: bindSwitch, bindRange: bindRange, bindSeg: bindSeg, bindNum: bindNum, bindSel: bindSel,
    toast: toast, toastErr: toastErr, cmd: cmd,
    $: $, setText: setText, setVal: setVal, show: show, dot: dot, num: num, on: on,
    paintSeg: paintSeg
  };
})(window);
