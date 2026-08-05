(function () {
  var originalInit = window.init;

  window.init = function (steps) {
    originalInit(steps);

    steps.forEach(function (step) {
      var row = document.getElementById('step-' + step.key);
      if (!row) return;

      var content = row.querySelector('.step-content');
      if (!content) return;

      var summary = document.createElement('div');
      summary.id = 'step-summary-' + step.key;
      summary.className = 'step-summary hidden';
      content.appendChild(summary);
    });

    fitDialogToContent();
  };
})();

function setStepSummary(payload) {
  if (!payload) return;

  var summary = document.getElementById('step-summary-' + payload.step);
  if (!summary) return;

  var message = payload.message || '';
  if (!message) {
    summary.textContent = '';
    summary.className = 'step-summary hidden';
    fitDialogToContent();
    return;
  }

  summary.textContent = message;
  summary.className = 'step-summary ' + (payload.tone || 'neutral');
  fitDialogToContent();
}
