// SD Card Builder wizard: disk ordering, blank disks, size estimate and
// build submission.
(function () {
  var form = document.getElementById("builder-form");
  if (!form) { return; }

  var diskOrder = [];   // component ids in the order they were ticked
  var blankCount = 0;

  function updateDiskBadges() {
    var badges = document.querySelectorAll(".disk-order");
    badges.forEach(function (badge) {
      var id = parseInt(badge.getAttribute("data-for"), 10);
      var index = diskOrder.indexOf(id);
      if (index === -1) {
        badge.hidden = true;
      } else {
        badge.hidden = false;
        if (index === 0) {
          badge.textContent = "startup";
        } else {
          badge.textContent = "disk " + (index + 1);
        }
      }
    });
  }

  function updateEstimate() {
    var total = 0;
    document.querySelectorAll(".disk-check:checked, .iso-check:checked").forEach(function (box) {
      var row = box.closest("li");
      var sizeEl = row.querySelector("[data-size]");
      if (sizeEl) { total += parseInt(sizeEl.getAttribute("data-size"), 10); }
    });
    document.querySelectorAll(".blank-size").forEach(function (sel) {
      total += parseInt(sel.value, 10) * 1048576;
    });
    var el = document.getElementById("payload-estimate");
    if (total > 0) {
      el.textContent = "About " + (total / 1073741824).toFixed(1) +
        " GB of Mac software selected.";
    } else {
      el.textContent = "";
    }
  }

  document.querySelectorAll(".disk-check").forEach(function (box) {
    box.addEventListener("change", function () {
      var id = parseInt(box.value, 10);
      var index = diskOrder.indexOf(id);
      if (box.checked && index === -1) {
        diskOrder.push(id);
      }
      if (!box.checked && index !== -1) {
        diskOrder.splice(index, 1);
      }
      updateDiskBadges();
      updateEstimate();
    });
  });

  document.querySelectorAll(".iso-check").forEach(function (box) {
    box.addEventListener("change", updateEstimate);
  });

  // ----------------------------------------------------- blank disks ---
  var blanksDiv = document.getElementById("blank-disks");
  var addBlank = document.getElementById("add-blank");

  function refreshAddButton() {
    addBlank.disabled = blanksDiv.children.length >= window.MAX_BLANK_DISKS;
  }

  addBlank.addEventListener("click", function () {
    blankCount += 1;
    var row = document.createElement("div");
    row.className = "field-row blank-row";
    row.innerHTML =
      '<label>Name <input type="text" class="blank-name" maxlength="27" ' +
      'value="Blank Disk ' + blankCount + '"></label> ' +
      '<label>Size <select class="blank-size">' +
      '<option value="100">100 MB</option>' +
      '<option value="250">250 MB</option>' +
      '<option value="500" selected>500 MB</option>' +
      '<option value="1024">1 GB</option>' +
      '<option value="2048">2 GB</option>' +
      '</select></label> ' +
      '<button type="button" class="btn btn-small blank-remove">Remove</button>';
    row.querySelector(".blank-remove").addEventListener("click", function () {
      row.remove();
      refreshAddButton();
      updateEstimate();
    });
    row.querySelector(".blank-size").addEventListener("change", updateEstimate);
    blanksDiv.appendChild(row);
    refreshAddButton();
    updateEstimate();
  });

  // ---------------------------------------------------------- submit ---
  function showError(message) {
    var el = document.getElementById("builder-error");
    el.textContent = message;
    el.hidden = false;
  }

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    document.getElementById("builder-error").hidden = true;

    var romInput = form.querySelector("input[name=rom]:checked");
    if (!romInput) {
      showError("Pick a ROM first.");
      return;
    }

    var isos = [];
    document.querySelectorAll(".iso-check:checked").forEach(function (box) {
      isos.push(parseInt(box.value, 10));
    });

    var blanks = [];
    var blankOk = true;
    blanksDiv.querySelectorAll(".blank-row").forEach(function (row) {
      var name = row.querySelector(".blank-name").value.trim();
      if (!name) { blankOk = false; }
      blanks.push({
        name: name,
        size_mb: parseInt(row.querySelector(".blank-size").value, 10)
      });
    });
    if (!blankOk) {
      showError("Every blank disk needs a name.");
      return;
    }

    var payload = {
      base: document.getElementById("base-select").value,
      rom: parseInt(romInput.value, 10),
      disks: diskOrder.slice(),
      blank_disks: blanks,
      isos: isos,
      boot: form.querySelector("input[name=boot]:checked").value,
      network: {
        wifi_ssid: document.getElementById("wifi-ssid").value,
        wifi_pass: document.getElementById("wifi-pass").value,
        wifi_country: document.getElementById("wifi-country").value.toUpperCase()
      },
      display: form.querySelector("input[name=display]:checked").value,
      rotate: document.getElementById("rotate-select").value
    };

    var button = document.getElementById("build-button");
    button.disabled = true;
    fetch("/api/builds", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    }).then(function (response) {
      return response.json().then(function (data) {
        if (response.ok) {
          window.location = data.status_url;
        } else {
          showError(data.error || "The build could not be queued.");
          button.disabled = false;
        }
      });
    }).catch(function () {
      showError("Could not reach the server - try again.");
      button.disabled = false;
    });
  });
})();
