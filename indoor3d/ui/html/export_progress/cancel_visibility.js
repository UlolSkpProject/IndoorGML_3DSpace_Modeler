var validationCancellable = false;

function setCancellable(value) {
  validationCancellable = value === true;
  updateCancelVisibility();
  fitDialogToContent();
}

function updateCancelVisibility() {
  var button = document.getElementById('cancel-validation');
  if (!button) return;

  var terminal = typeof terminalResultShown !== 'undefined' && terminalResultShown;
  var visible = validationCancellable && !terminal;
  button.disabled = !visible;
  button.hidden = !visible;
  button.style.display = visible ? 'inline-flex' : 'none';
}
