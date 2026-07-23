// ────────────────────────────────────────────────────────────────
// DOM references
// ────────────────────────────────────────────────────────────────
var emptyPanel = document.getElementById('emptyPanel');
var solidPanel = document.getElementById('solidPanel');
var cellPanel = document.getElementById('cellPanel');
var filterPanel = document.getElementById('filterPanel');
var filterToggle = document.getElementById('filterToggle');
var storeyFilterOptions = document.getElementById('storeyFilterOptions');
var typeFilterOptions = document.getElementById('typeFilterOptions');

var modeTitle = document.getElementById('modeTitle');
var finishButton = document.getElementById('finish');
var clearAllButton = document.getElementById('clearAll');
var recheckErrorsButton = document.getElementById('recheckErrors');

var solidCount = document.getElementById('solidCount');
var solidClassification = document.getElementById('solidClassification');
var convertSelectedButton = document.getElementById('convertSelected');
var solidStoreyFields = document.getElementById('solidStoreyFields');
var solidStoreyFromKind = document.getElementById('solidStoreyFromKind');
var solidStoreyFromLevel = document.getElementById('solidStoreyFromLevel');
var solidStoreyToKind = document.getElementById('solidStoreyToKind');
var solidStoreyToLevel = document.getElementById('solidStoreyToLevel');

var singleCellInfo = document.getElementById('singleCellInfo');
var multiCellInfo = document.getElementById('multiCellInfo');
var selectedId = document.getElementById('selectedId');
var selectedName = document.getElementById('selectedName');
var transitionCount = document.getElementById('transitionCount');
var cellSpaceCount = document.getElementById('cellSpaceCount');
var selectedCellTypeCounts = document.getElementById('selectedCellTypeCounts');

var storeyFields = document.getElementById('storeyFields');
var storeyFromKind = document.getElementById('storeyFromKind');
var storeyFromLevel = document.getElementById('storeyFromLevel');
var storeyToKind = document.getElementById('storeyToKind');
var storeyToLevel = document.getElementById('storeyToLevel');

var selectedClassification = document.getElementById('selectedClassification');
var changeTypeButton = document.getElementById('changeType');
var removeIndoorGmlAttributesButton = document.getElementById('removeIndoorGmlAttributes');

var cellTypeCounts = document.getElementById('cellTypeCounts');
var stateCount = document.getElementById('stateCount');
var totalTransitionCount = document.getElementById('totalTransitionCount');

var currentMode = null;
var currentSelectionKey = null;
var fixMode = false;
var validationBusy = false;
var currentStoreyRangeAllowed = false;
var currentSolidStoreyRangeAllowed = false;
var rangeStoreyClassifications = [];
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
  renderStoreyFilterGroup(
    storeyFilterOptions,
    currentVisibilityFilter.storeyOptions,
    currentVisibilityFilter.selectedStoreys
  );
  renderFilterGroup(
    typeFilterOptions,
    currentVisibilityFilter.cellTypeOptions,
    currentVisibilityFilter.selectedCellTypes,
    'type'
  );
  suppressFilterEvents = false;
  applyFilterDisabled();
}

function renderFilterGroup(container, options, selectedValues, name) {
  var state = filterSelectionState(options, selectedValues);

  container.innerHTML = '';

  if (!options.length) {
    appendEmptyFilterOption(container);
    return;
  }

  options.forEach(function (option) {
    appendFilterOption(container, option, name, state.allSelected || state.selected[String(option.value)] === true);
  });
}

function renderStoreyFilterGroup(container, options, selectedValues) {
  var state = filterSelectionState(options, selectedValues);
  var groups = [
    { title: '지상층', options: [] },
    { title: '지하층', options: [] }
  ];

  container.innerHTML = '';

  if (!options.length) {
    appendEmptyFilterOption(container);
    return;
  }

  options.forEach(function (option) {
    var kind = String(option.value || '').charAt(0).toUpperCase();
    var group = kind === 'B' ? groups[1] : groups[0];
    group.options.push(option);
  });

  groups.forEach(function (group) {
    if (!group.options.length) return;

    var section = document.createElement('div');
    var title = document.createElement('div');
    var optionsContainer = document.createElement('div');

    section.className = 'storey-filter-group';
    title.className = 'storey-filter-group-title';
    title.textContent = group.title;
    optionsContainer.className = 'filter-options storey-filter-group-options';

    group.options.forEach(function (option) {
      appendFilterOption(optionsContainer, option, 'storey', state.allSelected || state.selected[String(option.value)] === true);
    });

    section.appendChild(title);
    section.appendChild(optionsContainer);
    container.appendChild(section);
  });
}

function filterSelectionState(options, selectedValues) {
  var selected = selectedSet(selectedValues);
  var optionValues = normalizeArray(options).map(function (option) {
    return String(option.value);
  });
  var selectedOptionCount = optionValues.filter(function (value) {
    return selected[value] === true;
  }).length;
  var allSelected = selectedValues.length === 0 || (optionValues.length > 0 && selectedOptionCount === optionValues.length);

  return {
    selected: selected,
    allSelected: allSelected
  };
}

function appendEmptyFilterOption(container) {
  var empty = document.createElement('span');
  empty.className = 'filter-option empty';
  empty.textContent = '-';
  container.appendChild(empty);
}

function appendFilterOption(container, option, name, checked) {
  var label = document.createElement('label');
  var input = document.createElement('input');
  var text = document.createElement('span');

  label.className = 'filter-option';
  input.type = 'checkbox';
  input.name = name + 'Filter';
  input.value = option.value;
  input.checked = checked;
  input.disabled = fixMode;
  input.addEventListener('change', onFilterOptionChanged);
  text.textContent = option.label || option.value;

  label.appendChild(input);
  label.appendChild(text);
  container.appendChild(label);
}

function checkedFilterValues(container) {
  return Array.prototype.map.call(
    container.querySelectorAll('input[type="checkbox"]:checked'),
    function (input) { return input.value; }
  );
}

function filterValuesForCommit(container) {
  var inputs = Array.prototype.slice.call(container.querySelectorAll('input[type="checkbox"]'));
  var checked = checkedFilterValues(container);

  return inputs.length === 0 || checked.length === inputs.length ? [] : checked;
}

function checkAllFilterOptions(container) {
  Array.prototype.forEach.call(container.querySelectorAll('input[type="checkbox"]'), function (input) {
    input.checked = true;
  });
}

function commitVisibilityFilter() {
  if (suppressFilterEvents) return;
  if (fixMode) return;

  var selectedStoreys = filterValuesForCommit(storeyFilterOptions);
  var selectedTypes = filterValuesForCommit(typeFilterOptions);

  invokeSketchup('setEditModeVisibilityFilter', [
    JSON.stringify(selectedStoreys),
    JSON.stringify(selectedTypes)
  ]);
}

function onFilterOptionChanged(event) {
  if (suppressFilterEvents) return;
  if (fixMode) return;

  var input = event.currentTarget;
  var isStorey = input.name === 'storeyFilter';
  var container = isStorey ? storeyFilterOptions : typeFilterOptions;

  if (!checkedFilterValues(container).length) {
    checkAllFilterOptions(container);
  }

  commitVisibilityFilter();
}

function setFilterCollapsed(collapsed) {
  filterPanel.classList.toggle('is-collapsed', collapsed);
  filterToggle.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
  fitDialogToContent();
}

function toggleFilterPanel() {
  if (fixMode) return;

  setFilterCollapsed(!filterPanel.classList.contains('is-collapsed'));
}

function applyFilterDisabled() {
  filterPanel.classList.toggle('is-disabled', fixMode);
  filterToggle.disabled = fixMode;

  Array.prototype.forEach.call(
    filterPanel.querySelectorAll('input[type="checkbox"]'),
    function (input) {
      input.disabled = fixMode;
    }
  );
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
  setControlLocked([storeyFromKind, storeyFromLevel], validationBusy);
  setControlLocked([storeyToKind, storeyToLevel], validationBusy || !currentStoreyRangeAllowed);
  storeyFields.classList.toggle('is-single-storey', !currentStoreyRangeAllowed);
  show(storeyFields);
}

function composeSolidStorey() {
  clampStoreyLevel(solidStoreyFromLevel);
  clampStoreyLevel(solidStoreyToLevel);

  var from = solidStoreyFromKind.value + padLevel(solidStoreyFromLevel.value);
  if (!currentSolidStoreyRangeAllowed) {
    solidStoreyToKind.value = solidStoreyFromKind.value;
    solidStoreyToLevel.value = solidStoreyFromLevel.value;
    return from;
  }

  var to = solidStoreyToKind.value + padLevel(solidStoreyToLevel.value);
  return from === to ? from : from + '~' + to;
}

function setSolidStorey(value, rangeAllowed) {
  var parsed = parseStorey(value);

  currentSolidStoreyRangeAllowed = Boolean(rangeAllowed);
  solidStoreyFromKind.value = parsed.from.kind;
  solidStoreyFromLevel.value = parsed.from.level;
  solidStoreyToKind.value = currentSolidStoreyRangeAllowed ? parsed.to.kind : parsed.from.kind;
  solidStoreyToLevel.value = currentSolidStoreyRangeAllowed ? parsed.to.level : parsed.from.level;
  setControlLocked([solidStoreyFromKind, solidStoreyFromLevel], validationBusy);
  setControlLocked(
    [solidStoreyToKind, solidStoreyToLevel],
    validationBusy || !currentSolidStoreyRangeAllowed
  );
  solidStoreyFields.classList.toggle('is-single-storey', !currentSolidStoreyRangeAllowed);
}

function classificationAllowsStoreyRange(value) {
  return rangeStoreyClassifications.indexOf(String(value || '')) >= 0;
}

// ────────────────────────────────────────────────────────────────
// Initialization called from Ruby
// ────────────────────────────────────────────────────────────────
function init(config) {
  config = config || {};
  fixMode = Boolean(config.fixMode);
  validationBusy = Boolean(config.validationBusy);
  rangeStoreyClassifications = normalizeArray(config.rangeStoreyClassifications);

  modeTitle.textContent = fixMode ? '수정 모드' : '편집 모드';
  finishButton.textContent = fixMode ? '수정 완료' : '편집 완료';

  fillOptions(selectedClassification, config.classificationOptions);
  fillOptions(solidClassification, config.classificationOptions);

  setIcon('convertIcon', config.assetRoot, 'create_cellspace.svg');
  setIcon('changeTypeIcon', config.assetRoot, 'change_cellspace_type.svg');
  applyOverlayColors(config.overlayColors);
  renderVisibilityFilter(config.visibilityFilter);
  applyFilterDisabled();

  setVisible(recheckErrorsButton, fixMode);
  setVisible(removeIndoorGmlAttributesButton, !fixMode);
  setControlLocked(
    [finishButton, recheckErrorsButton, removeIndoorGmlAttributesButton],
    validationBusy
  );
  updateSelection(null);
  fitDialogToContent();
}

// ────────────────────────────────────────────────────────────────
// Selection rendering called from Ruby
// ────────────────────────────────────────────────────────────────
function updateSelection(snapshot) {
  var nextMode = snapshot && snapshot.mode ? snapshot.mode : 'empty';
  if (snapshot && Object.prototype.hasOwnProperty.call(snapshot, 'validationBusy')) {
    validationBusy = Boolean(snapshot.validationBusy);
  }
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
  setControlLocked(
    [finishButton, recheckErrorsButton, removeIndoorGmlAttributesButton],
    validationBusy
  );
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
    snapshot.validationBusy ? 'validation-busy' : 'validation-idle',
    snapshot.storey || '',
    snapshot.storeyEditable ? 'storey-editable' : 'storey-readonly',
    snapshot.storeyRangeAllowed ? 'storey-range' : 'storey-single',
    snapshot.transitionCount || 0,
    snapshot.cellSpaceCount || 0,
    cellTypeCountKey(snapshot.selectedCellTypeCounts),
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
  renderCountRows(cellTypeCounts, snapshot.cellTypeCounts || []);

  stateCount.textContent = snapshot.stateCount || 0;
  totalTransitionCount.textContent = snapshot.totalTransitionCount || 0;
}

function renderCountRows(container, counts) {
  container.innerHTML = '';

  (counts || []).forEach(function (entry) {
    var row = document.createElement('div');
    var label = document.createElement('span');
    var count = document.createElement('strong');

    row.className = 'type-count-row';
    label.textContent = entry.label || '-';
    count.textContent = entry.count || 0;

    row.appendChild(label);
    row.appendChild(count);
    container.appendChild(row);
  });
}

function renderSolidGroups(snapshot) {
  solidCount.textContent = snapshot.solidGroupCount || 0;
  solidClassification.value = snapshot.classification || 'GeneralSpace|Room';
  setSolidStorey(
    snapshot.storey || 'F01',
    classificationAllowsStoreyRange(solidClassification.value)
  );

  setControlLocked(
    [solidClassification, convertSelectedButton],
    validationBusy || snapshot.classificationLocked
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

  cellSpaceCount.textContent = snapshot.cellSpaceCount || 0;
  renderCountRows(selectedCellTypeCounts, snapshot.selectedCellTypeCounts || []);
  selectedClassification.value = snapshot.classification || 'GeneralSpace|Room';

  setControlLocked(
    [selectedClassification, changeTypeButton],
    validationBusy || snapshot.classificationLocked
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
    validationBusy || snapshot.classificationLocked
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

solidClassification.addEventListener('change', function () {
  setSolidStorey(
    composeSolidStorey(),
    classificationAllowsStoreyRange(solidClassification.value)
  );
});

solidStoreyFromKind.addEventListener('change', function () {
  if (!currentSolidStoreyRangeAllowed) setSolidStorey(composeSolidStorey(), false);
});

solidStoreyToKind.addEventListener('change', function () {
  composeSolidStorey();
});

solidStoreyFromLevel.addEventListener('blur', function () {
  clampStoreyLevel(solidStoreyFromLevel);
  if (!currentSolidStoreyRangeAllowed) setSolidStorey(composeSolidStorey(), false);
});

solidStoreyToLevel.addEventListener('blur', function () {
  clampStoreyLevel(solidStoreyToLevel);
});

solidStoreyFromLevel.addEventListener('keydown', function (event) {
  if (event.key === 'Enter') solidStoreyFromLevel.blur();
});

solidStoreyToLevel.addEventListener('keydown', function (event) {
  if (event.key === 'Enter') solidStoreyToLevel.blur();
});

filterToggle.addEventListener('click', toggleFilterPanel);

changeTypeButton.addEventListener('click', function () {
  invokeSketchup('setSelectedCellSpaceClassification', [selectedClassification.value]);
});

removeIndoorGmlAttributesButton.addEventListener('click', function () {
  invokeSketchup('removeSelectedCellSpacesIndoorGmlAttributes');
});

convertSelectedButton.addEventListener('click', function () {
  invokeSketchup('convertSelectedSolidGroups', [solidClassification.value, composeSolidStorey()]);
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
