function isExternalFileDrag(event) {
  const dataTransfer = event?.dataTransfer;
  if (!dataTransfer) return false;

  if (dataTransfer.files?.length > 0) return true;

  return Array.from(dataTransfer.types || []).includes('Files');
}

function preventExternalFileNavigation(event) {
  if (!isExternalFileDrag(event)) return;

  event.preventDefault();

  if (event.type === 'dragover' && event.dataTransfer) {
    event.dataTransfer.dropEffect = 'none';
  }
}

function initExternalFileDropGuard() {
  if (window.__indoorGmlExternalFileDropGuardInitialized) return;

  window.__indoorGmlExternalFileDropGuardInitialized = true;
  window.addEventListener(
    'dragover',
    preventExternalFileNavigation,
    true
  );

  window.addEventListener(
    'drop',
    preventExternalFileNavigation,
    true
  );
}
