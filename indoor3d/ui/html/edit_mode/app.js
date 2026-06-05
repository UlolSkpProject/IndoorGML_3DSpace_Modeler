var overlayMinRadius = document.getElementById('overlayMinRadius');
var overlayMaxRadius = document.getElementById('overlayMaxRadius');
var overlayRadiusValue = document.getElementById('overlayRadiusValue');
var selectedFeature = document.getElementById('selectedFeature');
var selectedId = document.getElementById('selectedId');
var selectedName = document.getElementById('selectedName');
var selectedClassification = document.getElementById('selectedClassification');
var suppressTypeChange = false;

function init(minRadius, maxRadius, classificationOptions) {
  selectedClassification.innerHTML = '';
  classificationOptions.forEach(function (option) {
    var element = document.createElement('option');
    element.value = option.value;
    element.textContent = option.label;
    selectedClassification.appendChild(element);
  });
  overlayMinRadius.value = minRadius;
  overlayMaxRadius.value = maxRadius;
  updateSelectedCellSpace(null);
  normalizedOverlayRadiusRange();
  fitDialogToContent();
}

function updateSelectedCellSpace(snapshot) {
  suppressTypeChange = true;
  if (!snapshot || !snapshot.id) {
    selectedFeature.textContent = 'None';
    selectedId.textContent = '-';
    selectedName.textContent = '-';
    selectedClassification.disabled = true;
    selectedClassification.value = 'GeneralSpace|Room';
  } else {
    selectedFeature.textContent = snapshot.feature || 'CellSpace';
    selectedId.textContent = snapshot.id || '-';
    selectedName.textContent = snapshot.name || '-';
    selectedClassification.disabled = false;
    selectedClassification.value = snapshot.classification || 'GeneralSpace|Room';
  }
  suppressTypeChange = false;
}

function normalizedOverlayRadiusRange() {
  var minRadius = Number(overlayMinRadius.value);
  var maxRadius = Number(overlayMaxRadius.value);
  overlayRadiusValue.textContent = `${minRadius}-${maxRadius} px`;
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
  var contentHeight = Math.max(
    document.body.scrollHeight,
    document.documentElement.scrollHeight
  );
  sketchup.fitContentHeight(contentHeight);
}

overlayMinRadius.addEventListener('input', previewOverlayRadiusRange);
overlayMaxRadius.addEventListener('input', previewOverlayRadiusRange);
overlayMinRadius.addEventListener('change', commitOverlayRadiusRange);
overlayMaxRadius.addEventListener('change', commitOverlayRadiusRange);
selectedClassification.addEventListener('change', function () {
  if (!suppressTypeChange) {
    sketchup.setSelectedCellSpaceClassification(selectedClassification.value);
  }
});
document.getElementById('finish').addEventListener('click', function () {
  sketchup.finishEditing();
});
document.getElementById('clearAll').addEventListener('click', function () {
  sketchup.clearAllIndoorGmlElements();
});
window.addEventListener('load', function () {
  sketchup.domReady();
});
window.addEventListener('resize', fitDialogToContent);
