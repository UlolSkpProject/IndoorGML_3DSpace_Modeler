var icons = {
  pending: String.fromCodePoint(0x23F3),
  running: String.fromCodePoint(0x1F504),
  complete: String.fromCodePoint(0x2705),
  failed: String.fromCodePoint(0x274C)
};

var defaultSteps = [
  { key: 'temp_file', label: '\uC784\uC2DC\uD30C\uC77C \uC0DD\uC131' },
  { key: 'val3dity', label: 'val3dity \uC2E4\uD589 (version2.2.0)' },
  { key: 'extension_recheck', label: '2\uCC28 overlap recheck' },
  { key: 'report', label: 'report \uC0DD\uC131' },
  { key: 'report_view', label: 'report view \uC0DD\uC131' }
];

var validationSubsteps = [
  { key: 'xsd', label: 'XSD Validation' },
  { key: 'geometry', label: 'Geometry Primal Cells' },
  { key: 'xlinks', label: 'XLinks Errors' },
  { key: 'overlap', label: 'Overlap Primal Cells' },
  { key: 'dual_vertex', label: 'Dual Vertex Inside Cells' },
  { key: 'adjacency', label: 'Adjacency in Primal / Dual' }
];

var terminalResultShown = false;

function init(steps) {
  terminalResultShown = false;
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

    var content = document.createElement('span');
    content.className = 'step-content';
    content.appendChild(label);

    if (step.key === 'val3dity') {
      content.appendChild(createValidationSubsteps());
    }

    row.appendChild(icon);
    row.appendChild(content);
    list.appendChild(row);
  });
  fitDialogToContent();
}

function createValidationSubsteps() {
  var list = document.createElement('ul');
  list.id = 'val3dity-substeps';
  list.className = 'substeps';

  validationSubsteps.forEach(function (substep) {
    var row = document.createElement('li');
    row.id = 'substep-' + substep.key;
    row.className = 'pending';

    var icon = document.createElement('span');
    icon.className = 'sub-icon';
    icon.textContent = icons.pending;

    var label = document.createElement('span');
    label.className = 'sub-label';
    label.textContent = substep.label;

    row.appendChild(icon);
    row.appendChild(label);
    list.appendChild(row);
  });

  return list;
}

function setStatus(step, status) {
  var row = document.getElementById('step-' + step);
  if (!row) return;
  row.className = status;
  row.querySelector('.icon').textContent = icons[status] || icons.pending;
  updateValidationSubstepsForStatus(step, status);
  updateCancelVisibility();
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

  if (payload.step === 'val3dity') {
    updateValidationSubsteps(payload.phase);
  }

  updateCancelVisibility();
  fitDialogToContent();
}

function updateValidationSubstepsForStatus(step, status) {
  if (step !== 'val3dity') return;

  if (status === 'pending') {
    setAllValidationSubsteps('pending');
  } else if (status === 'running') {
    updateValidationSubsteps('XSD Validation');
  } else if (status === 'complete') {
    setAllValidationSubsteps('complete');
  } else if (status === 'failed') {
    markCurrentValidationSubstepFailed();
  }
}

function setAllValidationSubsteps(status) {
  validationSubsteps.forEach(function (substep) {
    setValidationSubstepStatus(substep.key, status);
  });
}

function updateValidationSubsteps(phase) {
  if (normalizePhase(phase) === 'Finished') {
    setAllValidationSubsteps('complete');
    return;
  }

  var index = validationSubstepIndex(phase);
  if (index < 0) return;

  validationSubsteps.forEach(function (substep, substepIndex) {
    if (substepIndex < index) {
      setValidationSubstepStatus(substep.key, 'complete');
    } else if (substepIndex === index) {
      setValidationSubstepStatus(substep.key, 'running');
    } else {
      setValidationSubstepStatus(substep.key, 'pending');
    }
  });
}

function markCurrentValidationSubstepFailed() {
  var running = document.querySelector('#val3dity-substeps li.running');
  if (!running) return;
  running.className = 'failed';
  running.querySelector('.sub-icon').textContent = icons.failed;
}

function setValidationSubstepStatus(key, status) {
  var row = document.getElementById('substep-' + key);
  if (!row) return;
  row.className = status;
  row.querySelector('.sub-icon').textContent = icons[status] || icons.pending;
}

function validationSubstepIndex(phase) {
  var normalized = normalizePhase(phase);
  if (!normalized) return -1;

  for (var i = 0; i < validationSubsteps.length; i += 1) {
    if (normalized.indexOf(validationSubsteps[i].label) === 0) {
      return i;
    }
  }

  return -1;
}

function normalizePhase(phase) {
  if (!phase) return '';
  return String(phase)
    .replace(/^\d+\.\s*/, '')
    .replace(/\s*\(\d+\s*\/\s*\d+\)\s*$/, '')
    .trim();
}

var actionConfig = {
  createGml: { label: 'Create GML file', callback: 'createGml' },
  openReport: { label: 'Open report', callback: 'openReport' },
  close: { label: 'Close', callback: 'closeDialog' }
};

function setResult(payload) {
  terminalResultShown = true;
  updateCancelVisibility();

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

function updateCancelVisibility() {
  var button = document.getElementById('cancel-validation');
  if (!button) return;

  var running = document.querySelector('#steps > li.running');
  button.disabled = terminalResultShown || !running;
  button.style.display = terminalResultShown || !running ? 'none' : 'inline-flex';
}

window.addEventListener('load', function () {
  sketchup.domReady();
  fitDialogToContent();
});
window.addEventListener('DOMContentLoaded', function () {
  init(defaultSteps);
  updateCancelVisibility();
  document.getElementById('cancel-validation').addEventListener('click', function () {
    if (typeof sketchup !== 'undefined' && sketchup.cancelValidation) {
      sketchup.cancelValidation();
    }
  });
});
window.addEventListener('resize', fitDialogToContent);
