var overlayMinRadius = document.getElementById('overlayMinRadius');
var overlayMaxRadius = document.getElementById('overlayMaxRadius');
var overlayRadiusValue = document.getElementById('overlayRadiusValue');
var minRadiusPreview = document.getElementById('minRadiusPreview');
var maxRadiusPreview = document.getElementById('maxRadiusPreview');
var emptyPanel = document.getElementById('emptyPanel');
var solidPanel = document.getElementById('solidPanel');
var cellPanel = document.getElementById('cellPanel');
var solidCount = document.getElementById('solidCount');
var solidClassification = document.getElementById('solidClassification');
var selectedClassification = document.getElementById('selectedClassification');
var selectedId = document.getElementById('selectedId');
var selectedName = document.getElementById('selectedName');
var transitionCount = document.getElementById('transitionCount');
var singleCellInfo = document.getElementById('singleCellInfo');
var multiCellInfo = document.getElementById('multiCellInfo');
var cellSpaceCount = document.getElementById('cellSpaceCount');
var clearAll = document.getElementById('clearAll');
var recheckErrors = document.getElementById('recheckErrors');
var modeTitle = document.getElementById('modeTitle');
var cellTypeCounts = document.getElementById('cellTypeCounts');
var stateCount = document.getElementById('stateCount');
var totalTransitionCount = document.getElementById('totalTransitionCount');
var suppressTypeChange = false;
var currentMode = null;
var currentSelectionKey = null;
var fixMode = false;

function init(config) {
  fixMode = Boolean(config.fixMode);
  modeTitle.textContent = fixMode ? '수정 모드' : '편집 모드';
  document.getElementById('finish').textContent = fixMode ? '수정 완료' : '편집 완료';
  setVisible(clearAll, false);
  setVisible(recheckErrors, fixMode);
  fillOptions(selectedClassification, config.classificationOptions);
  fillOptions(solidClassification, config.classificationOptions);
  setIcon('convertIcon', config.assetRoot, 'create_cellspace.svg');
  setIcon('changeTypeIcon', config.assetRoot, 'change_cellspace_type.svg');
  applyOverlayColors(config.overlayColors);
  overlayMinRadius.value = config.minRadius;
  overlayMaxRadius.value = config.maxRadius;
  updateSelection(null);
  normalizedOverlayRadiusRange();
  fitDialogToContent();
}

function fillOptions(select, options) {
  select.innerHTML = '';
  options.forEach(function (option) {
    var element = document.createElement('option');
    element.value = option.value;
    element.textContent = option.label;
    select.appendChild(element);
  });
}

function setIcon(id, assetRoot, filename) {
  var image = document.getElementById(id);
  if (!image || !assetRoot) return;
  image.src = encodeURI('file:///' + assetRoot + '/assets/icons/' + filename);
}

function applyOverlayColors(colors) {
  if (!colors) return;

  document.documentElement.style.setProperty('--overlay-state-color', colors.state);
  document.documentElement.style.setProperty('--overlay-state-soft-color', colors.stateSoft);
}

function updateSelection(snapshot) {
  var nextMode = snapshot && snapshot.mode ? snapshot.mode : 'empty';
  var nextKey = selectionKey(snapshot);
  if (nextKey === currentSelectionKey) {
    return false;
  }

  var modeChanged = nextMode !== currentMode;
  suppressTypeChange = true;
  if (modeChanged) {
    setVisible(emptyPanel, nextMode === 'empty');
    setVisible(solidPanel, nextMode === 'solid_groups');
    setVisible(cellPanel, nextMode === 'cell_space' || nextMode === 'cell_spaces');
    setVisible(clearAll, !fixMode && nextMode === 'empty');
    setVisible(recheckErrors, fixMode);
    currentMode = nextMode;
  }

  if (nextMode === 'solid_groups') {
    showSolidGroups(snapshot);
  } else if (nextMode === 'cell_spaces') {
    showCellSpaces(snapshot);
  } else if (nextMode === 'cell_space') {
    showCellSpace(snapshot);
  } else {
    showEmpty(snapshot);
  }

  currentSelectionKey = nextKey;
  suppressTypeChange = false;
  return modeChanged;
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

function setVisible(element, visible) {
  if (visible) {
    show(element);
  } else {
    hide(element);
  }
}

function showSolidGroups(snapshot) {
  solidCount.textContent = snapshot.solidGroupCount || 0;
  solidClassification.value = snapshot.classification || 'GeneralSpace|Room';
  setControlLocked(solidClassification, null, snapshot.classificationLocked);
  show(solidPanel);
}

function showEmpty(snapshot) {
  var counts = snapshot && snapshot.cellTypeCounts ? snapshot.cellTypeCounts : [];
  cellTypeCounts.innerHTML = '';
  counts.forEach(function (entry) {
    var row = document.createElement('div');
    row.className = 'type-count-row';
    var label = document.createElement('span');
    label.textContent = entry.label || '-';
    var count = document.createElement('strong');
    count.textContent = entry.count || 0;
    row.appendChild(label);
    row.appendChild(count);
    cellTypeCounts.appendChild(row);
  });
  stateCount.textContent = snapshot && snapshot.stateCount ? snapshot.stateCount : 0;
  totalTransitionCount.textContent = snapshot && snapshot.totalTransitionCount ? snapshot.totalTransitionCount : 0;
}

function showCellSpaces(snapshot) {
  hide(singleCellInfo);
  show(multiCellInfo);
  cellSpaceCount.textContent = snapshot.cellSpaceCount || 0;
  selectedClassification.value = snapshot.classification || 'GeneralSpace|Room';
  setControlLocked(selectedClassification, document.getElementById('changeType'), snapshot.classificationLocked);
  show(cellPanel);
}

function showCellSpace(snapshot) {
  show(singleCellInfo);
  hide(multiCellInfo);
  selectedId.textContent = snapshot.id || '-';
  selectedName.textContent = snapshot.name || '-';
  transitionCount.textContent = snapshot.transitionCount || 0;
  selectedClassification.value = snapshot.classification || 'GeneralSpace|Room';
  setControlLocked(selectedClassification, document.getElementById('changeType'), snapshot.classificationLocked);
  show(cellPanel);
}

function setControlLocked(select, button, locked) {
  var disabled = Boolean(locked);
  if (select) select.disabled = disabled;
  if (button) button.disabled = disabled;
}

function show(element) {
  element.classList.remove('hidden');
}

function hide(element) {
  element.classList.add('hidden');
}

function normalizedOverlayRadiusRange() {
  var minRadius = Number(overlayMinRadius.value);
  var maxRadius = Number(overlayMaxRadius.value);
  if (minRadius > maxRadius) {
    var swap = minRadius;
    minRadius = maxRadius;
    maxRadius = swap;
  }
  overlayRadiusValue.textContent = minRadius + '-' + maxRadius + ' px';
  minRadiusPreview.style.width = minRadius + 'px';
  minRadiusPreview.style.height = minRadius + 'px';
  maxRadiusPreview.style.width = maxRadius + 'px';
  maxRadiusPreview.style.height = maxRadius + 'px';
  return [minRadius, maxRadius];
}

function previewOverlayRadiusRange() {
  normalizedOverlayRadiusRange();
}

function commitOverlayRadiusRange() {
  var range = normalizedOverlayRadiusRange();
  sketchup.setOverlayRadiusRange(range[0], range[1]);
}

function fitDialogToContent() {
  var contentHeight = document.body.scrollHeight;
  sketchup.fitContentHeight(contentHeight);
}

overlayMinRadius.addEventListener('input', previewOverlayRadiusRange);
overlayMaxRadius.addEventListener('input', previewOverlayRadiusRange);
overlayMinRadius.addEventListener('change', commitOverlayRadiusRange);
overlayMaxRadius.addEventListener('change', commitOverlayRadiusRange);
solidClassification.addEventListener('change', fitDialogToContent);
document.getElementById('changeType').addEventListener('click', function () {
  sketchup.setSelectedCellSpaceClassification(selectedClassification.value);
});
document.getElementById('convertSelected').addEventListener('click', function () {
  sketchup.convertSelectedSolidGroups(solidClassification.value);
});
document.getElementById('finish').addEventListener('click', function () {
  sketchup.finishEditing();
});
document.getElementById('clearAll').addEventListener('click', function () {
  sketchup.clearAllIndoorGmlElements();
});
recheckErrors.addEventListener('click', function () {
  sketchup.recheckFixModeErrors();
});
document.addEventListener('dragstart', function (event) {
  if (!event.target.closest('.copyable-cell-id')) {
    event.preventDefault();
  }
});
document.addEventListener('keydown', function (event) {
  if ((event.ctrlKey || event.metaKey) && String(event.key).toLowerCase() === 'a') {
    event.preventDefault();
    event.stopPropagation();
  }
}, true);
document.addEventListener('selectionchange', function () {
  var selection = window.getSelection && window.getSelection();
  if (!selection || selection.rangeCount === 0) return;

  var anchor = selection.anchorNode && selection.anchorNode.nodeType === Node.ELEMENT_NODE ?
    selection.anchorNode :
    selection.anchorNode && selection.anchorNode.parentElement;
  var focus = selection.focusNode && selection.focusNode.nodeType === Node.ELEMENT_NODE ?
    selection.focusNode :
    selection.focusNode && selection.focusNode.parentElement;
  if ((anchor && anchor.closest('.copyable-cell-id')) && (focus && focus.closest('.copyable-cell-id'))) return;

  selection.removeAllRanges();
});
window.addEventListener('load', function () {
  sketchup.domReady();
});
window.addEventListener('resize', fitDialogToContent);
