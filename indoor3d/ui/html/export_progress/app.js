var icons = {
  pending: String.fromCodePoint(0x23F3),
  running: String.fromCodePoint(0x1F504),
  complete: String.fromCodePoint(0x2705),
  failed: String.fromCodePoint(0x274C)
};

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
}

function setStatus(step, status) {
  var row = document.getElementById('step-' + step);
  if (!row) return;
  row.className = status;
  row.querySelector('.icon').textContent = icons[status] || icons.pending;
}

window.addEventListener('load', function () {
  sketchup.domReady();
});
