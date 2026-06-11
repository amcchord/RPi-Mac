// Progress-reporting uploads: any form marked with data-progress is
// submitted via XHR so large ISO/disk transfers show progress and don't
// look like a hung page.
(function () {
  var forms = document.querySelectorAll("form[data-progress]");
  forms.forEach(function (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var statusEl = form.querySelector(".upload-status");
      var button = form.querySelector("button[type=submit]");
      var data = new FormData(form);
      var xhr = new XMLHttpRequest();
      xhr.open("POST", form.action);
      xhr.upload.onprogress = function (ev) {
        if (ev.lengthComputable && statusEl) {
          var pct = Math.floor((ev.loaded / ev.total) * 100);
          var mb = (ev.loaded / 1048576).toFixed(1);
          var total = (ev.total / 1048576).toFixed(1);
          statusEl.textContent = "Uploading... " + pct + "% (" + mb + " / " + total + " MB)";
        }
      };
      xhr.onload = function () {
        if (statusEl) { statusEl.textContent = "Done."; }
        window.location.reload();
      };
      xhr.onerror = function () {
        if (statusEl) { statusEl.textContent = "Upload failed - try again."; }
        if (button) { button.disabled = false; }
      };
      xhr.timeout = 0;
      if (button) { button.disabled = true; }
      if (statusEl) { statusEl.textContent = "Uploading... 0%"; }
      xhr.send(data);
    });
  });
})();
