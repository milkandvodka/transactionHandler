const requestIdInput = document.querySelector("#request-id");
const transactionForm = document.querySelector("#transaction-form");
const transactionOutput = document.querySelector("#transaction-output");
const summaryUserInput = document.querySelector("#summary-user");
const summaryOutput = document.querySelector("#summary-output");
const rankingBody = document.querySelector("#ranking-body");
const rankingFormula = document.querySelector("#ranking-formula");

function newRequestId() {
  const bytes = new Uint32Array(2);
  crypto.getRandomValues(bytes);
  return `req_${Date.now()}_${bytes[0].toString(16)}${bytes[1].toString(16)}`;
}

function writeJson(element, data) {
  element.textContent = JSON.stringify(data, null, 2);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { detail: text || "Unexpected response from server." };
  }
  if (!response.ok) {
    throw data;
  }
  return data;
}

async function submitTransaction() {
  const payload = {
    request_id: requestIdInput.value,
    user_id: document.querySelector("#tx-user").value,
    amount: document.querySelector("#amount").value,
    transaction_type: document.querySelector("#transaction-type").value,
  };

  try {
    const data = await api("/transaction", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    writeJson(transactionOutput, data);
    summaryUserInput.value = payload.user_id;
    await loadSummary();
    await loadRanking();
  } catch (error) {
    writeJson(transactionOutput, error);
  }
}

async function loadSummary() {
  const userId = summaryUserInput.value.trim();
  try {
    const data = await api(`/summary/${encodeURIComponent(userId)}`);
    writeJson(summaryOutput, data);
  } catch (error) {
    writeJson(summaryOutput, error);
  }
}

async function loadRanking() {
  const limit = document.querySelector("#ranking-limit").value || "10";
  try {
    const data = await api(`/ranking?limit=${encodeURIComponent(limit)}`);
    rankingBody.innerHTML = "";
    rankingFormula.textContent = data.formula || "";

    if (!data.items.length) {
      rankingBody.innerHTML = '<tr><td colspan="7">No ranked users yet.</td></tr>';
      return;
    }

    for (const item of data.items) {
      const row = document.createElement("tr");
      row.innerHTML = `
        <td>${item.rank}</td>
        <td>${item.user_id}</td>
        <td>${item.score}</td>
        <td>${item.points}</td>
        <td>${item.transaction_count}</td>
        <td>${item.total_amount}</td>
        <td>${item.abuse_penalty}</td>
      `;
      rankingBody.appendChild(row);
    }
  } catch (error) {
    rankingBody.innerHTML = `<tr><td colspan="7">${error.detail || "Could not load ranking."}</td></tr>`;
  }
}

document.querySelector("#new-request").addEventListener("click", () => {
  requestIdInput.value = newRequestId();
});

document.querySelector("#submit-duplicate").addEventListener("click", submitTransaction);
document.querySelector("#load-summary").addEventListener("click", loadSummary);
document.querySelector("#load-ranking").addEventListener("click", loadRanking);

transactionForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  await submitTransaction();
});

requestIdInput.value = newRequestId();
loadRanking();
