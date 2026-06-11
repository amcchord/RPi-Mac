// Progress-reporting uploads: any form marked with data-progress is
// submitted as a raw-body upload (faster: skips a server-side temp copy
// at SD-card speeds) with progress and honest post-transfer status.
(function () {
  var forms = document.querySelectorAll("form[data-progress]");
  forms.forEach(function (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var statusEl = form.querySelector(".upload-status");
      var button = form.querySelector("button[type=submit]");
      var fileInput = form.querySelector("input[type=file]");
      if (!fileInput || !fileInput.files.length) { return; }
      var file = fileInput.files[0];
      var kindInput = form.querySelector("input[name=kind]");
      var kind = form.getAttribute("data-kind");
      if (!kind && kindInput) { kind = kindInput.value; }
      if (!kind) { kind = "shared"; }

      var xhr = new XMLHttpRequest();
      xhr.open("POST", "/upload-raw?kind=" + encodeURIComponent(kind) +
                       "&name=" + encodeURIComponent(file.name));
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      xhr.upload.onprogress = function (ev) {
        if (!ev.lengthComputable || !statusEl) { return; }
        var pct = Math.floor((ev.loaded / ev.total) * 100);
        var mb = (ev.loaded / 1048576).toFixed(1);
        var total = (ev.total / 1048576).toFixed(1);
        if (pct >= 100) {
          statusEl.textContent =
            "Transfer done - writing to the SD card... this takes a " +
            "minute or two for large files. Keep the page open.";
        } else {
          statusEl.textContent = "Uploading... " + pct + "% (" + mb + " / " + total + " MB)";
        }
      };
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) {
          if (statusEl) { statusEl.textContent = "Done."; }
          window.location.reload();
        } else {
          if (statusEl) { statusEl.textContent = "Upload failed (" + xhr.status + ") - try again."; }
          if (button) { button.disabled = false; }
        }
      };
      xhr.onerror = function () {
        if (statusEl) { statusEl.textContent = "Upload failed - try again."; }
        if (button) { button.disabled = false; }
      };
      xhr.timeout = 0;
      if (button) { button.disabled = true; }
      if (statusEl) { statusEl.textContent = "Uploading... 0%"; }
      xhr.send(file);
    });
  });
})();
