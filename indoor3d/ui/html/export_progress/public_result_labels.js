(function () {
  'use strict';

  var originalSetResult = window.setResult;
  if (typeof originalSetResult !== 'function') return;

  window.setResult = function (payload) {
    var publicPayload = Object.assign({}, payload || {});

    if (publicPayload.status === 'success') {
      publicPayload.title = 'Valid';
    } else if (publicPayload.status === 'failed') {
      publicPayload.title = 'Invalid';
    } else if (publicPayload.status === 'error') {
      publicPayload.title = 'Failed';
    }

    return originalSetResult(publicPayload);
  };
}());
