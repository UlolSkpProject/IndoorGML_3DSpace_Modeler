// ────────────────────────────────────────────────────────────────
// DOM references
// ────────────────────────────────────────────────────────────────
var emptyPanel = document.getElementById('emptyPanel');
var solidPanel = document.getElementById('solidPanel');
var cellPanel = document.getElementById('cellPanel');
var filterPanel = document.getElementById('filterPanel');
var storeyFilterAll = document.getElementById('storeyFilterAll');
var storeyFilterOptions = document.getElementById('storeyFilterOptions');
var typeFilterAll = document.getElementById('typeFilterAll');
var typeFilterOptions = document.getElementById('typeFilterOptions');

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

var selectedClassification = document.getElementById('selectedClassification');
var changeTypeButton = document.getElementById('changeType');

var cellTypeCounts = document.getElementById('cellTypeCounts');
var stateCount = document.getElementById('stateCount');
var totalTransitionCount = document.getElementById('totalTransitionCount');

var currentMode = null;
var currentSelectionKey = null;
var fixMode = false;
var currentStoreyRangeAllowed = false;
var suppressFilterEvents = false;
var currentVisibilityFilter = {
  storeyOptions: [],
  selectedStoreys: [],
  cellTypeOptions: [],
  selectedCellTypes: []
};

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

function normalizeArray(values) {
  return Array.isArray(values) ? values : [];
}

function selectedSet(values) {
  return normalizeArray(values).reduce(function (memo, value) {
    memo[String(value)] = true;
    return memo;
  }, {});
}

function renderVisibilityFilter(filter) {
  filter = filter || {};
  currentVisibilityFilter = {
    storeyOptions: normalizeArray(filter.storeyOptions),
    selectedStoreys: normalizeArray(filter.selectedStoreys),
    cellTypeOptions: normalizeArray(filter.cellTypeOptions),
    selectedCellTypes: normalizeArray(filter.selectedCellTypes)
  };

  suppressFilterEvents = true;
  renderFilterGroup(
    storeyFilterOptions,
    storeyFilterAll,
    currentVisibilityFilter.storeyOptions,
    currentVisibilityFilter.selectedStoreys,
    'storey'
  );
  renderFilterGroup(
    typeFilterOptions,
    typeFilterAll,
    currentVisibilityFilter.cellTypeOptions,
    currentVisibilityFilter.selectedCellTypes,
    'type'
  );
  suppressFilterEvents = false;
}

function renderFilterGroup(container, allCheckbox, options, selectedValues, name) {
  var selected = selectedSet(selectedValues);
  var allSelected = selectedValues.length === 0;

  allCheckbox.checked = allSelected;
  container.innerHTML = '';

  if (!options.length) {
    var empty = document.createElement('span');
    empty.className = 'filter-option empty';
    empty.textContent = '-';
    container.appendChild(empty);
    return;
  }

  options.forEach(function (option) {
    var label = document.createElement('label');
    var input = document.createElement('input');
    var text = document.createElement('span');

    label.className = 'filter-option';
    input.type = 'checkbox';
    input.name = name + 'Filter';
    input.value = option.value;
    input.checked = !allSelected && selected[String(option.value)] === true;
    input.addEventListener('change', onFilterOptionChanged);
    text.textContent = option.label || option.value;

    label.appendChild(input);
    label.appendChild(text);
    container.appendChild(label);
  });
}

function checkedFilterValues(container) {
  return Array.prototype.map.call(
    container.querySelectorAll('input[type="checkbox"]:checked'),
    function (input) { return input.value; }
  );
}

function commitVisibilityFilter() {
  if (suppressFilterEvents) return;

  var selectedStoreys = storeyFilterAll.checked ? [] : checkedFilterValues(storeyFilterOptions);
  var selectedTypes = typeFilterAll.checked ? [] : checkedFilterValues(typeFilterOptions);

  invokeSketchup('setEditModeVisibilityFilter', [
    JSON.stringify(selectedStoreys),
    JSON.stringify(selectedTypes)
  ]);
}

function onFilterAllChanged(event) {
  if (suppressFilterEvents) return;

  var allCheckbox = event.currentTarget;
  var container = allCheckbox === storeyFilterAll ? storeyFilterOptions : typeFilterOptions;

  if (allCheckbox.checked) {
    Array.prototype.forEach.call(container.querySelectorAll('input[type="checkbox"]'), function (input) {
      input.checked = false;
    });
  } else if (!checkedFilterValues(container).length) {
    allCheckbox.checked = true;
  }

  commitVisibilityFilter();
}

function onFilterOptionChanged(event) {
  if (suppressFilterEvents) return;

  var input = event.currentTarget;
  var isStorey = input.name === 'storeyFilter';
  var allCheckbox = isStorey ? storeyFilterAll : typeFilterAll;
  var container = isStorey ? storeyFilterOptions : typeFilterOptions;

  if (checkedFilterValues(container).length) {
    allCheckbox.checked = false;
  } else {
    allCheckbox.checked = true;
  }

  commitVisibilityFilter();
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
  if (!currentStoreyRangeAllowed) {
    storeyToKind.value = storeyFromKind.value;
    storeyToLevel.value = storeyFromLevel.value;
    return from;
  }

  var to = storeyToKind.value + padLevel(storeyToLevel.value);

  return from === to ? from : from + '~' + to;
}

function setStorey(value, rangeAllowed) {
  var parsed = parseStorey(value);

  currentStoreyRangeAllowed = Boolean(rangeAllowed);
  storeyFromKind.value = parsed.from.kind;
  storeyFromLevel.value = parsed.from.level;
  storeyToKind.value = currentStoreyRangeAllowed ? parsed.to.kind : parsed.from.kind;
  storeyToLevel.value = currentStoreyRangeAllowed ? parsed.to.level : parsed.from.level;
  setControlLocked([storeyToKind, storeyToLevel], !currentStoreyRangeAllowed);
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
  renderVisibilityFilter(config.visibilityFilter);

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
  setVisible(filterPanel, true);
  setVisible(clearAllButton, !fixMode && nextMode === 'empty');
  setVisible(recheckErrorsButton, fixMode);
  renderVisibilityFilter((snapshot || {}).visibilityFilter || currentVisibilityFilter);

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
    snapshot.storeyEditable ? 'storey-editable' : 'storey-readonly',
    snapshot.storeyRangeAllowed ? 'storey-range' : 'storey-single',
    snapshot.transitionCount || 0,
    snapshot.cellSpaceCount || 0,
    snapshot.solidGroupCount || 0,
    snapshot.stateCount || 0,
    snapshot.totalTransitionCount || 0,
    visibilityFilterKey(snapshot.visibilityFilter),
    cellTypeCountKey(snapshot.cellTypeCounts)
  ].join('|');
}

function cellTypeCountKey(counts) {
  if (!counts || !counts.length) return '';

  return counts.map(function (entry) {
    return [entry.label || '', entry.count || 0].join(':');
  }).join(',');
}

function visibilityFilterKey(filter) {
  if (!filter) return '';

  return [
    optionKey(filter.storeyOptions),
    normalizeArray(filter.selectedStoreys).join(','),
    optionKey(filter.cellTypeOptions),
    normalizeArray(filter.selectedCellTypes).join(',')
  ].join('|');
}

function optionKey(options) {
  return normalizeArray(options).map(function (entry) {
    return [entry.value || '', entry.label || ''].join(':');
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
  if (snapshot.storeyEditable) {
    setStorey(snapshot.storey || 'F01', Boolean(snapshot.storeyRangeAllowed));
  } else {
    hide(storeyFields);
  }
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

  setStorey(snapshot.storey || 'F01', Boolean(snapshot.storeyRangeAllowed));

  setControlLocked(
    [selectedClassification, changeTypeButton],
    snapshot.classificationLocked
  );
}

// ────────────────────────────────────────────────────────────────
// Commit helpers
// ────────────────────────────────────────────────────────────────
function commitStorey() {
  invokeSketchup('setSelectedCellSpaceStorey', [composeStorey()]);
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

storeyFilterAll.addEventListener('change', onFilterAllChanged);
typeFilterAll.addEventListener('change', onFilterAllChanged);

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
