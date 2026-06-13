// Raw-body component uploads with progress (same approach as the on-Pi
// web UI: the file streams straight to disk on the server).
(function () {
  var forms = document.querySelectorAll("form[data-upload]");
  forms.forEach(function (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var statusEl = form.querySelector(".upload-status");
      var button = form.querySelector("button[type=submit]");
      var fileInput = form.querySelector("input[type=file]");
      if (!fileInput || !fileInput.files.length) { return; }
      var file = fileInput.files[0];
      var kind = form.getAttribute("data-kind");

      var xhr = new XMLHttpRequest();
      xhr.open("POST", "/admin/upload-raw?kind=" + encodeURIComponent(kind) +
                       "&name=" + encodeURIComponent(file.name));
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      xhr.upload.onprogress = function (ev) {
        if (!ev.lengthComputable || !statusEl) { return; }
        var pct = Math.floor((ev.loaded / ev.total) * 100);
        var mb = (ev.loaded / 1048576).toFixed(1);
        var total = (ev.total / 1048576).toFixed(1);
        statusEl.textContent = "Uploading... " + pct + "% (" + mb + " / " + total + " MB)";
      };
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) {
          statusEl.textContent = "Done.";
          window.location.reload();
        } else {
          var message = "Upload failed (" + xhr.status + ").";
          try {
            var data = JSON.parse(xhr.responseText);
            if (data.error) { message = data.error; }
          } catch (err) { /* keep generic message */ }
          statusEl.textContent = message;
          button.disabled = false;
        }
      };
      xhr.onerror = function () {
        statusEl.textContent = "Upload failed - try again.";
        button.disabled = false;
      };
      xhr.timeout = 0;
      button.disabled = true;
      statusEl.textContent = "Uploading... 0%";
      xhr.send(file);
    });
  });
})();
