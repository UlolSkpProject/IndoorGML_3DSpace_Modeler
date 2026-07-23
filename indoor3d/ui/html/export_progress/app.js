var icons = {
  pending: '\u25CB',
  running: '\u25CF',
  complete: '\u2713',
  failed: '\u00D7'
};

var defaultSteps = [
  { key: 'temp_file', label: '\uC784\uC2DC\uD30C\uC77C \uC0DD\uC131' },
  { key: 'val3dity', label: 'val3dity \uC2E4\uD589 (version2.2.0)' },
  { key: 'extension_recheck', label: '2\uCC28 overlap recheck' },
  { key: 'report', label: 'Report \uC0DD\uC131' }
];

var validationSubsteps = [
  { key: 'xsd', label: 'XSD Validation' },
  { key: 'geometry', label: 'Geometry Primal Cells' },
  { key: 'xlinks', label: 'XLinks Errors' },
  { key: 'overlap', label: 'Overlap Primal Cells' },
  { key: 'dual_vertex', label: 'Dual Vertex Inside Cells' },
  { key: 'adjacency', label: 'Adjacency in Primal / Dual' }
];

var extensionRecheckSubsteps = [
  { key: 'collect', label: 'Collect 701/704 errors' },
  { key: 'pairs', label: 'Recheck reported cell pairs' },
  { key: 'policy', label: 'Apply extension policy' }
];

var substepGroups = {
  val3dity: validationSubsteps,
  extension_recheck: extensionRecheckSubsteps
};

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

    if (substepGroups[step.key]) {
      content.appendChild(createSubsteps(step.key));
    }

    row.appendChild(icon);
    row.appendChild(content);
    list.appendChild(row);
  });
  fitDialogToContent();
}

function createSubsteps(stepKey) {
  var list = document.createElement('ul');
  list.id = stepKey + '-substeps';
  list.className = 'substeps';

  substepGroups[stepKey].forEach(function (substep) {
    var row = document.createElement('li');
    row.id = 'substep-' + stepKey + '-' + substep.key;
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
  updateSubstepsForStatus(step, status);
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

  if (substepGroups[payload.step]) {
    updateSubsteps(payload.step, payload.phase);
  }

  updateCancelVisibility();
  fitDialogToContent();
}

function updateSubstepsForStatus(step, status) {
  if (!substepGroups[step]) return;

  if (status === 'pending') {
    setAllSubsteps(step, 'pending');
  } else if (status === 'running') {
    updateSubsteps(step, substepGroups[step][0].label);
  } else if (status === 'complete') {
    setAllSubsteps(step, 'complete');
  } else if (status === 'failed') {
    markCurrentSubstepFailed(step);
  }
}

function setAllSubsteps(step, status) {
  substepGroups[step].forEach(function (substep) {
    setSubstepStatus(step, substep.key, status);
  });
}

function updateSubsteps(step, phase) {
  if (normalizePhase(phase) === 'Finished') {
    setAllSubsteps(step, 'complete');
    return;
  }

  var index = substepIndex(step, phase);
  if (index < 0) return;

  substepGroups[step].forEach(function (substep, substepIndex) {
    if (substepIndex < index) {
      setSubstepStatus(step, substep.key, 'complete');
    } else if (substepIndex === index) {
      setSubstepStatus(step, substep.key, 'running');
    } else {
      setSubstepStatus(step, substep.key, 'pending');
    }
  });
}

function markCurrentSubstepFailed(step) {
  var running = document.querySelector('#' + step + '-substeps li.running');
  if (!running) return;
  running.className = 'failed';
  running.querySelector('.sub-icon').textContent = icons.failed;
}

function setSubstepStatus(step, key, status) {
  var row = document.getElementById('substep-' + step + '-' + key);
  if (!row) return;
  row.className = status;
  row.querySelector('.sub-icon').textContent = icons[status] || icons.pending;
}

function substepIndex(step, phase) {
  var normalized = normalizePhase(phase);
  if (!normalized) return -1;

  for (var i = 0; i < substepGroups[step].length; i += 1) {
    if (normalized.indexOf(substepGroups[step][i].label) === 0) {
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
document.addEventListener('dragstart', function (event) {
  if (!event.target.closest('.result-title, .result-message')) {
    event.preventDefault();
  }
});
document.addEventListener('keydown', function (event) {
  if ((event.ctrlKey || event.metaKey) && String(event.key).toLowerCase() === 'a') {
    event.preventDefault();
    event.stopPropagation();
  }
}, true);
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
