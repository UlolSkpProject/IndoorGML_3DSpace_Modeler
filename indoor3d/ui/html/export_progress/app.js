var icons = {
  pending: String.fromCodePoint(0x23F3),
  running: String.fromCodePoint(0x1F504),
  complete: String.fromCodePoint(0x2705),
  failed: String.fromCodePoint(0x274C)
};

var defaultSteps = [
  { key: 'temp_file', label: '\uC784\uC2DC\uD30C\uC77C \uC0DD\uC131' },
  { key: 'val3dity', label: 'val3dity \uC2E4\uD589 (version2.2.0)' },
  { key: 'report', label: 'report \uC0DD\uC131' },
  { key: 'report_view', label: 'report view \uC0DD\uC131' }
];

function init(steps) {
  var list = document.getElementById('steps');
  list.innerHTML = '';
  steps.forEach(function (step) {
    var row = document.createElement('li');
    row.id = 'step-' + step.key;
    row.className = 'pending';

    var icon = document.createElement('span');
    icon.className = 'icon';
    icon.textContent = icons.pending;

    var label = document.createElement('span');
    label.className = 'label';
    label.textContent = step.label;

    row.appendChild(icon);
    row.appendChild(label);
    list.appendChild(row);
  });
  fitDialogToContent();
}

function setStatus(step, status) {
  var row = document.getElementById('step-' + step);
  if (!row) return;
  row.className = status;
  row.querySelector('.icon').textContent = icons[status] || icons.pending;
  fitDialogToContent();
}

function setDetail(payload) {
  var detail = document.getElementById('detail');
  if (!detail) return;

  detail.className = 'detail';

  var percent = payload.percent;
  if (percent === null || percent === undefined) percent = 0;
  percent = Math.max(0, Math.min(100, percent));

  document.getElementById('detail-phase').textContent =
    payload.phase || 'Running val3dity';

  document.getElementById('detail-percent').textContent =
    percent + '%';

  document.getElementById('detail-bar').style.width =
    percent + '%';

  document.getElementById('detail-message').textContent =
    payload.message || '';

  document.getElementById('detail-current').textContent =
    payload.current ? ('Current: ' + payload.current) : '';
  fitDialogToContent();
}

var actionConfig = {
  createGml: { label: 'Create GML file', callback: 'createGml' },
  openReport: { label: 'Open report', callback: 'openReport' },
  close: { label: 'Close', callback: 'closeDialog' }
};

function setResult(payload) {
  var result = document.getElementById('result');
  if (!result) return;

  result.className = 'result ' + (payload.status || 'neutral');
  document.getElementById('result-title').textContent = payload.title || '';
  setResultMessage(payload.message || '');

  var actions = document.getElementById('result-actions');
  actions.innerHTML = '';

  (payload.actions || []).forEach(function (actionName) {
    var config = actionConfig[actionName];
    if (!config) return;

    var button = document.createElement('button');
    button.type = 'button';
    button.textContent = config.label;
    button.addEventListener('click', function () {
      if (typeof sketchup !== 'undefined' && sketchup[config.callback]) {
        sketchup[config.callback]();
      }
    });
    actions.appendChild(button);
  });
  fitDialogToContent();
}

function setResultMessage(message) {
  var messageElement = document.getElementById('result-message');
  if (!messageElement) return;

  messageElement.textContent = message || '';
  fitDialogToContent();
}

function fitDialogToContent() {
  window.setTimeout(function () {
    if (typeof sketchup === 'undefined' || !sketchup.fitContentHeight) return;

    sketchup.fitContentHeight(document.body.scrollHeight);
  }, 0);
}

window.addEventListener('load', function () {
  sketchup.domReady();
  fitDialogToContent();
});
window.addEventListener('DOMContentLoaded', function () {
  init(defaultSteps);
});
window.addEventListener('resize', fitDialogToContent);
