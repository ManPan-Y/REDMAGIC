/* REDMAGIC v3.3.0 —— 触控页：10 项档位下拉 + 5 项自定义数值（只收整数）
   数据流是单向的：
     快照 touch_vals（英文短名=值;…）→ 回填表单（dirty 时跳过）→ 用户改 → dirty=1
     → 抖动 600ms 自动保存（也保留「应用」按钮）：逐项发 touch_param 存记忆，再发
       touch_apply 写节点 → dirty=0。后端看门狗每 15s 自动核对节点与记忆。
   自定义项按驱动实测范围校验：像素 0–255，时间 0–10000 ms，长按范围 4 个 0–255。 */
(function (g) {
  'use strict';
  var t = g.t;
  var C = null;   // CARDS，init 之后再取

  /* 与 lib/touch_table.txt 顺序严格一致；key 与后端 touch_key() 映射一致 */
  /* opts=下拉档位，bin=1 显示「关/开」；num=[min,max] 走数字输入；
     list=N 表示 N 个 0..max 的逗号列表。范围来自 NX809J 驱动实写回读：
     jitter_pixel / click_pixel 是 u8，两个 timer 至少接受 60000 ms。 */
  var ITEMS = [
    { key: 'follow',     cn: '跟手速度',   opts: ['0', '1', '2', '3', '4'] },
    { key: 'stability',  cn: '稳定程度',   opts: ['0', '1', '2', '3', '4'] },
    { key: 'sensibility',cn: '灵敏程度',   opts: ['0', '1', '2', '3', '4'] },
    { key: 'report',     cn: '上报频率',   opts: ['0', '1', '2', '3', '4'] },
    { key: 'edge_deb',   cn: '边缘防抖',   opts: ['0', '1'], bin: 1 },
    { key: 'edge_px',    cn: '防抖像素',   num: [0, 255], tip: 'tip_px' },
    { key: 'edge_ms',    cn: '防抖时间',   num: [0, 10000], tip: 'tip_ms' },
    { key: 'click_tol',  cn: '点击容错',   num: [0, 255], tip: 'tip_px' },
    { key: 'long_on',    cn: '长按识别',   opts: ['0', '1'], bin: 1 },
    { key: 'long_ms',    cn: '长按时长',   num: [0, 10000], tip: 'tip_ms' },
    { key: 'long_range', cn: '长按范围',   list: 4, max: 255, tip: 'tip_range4' },
    { key: 'edge_anti',  cn: '边缘防误触', opts: ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10'] },
    { key: 'edge_grip',  cn: '握持防误触', opts: ['0', '1', '2', '3'] },
    { key: 'palm',       cn: '手掌抑制',   opts: ['0', '1'], bin: 1 },
    { key: 'pen',        cn: '手写笔模式', opts: ['0', '1'], bin: 1 }
  ];

  var PRESETS = {
    official_gaming: {
      follow: '4', stability: '0', sensibility: '4', report: '4',
      edge_deb: '0', edge_px: '0', edge_ms: '0', click_tol: '0',
      long_on: '0', long_ms: '0', long_range: '0,0,0,0', edge_anti: '0',
      edge_grip: '0', palm: '0', pen: '0'
    },
    official_daily: {
      follow: '2', stability: '2', sensibility: '2', report: '2',
      edge_deb: '1', edge_px: '10', edge_ms: '100', click_tol: '10',
      long_on: '1', long_ms: '500', long_range: '10,10,20,20', edge_anti: '5',
      edge_grip: '2', palm: '1', pen: '0'
    }
  };

  var dirty = false;
  var formBuilt = false;
  var curPreset = 'official_gaming';
  var naShown = '';
  var rbShown = '';

  function inputs() {
    var box = document.getElementById('touchForm');
    if (!box) return [];
    return box.querySelectorAll('select,input');
  }

  function itemOf(k) {
    for (var i = 0; i < ITEMS.length; i++) if (ITEMS[i].key === k) return ITEMS[i];
    return null;
  }

  function zeros(n) {
    var a = [];
    for (var i = 0; i < n; i++) a.push('0');
    return a.join(',');
  }

  function rangeText(it) {
    return it.num ? it.num[0] + '–' + it.num[1] : it.list + '×0–' + it.max;
  }

  /* 合法值原样返回（去空格、去前导零），非法返回 '' */
  function normVal(it, raw) {
    var s = String(raw == null ? '' : raw), v;
    if (it.list) {
      /* 逗号、中文逗号、空格都当分隔符；多打的逗号压掉 */
      v = s.replace(/\s+/g, ',').replace(/，/g, ',').replace(/,+/g, ',').replace(/^,|,$/g, '');
      if (!/^[0-9]+(,[0-9]+)*$/.test(v)) return '';
      var a = v.split(',');
      if (a.length !== it.list) return '';
      for (var i = 0; i < a.length; i++) {
        if (+a[i] > it.max) return '';
        a[i] = String(+a[i]);
      }
      return a.join(',');
    }
    v = s.replace(/\s+/g, '');
    if (!/^[0-9]+$/.test(v)) return '';
    if (+v < it.num[0] || +v > it.num[1]) return '';
    return String(+v);
  }

  function badToast(it) {
    C.toast(t('toast_range') + ' · ' + t('touch_item_' + ITEMS.indexOf(it)) + ' ' + rangeText(it), 'bad');
  }

  function build() {
    var box = document.getElementById('touchForm');
    if (!box || formBuilt) return;
    var html = '';
    for (var i = 0; i < ITEMS.length; i++) {
      var it = ITEMS[i], ctl;
      if (it.num || it.list) {
        ctl = '<div class="ctl"><input id="tp_' + it.key + '" data-k="' + it.key + '"' +
              (it.num
                ? ' type="number" inputmode="numeric" min="' + it.num[0] + '" max="' + it.num[1] + '" step="1"'
                : ' type="text" placeholder="' + zeros(it.list) + '"') +
              '><span class="tip" data-i18n="' + it.tip + '">' + t(it.tip) + '</span></div>';
      } else {
        var opt = '';
        for (var j = 0; j < it.opts.length; j++) {
          var v = it.opts[j], lb = v;
          if (it.bin) lb = v === '0' ? t('off_s') : t('on');
          opt += '<option value="' + v + '"' + (it.bin ? ' data-i18n="' + (v === '0' ? 'off_s' : 'on') + '"' : '') + '>' + lb + '</option>';
        }
        ctl = '<select id="tp_' + it.key + '" data-k="' + it.key + '">' + opt + '</select>';
      }
      html += '<div class="it"><label class="nm" for="tp_' + it.key + '">' + t('touch_item_' + i) + '</label>' + ctl + '</div>';
    }
    box.innerHTML = html;
    var is = inputs();
    for (var j = 0; j < is.length; j++) {
      var el = is[j];
      el.addEventListener(el.tagName === 'SELECT' ? 'change' : 'input', function () {
        dirty = true;
        markDirty();
        scheduleAutoSave();   // 自定义参数改完自动保存并写节点
        var it = itemOf(this.getAttribute('data-k'));
        if (!it || (!it.num && !it.list)) return;
        var ok = this.value === '' || normVal(it, this.value) !== '';
        this.classList.toggle('bad', !ok);
      });
      if (el.tagName !== 'SELECT') {
        /* 失焦就提示一次，不用等点「应用」才发现填错 */
        el.addEventListener('change', function () {
          var it = itemOf(this.getAttribute('data-k'));
          if (it && this.value !== '' && normVal(it, this.value) === '') badToast(it);
        });
      }
    }
    formBuilt = true;
  }

  function markDirty() {
    C.show('touchDirty', dirty);
  }

  function readForm() {
    var o = {}, is = inputs();
    for (var i = 0; i < is.length; i++) {
      var el = is[i], it = itemOf(el.getAttribute('data-k')), v;
      if (el.disabled) continue;   // 驱动不支持的项不提交
      if (it && (it.num || it.list)) {
        if (String(el.value).replace(/\s+/g, '') === '') {
          el.classList.add('bad');
          el.focus();
          C.toast(t('toast_empty') + ' · ' + t('touch_item_' + ITEMS.indexOf(it)), 'bad');
          return null;
        }
        v = normVal(it, el.value);
        if (v === '') {
          el.classList.add('bad');
          el.focus();
          badToast(it);
          return null;
        }
        el.classList.remove('bad');
        el.value = v;
      } else {
        v = String(el.value).replace(/\s+/g, '').replace(/，/g, ',');
        if (v === '' || !/^[0-9]+(,[0-9]+)*$/.test(v)) {
          C.toast(t('toast_bad'), 'bad');
          return null;
        }
      }
      o[el.getAttribute('data-k')] = v;
    }
    return o;
  }

  function fill(vals) {
    var is = inputs();
    for (var i = 0; i < is.length; i++) {
      var k = is[i].getAttribute('data-k');
      if (!vals || vals[k] == null || document.activeElement === is[i]) continue;
      var v = String(vals[k]), has = false;
      if (is[i].tagName === 'SELECT') {
        for (var j = 0; j < is[i].options.length; j++) {
          if (is[i].options[j].value === v) { has = true; break; }
        }
        if (!has) {
          var o = document.createElement('option');
          o.value = v;
          o.textContent = v;
          is[i].appendChild(o);
        }
      }
      is[i].value = v;
      is[i].classList.remove('bad');
    }
  }

  function parseVals(s) {
    var o = {};
    if (!s) return o;
    var parts = String(s).split(';');
    for (var i = 0; i < parts.length; i++) {
      var e = parts[i].indexOf('=');
      if (e > 0) o[parts[i].slice(0, e)] = parts[i].slice(e + 1);
    }
    return o;
  }

  function applyPreset(name) {
    var p = PRESETS[name];
    if (!p) return;
    fill(p);
    curPreset = name;
    dirty = true;
    markDirty();
  }

  function presetOf(vals) {
    for (var name in PRESETS) {
      if (!PRESETS.hasOwnProperty(name)) continue;
      var p = PRESETS[name], same = true;
      for (var k in p) {
        if (!p.hasOwnProperty(k)) continue;
        if ((vals[k] || '') !== p[k]) { same = false; break; }
      }
      if (same) return name;
    }
    return '';
  }

  /* 逐项发命令；全部发完才发 touch_apply 写节点。
     silent=1 是自动保存路径：只弹「已保存」，不弹「已应用」。 */
  function applyAll(silent) {
    var vals = readForm();
    /* readForm 已为具体项弹过「超出范围/未填写」，这里再弹会把它盖掉 */
    if (!vals) return;
    var keys = [];
    for (var k in vals) if (vals.hasOwnProperty(k)) keys.push(k);
    var i = 0, chain = Promise.resolve();
    keys.forEach(function (k) {
      var cn = '';
      for (var j = 0; j < ITEMS.length; j++) if (ITEMS[j].key === k) cn = ITEMS[j].cn;
      var kv = cn ? (cn + '=' + vals[k]) : '';
      if (!kv) return;
      chain = chain.then(function () { return g.API.send('touch_param', kv); });
      i++;
    });
    if (i === 0) { if (!silent) C.toast(t('toast_na_all'), 'bad'); return; }
    chain.then(function () {
      return g.API.send('touch_apply', '');
    }).then(function () {
      dirty = false;
      markDirty();
      C.toast(t(silent ? 'toast_saved' : 'toast_applied'), 'ok');
      g.API.refreshSoon();
    }, function (e) {
      if (!silent) C.toastErr(e);
      g.API.refreshSoon();
    });
  }

  /* 表单是否全部填对：自动保存时用它静默判断，避免半截输入时弹提示、抢焦点 */
  function formOk() {
    var is = inputs();
    for (var i = 0; i < is.length; i++) {
      var el = is[i];
      if (el.disabled) continue;
      var it = itemOf(el.getAttribute('data-k'));
      if (!it) continue;
      if (it.num || it.list) {
        if (String(el.value).replace(/\s+/g, '') === '' || normVal(it, el.value) === '') return false;
      } else if (!/^[0-9]+$/.test(String(el.value).replace(/\s+/g, ''))) {
        return false;
      }
    }
    return true;
  }

  /* 改完就自动存：抖动 600ms 后发参数 + 应用，不用再点按钮 */
  var autoTimer = null;
  function scheduleAutoSave() {
    if (autoTimer) clearTimeout(autoTimer);
    autoTimer = setTimeout(function () {
      autoTimer = null;
      if (!dirty || !formOk()) return;   // 输入未完成/越界：保持 dirty，等继续改
      applyAll(true);
    }, 600);
  }

  /* 「还原」= 回到当前生效值（快照里的 touch_vals），不是回到出厂 */
  function revert() {
    var d = g.API.data();
    if (d) fill(parseVals(d.touch_vals));
    var p = presetOf(parseVals(d ? d.touch_vals : ''));
    if (p) curPreset = p;
    C.paintSeg('touchPresetSeg', p || curPreset);
    dirty = false;
    markDirty();
  }

  function rowOf(el) {
    var p = el;
    while (p && p.classList && !p.classList.contains('it')) p = p.parentNode;
    return p && p.classList ? p : null;
  }

  /* touch_na：节点连原始值都读不出，这项不写也不校验，界面置灰说明原因
     touch_owned：节点被别的功能（采样率）接管，同样置灰，但提示文案必须区分，
     否则会误报成「驱动不支持」 */
  function paintNA(s, owned) {
    var names = String(s || '').split(','), owns = String(owned || '').split(','), sig = '';
    for (var i = 0; i < ITEMS.length; i++) {
      var it = ITEMS[i], el = document.getElementById('tp_' + it.key);
      if (!el) continue;
      var off = names.indexOf(it.cn) >= 0;
      var own = owns.indexOf(it.cn) >= 0;
      if (off) sig += (sig ? '、' : '') + it.cn;
      el.disabled = off || own;
      var row = rowOf(el);
      if (row) row.classList.toggle('na', off || own);
      var ctl = el.parentNode;
      var tip = ctl && ctl.querySelector ? ctl.querySelector('.tip') : null;
      if (tip) tip.textContent = off ? t('touch_na')
        : own ? t('touch_owned')
        : (it.tip ? t(it.tip) : '');
    }
    if (!sig || sig === naShown) return '';
    naShown = sig;
    return t('toast_na') + ' ' + sig;
  }

  /* touch_rb：上次应用被驱动退回的项，弹一次让用户知道「已保存」不等于「已生效」 */
  function paintRB(s) {
    if (!s || s === rbShown) return '';
    rbShown = s;
    var a = String(s).split(';'), out = [];
    for (var i = 0; i < a.length && out.length < 2; i++) {
      var p = a[i].indexOf('=');
      if (p <= 0) continue;
      var name = a[i].slice(0, p), rest = a[i].slice(p + 1), g = rest.indexOf('>');
      out.push(g >= 0 ? name + ' ' + rest.slice(0, g) + ' → ' + rest.slice(g + 1) : name + ' ' + rest);
    }
    return out.length ? t('toast_rollback') + ' ' + out.join('，') : '';
  }

  function render(d) {
    if (!formBuilt) return;
    var on = d.touch_on === '1';
    /* 关掉触控时把置灰还原，避免还原失败时表单长期半灰 */
    var msgs = [paintNA(on ? d.touch_na : '', on ? d.touch_owned : '')], m2 = on ? paintRB(d.touch_rb) : '';
    if (m2) msgs.push(m2);
    msgs = msgs.filter(function (x) { return x; });
    if (msgs.length) C.toast(msgs.join('；'), 'bad');
    var miss = parseInt(d.touch_missing, 10) || 0;
    var avail = miss === 0;
    C.dot('touchDot', !avail ? 'warn' : on ? 'on' : '');
    C.setVal('touchOn', on);

    var s;
    if (!avail) s = t('t_disabled') + ' · ' + miss + '/5';
    else if (!on) s = t('t_idle');
    else if (d.touch_mode === 'preset') s = t('t_touch_ok');
    else s = t('t_touch_custom');
    C.setText('touchStateDesc', s);

    if (!dirty) {
      var vals = parseVals(d.touch_vals);
      fill(vals);
      var p = presetOf(vals);
      if (p) curPreset = p;
      C.paintSeg('touchPresetSeg', p || '');
    }
  }

  function init() {
    C = g.CARDS;
    build();
    markDirty();
    C.bindSwitch('touchOn', 'touch_on');
    document.getElementById('touchPresetSeg').addEventListener('click', function (ev) {
      var b = ev.target;
      var box = document.getElementById('touchPresetSeg');
      while (b && b !== box && b.tagName !== 'BUTTON') b = b.parentNode;
      if (!b || b === box) return;
      var v = b.getAttribute('data-v');
      if (!v) return;
      applyPreset(v);
      C.paintSeg('touchPresetSeg', v);
      C.toast(t('toast_saved'), 'ok');
      scheduleAutoSave();
    });
    document.getElementById('touchApply').addEventListener('click', function () { applyAll(false); });
    document.getElementById('touchReset').addEventListener('click', revert);
  }

  g.TOUCH = { init: init, render: render };
})(window);
