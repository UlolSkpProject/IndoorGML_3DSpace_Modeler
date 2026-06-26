// ────────────────────────────────────────────────────────────────
// DOM references
// ────────────────────────────────────────────────────────────────
var emptyPanel = document.getElementById('emptyPanel');
var solidPanel = document.getElementById('solidPanel');
var cellPanel = document.getElementById('cellPanel');
var cellTop = document.getElementById('cellTop');

var modeTitle = document.getElementById('modeTitle');
var finishButton = document.getElementById('finish');
var clearAllButton = document.getElementById('clearAll');
var recheckErrorsButton = document.getElementById('recheckErrors');

var solidCount = document.getElementById('solidCount');
var solidClassification = document.getElementById('solidClassification');
var convertSelectedButton = document.getElementById('convertSelected');

var singleCellInfo = document.getElementById('singleCellInfo');
var multiCellInfo = document.getElementById('multiCellInfo');
var selectedId = document.getElementById('selectedId');
var selectedName = document.getElementById('selectedName');
var transitionCount = document.getElementById('transitionCount');
var cellSpaceCount = document.getElementById('cellSpaceCount');

var storeyFields = document.getElementById('storeyFields');
var storeyFromKind = document.getElementById('storeyFromKind');
var storeyFromLevel = document.getElementById('storeyFromLevel');
var storeyToKind = document.getElementById('storeyToKind');
var storeyToLevel = document.getElementById('storeyToLevel');

var navigationSemantics = document.getElementById('navigationSemantics');
var navigationClass = document.getElementById('navigationClass');
var navigationFunction = document.getElementById('navigationFunction');
var navigationUsage = document.getElementById('navigationUsage');

var selectedClassification = document.getElementById('selectedClassification');
var changeTypeButton = document.getElementById('changeType');

var cellTypeCounts = document.getElementById('cellTypeCounts');
var stateCount = document.getElementById('stateCount');
var totalTransitionCount = document.getElementById('totalTransitionCount');

var currentMode = null;
var currentSelectionKey = null;
var fixMode = false;

// ────────────────────────────────────────────────────────────────
// SketchUp bridge helpers
// ────────────────────────────────────────────────────────────────
function invokeSketchup(methodName, args) {
  if (!window.sketchup || typeof window.sketchup[methodName] !== 'function') {
    return;
  }

  window.sketchup[methodName].apply(window.sketchup, args || []);
}

function fitDialogToContent() {
  window.requestAnimationFrame(function () {
    invokeSketchup('fitContentHeight', [document.body.scrollHeight]);
  });
}

// ────────────────────────────────────────────────────────────────
// Generic UI helpers
// ────────────────────────────────────────────────────────────────
function show(element) {
  if (element) element.classList.remove('hidden');
}

function hide(element) {
  if (element) element.classList.add('hidden');
}

function setVisible(element, visible) {
  if (visible) {
    show(element);
  } else {
    hide(element);
  }
}

function setControlLocked(controls, locked) {
  var disabled = Boolean(locked);

  controls.forEach(function (control) {
    if (control) control.disabled = disabled;
  });
}

function fillOptions(select, options) {
  select.innerHTML = '';

  (options || []).forEach(function (option) {
    var element = document.createElement('option');
    element.value = option.value;
    element.textContent = option.label;
    select.appendChild(element);
  });
}

function setIcon(id, assetRoot, filename) {
  var image = document.getElementById(id);
  if (!image || !assetRoot) return;

  var normalizedRoot = String(assetRoot).replace(/\\/g, '/');
  image.src = encodeURI('file:///' + normalizedRoot + '/assets/icons/' + filename);
}

function applyOverlayColors(colors) {
  if (!colors) return;

  document.documentElement.style.setProperty('--overlay-state-color', colors.state || '');
  document.documentElement.style.setProperty('--overlay-state-soft-color', colors.stateSoft || '');
}

// ────────────────────────────────────────────────────────────────
// Storey parsing and composition
// ────────────────────────────────────────────────────────────────
function clampStoreyLevel(input) {
  var value = parseInt(input.value, 10);

  if (isNaN(value) || value < 1) value = 1;
  if (value > 99) value = 99;

  input.value = value;
}

function padLevel(value) {
  var text = String(value);
  return text.length < 2 ? '0' + text : text;
}

function parseStoreyPart(value) {
  var match = String(value || 'F01').toUpperCase().match(/^([FB])(\d{1,2})$/);

  if (!match) {
    return { kind: 'F', level: 1 };
  }

  return {
    kind: match[1],
    level: Math.max(1, Math.min(99, Number(match[2]) || 1))
  };
}

function parseStorey(value) {
  var parts = String(value || 'F01').split('~');
  var from = parseStoreyPart(parts[0]);
  var to = parseStoreyPart(parts[1] || parts[0]);

  return { from: from, to: to };
}

function composeStorey() {
  clampStoreyLevel(storeyFromLevel);
  clampStoreyLevel(storeyToLevel);

  var from = storeyFromKind.value + padLevel(storeyFromLevel.value);
  var to = storeyToKind.value + padLevel(storeyToLevel.value);

  return from === to ? from : from + '~' + to;
}

function setStorey(value) {
  var parsed = parseStorey(value);

  storeyFromKind.value = parsed.from.kind;
  storeyFromLevel.value = parsed.from.level;
  storeyToKind.value = parsed.to.kind;
  storeyToLevel.value = parsed.to.level;
  show(storeyFields);
}

// ────────────────────────────────────────────────────────────────
// Initialization called from Ruby
// ────────────────────────────────────────────────────────────────
function init(config) {
  config = config || {};
  fixMode = Boolean(config.fixMode);

  modeTitle.textContent = fixMode ? '수정 모드' : '편집 모드';
  finishButton.textContent = fixMode ? '수정 완료' : '편집 완료';

  fillOptions(selectedClassification, config.classificationOptions);
  fillOptions(solidClassification, config.classificationOptions);

  setIcon('convertIcon', config.assetRoot, 'create_cellspace.svg');
  setIcon('changeTypeIcon', config.assetRoot, 'change_cellspace_type.svg');
  applyOverlayColors(config.overlayColors);

  setVisible(recheckErrorsButton, fixMode);
  updateSelection(null);
  fitDialogToContent();
}

// ────────────────────────────────────────────────────────────────
// Selection rendering called from Ruby
// ────────────────────────────────────────────────────────────────
function updateSelection(snapshot) {
  var nextMode = snapshot && snapshot.mode ? snapshot.mode : 'empty';
  var nextKey = selectionKey(snapshot);

  if (nextKey === currentSelectionKey) {
    return false;
  }

  setVisible(emptyPanel, nextMode === 'empty');
  setVisible(solidPanel, nextMode === 'solid_groups');
  setVisible(cellPanel, nextMode === 'cell_space' || nextMode === 'cell_spaces');
  setVisible(clearAllButton, !fixMode && nextMode === 'empty');
  setVisible(recheckErrorsButton, fixMode);

  if (nextMode === 'solid_groups') {
    renderSolidGroups(snapshot || {});
  } else if (nextMode === 'cell_spaces') {
    renderCellSpaces(snapshot || {});
  } else if (nextMode === 'cell_space') {
    renderCellSpace(snapshot || {});
  } else {
    renderEmpty(snapshot || {});
  }

  currentMode = nextMode;
  currentSelectionKey = nextKey;
  return true;
}

function updateSelectionAndFit(snapshot) {
  if (updateSelection(snapshot)) {
    fitDialogToContent();
  }
}

function selectionKey(snapshot) {
  if (!snapshot || !snapshot.mode) return 'empty';

  return [
    snapshot.mode,
    snapshot.id || '',
    snapshot.name || '',
    snapshot.classification || '',
    snapshot.classificationLocked ? 'locked' : 'unlocked',
    snapshot.storey || '',
    snapshot.navigationSemanticsEnabled ? 'navi' : 'core',
    snapshot.navigationClass || '',
    snapshot.navigationFunction || '',
    snapshot.navigationUsage || '',
    snapshot.transitionCount || 0,
    snapshot.cellSpaceCount || 0,
    snapshot.solidGroupCount || 0,
    snapshot.stateCount || 0,
    snapshot.totalTransitionCount || 0,
    cellTypeCountKey(snapshot.cellTypeCounts)
  ].join('|');
}

function cellTypeCountKey(counts) {
  if (!counts || !counts.length) return '';

  return counts.map(function (entry) {
    return [entry.label || '', entry.count || 0].join(':');
  }).join(',');
}

function renderEmpty(snapshot) {
  cellTypeCounts.innerHTML = '';

  (snapshot.cellTypeCounts || []).forEach(function (entry) {
    var row = document.createElement('div');
    var label = document.createElement('span');
    var count = document.createElement('strong');

    row.className = 'type-count-row';
    label.textContent = entry.label || '-';
    count.textContent = entry.count || 0;

    row.appendChild(label);
    row.appendChild(count);
    cellTypeCounts.appendChild(row);
  });

  stateCount.textContent = snapshot.stateCount || 0;
  totalTransitionCount.textContent = snapshot.totalTransitionCount || 0;
}

function renderSolidGroups(snapshot) {
  solidCount.textContent = snapshot.solidGroupCount || 0;
  solidClassification.value = snapshot.classification || 'GeneralSpace|Room';

  setControlLocked(
    [solidClassification, convertSelectedButton],
    snapshot.classificationLocked
  );
}

function renderCellSpaces(snapshot) {
  hide(singleCellInfo);
  show(multiCellInfo);
  hide(storeyFields);
  setNavigationSemantics(null, false);

  cellSpaceCount.textContent = snapshot.cellSpaceCount || 0;
  selectedClassification.value = snapshot.classification || 'GeneralSpace|Room';

  setControlLocked(
    [selectedClassification, changeTypeButton],
    snapshot.classificationLocked
  );
}

function renderCellSpace(snapshot) {
  show(singleCellInfo);
  hide(multiCellInfo);

  selectedId.textContent = snapshot.id || '-';
  selectedName.textContent = snapshot.name || '-';
  transitionCount.textContent = snapshot.transitionCount || 0;
  selectedClassification.value = snapshot.classification || 'GeneralSpace|Room';

  setStorey(snapshot.storey || 'F01');
  setNavigationSemantics(snapshot, Boolean(snapshot.navigationSemanticsEnabled));

  setControlLocked(
    [selectedClassification, changeTypeButton],
    snapshot.classificationLocked
  );
}

function setNavigationSemantics(snapshot, enabled) {
  setVisible(navigationSemantics, enabled);
  cellTop.classList.toggle('single-column', !enabled);

  if (!enabled) {
    navigationClass.value = '';
    navigationFunction.value = '';
    navigationUsage.value = '';
    return;
  }

  navigationClass.value = snapshot.navigationClass || '';
  navigationFunction.value = snapshot.navigationFunction || '';
  navigationUsage.value = snapshot.navigationUsage || '';
}

// ────────────────────────────────────────────────────────────────
// Commit helpers
// ────────────────────────────────────────────────────────────────
function commitStorey() {
  invokeSketchup('setSelectedCellSpaceStorey', [composeStorey()]);
}

function commitNavigationSemantics() {
  invokeSketchup('setSelectedCellSpaceNavigationSemantics', [
    navigationClass.value,
    navigationFunction.value,
    navigationUsage.value
  ]);
}

function onStoreyLevelChange(input) {
  clampStoreyLevel(input);
  commitStorey();
}

// ────────────────────────────────────────────────────────────────
// Event bindings
// ────────────────────────────────────────────────────────────────
storeyFromKind.addEventListener('change', commitStorey);
storeyToKind.addEventListener('change', commitStorey);

storeyFromLevel.addEventListener('blur', function () {
  onStoreyLevelChange(storeyFromLevel);
});

storeyToLevel.addEventListener('blur', function () {
  onStoreyLevelChange(storeyToLevel);
});

storeyFromLevel.addEventListener('keydown', function (event) {
  if (event.key === 'Enter') storeyFromLevel.blur();
});

storeyToLevel.addEventListener('keydown', function (event) {
  if (event.key === 'Enter') storeyToLevel.blur();
});

navigationClass.addEventListener('change', commitNavigationSemantics);
navigationFunction.addEventListener('change', commitNavigationSemantics);
navigationUsage.addEventListener('change', commitNavigationSemantics);

changeTypeButton.addEventListener('click', function () {
  invokeSketchup('setSelectedCellSpaceClassification', [selectedClassification.value]);
});

convertSelectedButton.addEventListener('click', function () {
  invokeSketchup('convertSelectedSolidGroups', [solidClassification.value]);
});

finishButton.addEventListener('click', function () {
  invokeSketchup('finishEditing');
});

clearAllButton.addEventListener('click', function () {
  invokeSketchup('clearAllIndoorGmlElements');
});

recheckErrorsButton.addEventListener('click', function () {
  invokeSketchup('recheckFixModeErrors');
});

document.addEventListener('dragstart', function (event) {
  if (!event.target.closest('.copyable-cell-id')) {
    event.preventDefault();
  }
});

document.addEventListener('keydown', function (event) {
  if (event.target && event.target.matches('input, textarea')) return;

  if ((event.ctrlKey || event.metaKey) && String(event.key).toLowerCase() === 'a') {
    event.preventDefault();
    event.stopPropagation();
  }
}, true);

document.addEventListener('selectionchange', function () {
  var activeElement = document.activeElement;
  if (activeElement && activeElement.matches('input, textarea')) return;

  var selection = window.getSelection && window.getSelection();
  if (!selection || selection.rangeCount === 0) return;

  var anchor = selection.anchorNode && selection.anchorNode.nodeType === Node.ELEMENT_NODE
    ? selection.anchorNode
    : selection.anchorNode && selection.anchorNode.parentElement;

  var focus = selection.focusNode && selection.focusNode.nodeType === Node.ELEMENT_NODE
    ? selection.focusNode
    : selection.focusNode && selection.focusNode.parentElement;

  if (
    anchor && anchor.closest('.copyable-cell-id') &&
    focus && focus.closest('.copyable-cell-id')
  ) {
    return;
  }

  selection.removeAllRanges();
});

window.addEventListener('load', function () {
  invokeSketchup('domReady');
  fitDialogToContent();
});

window.addEventListener('resize', fitDialogToContent);

Array.prototype.forEach.call(document.images, function (image) {
  image.addEventListener('load', fitDialogToContent);
});

// Explicitly expose Ruby-callable functions on window.
window.init = init;
window.updateSelection = updateSelection;
window.updateSelectionAndFit = updateSelectionAndFit;
