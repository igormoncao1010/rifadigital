const appConfig = {
  raffleId: window.RIFA_CONFIG?.raffleId || null,
  ticketPrice: Number(window.RIFA_CONFIG?.ticketPrice || 5),
  totalNumbers: Number(window.RIFA_CONFIG?.totalNumbers || 100000),
};

const supabaseConfig = window.SUPABASE_CONFIG || {};
const hasSupabaseConfig =
  Boolean(supabaseConfig.url) &&
  Boolean(supabaseConfig.anonKey) &&
  !supabaseConfig.url.includes("COLE_AQUI") &&
  !supabaseConfig.anonKey.includes("COLE_AQUI");

const db = hasSupabaseConfig
  ? window.supabase.createClient(supabaseConfig.url, supabaseConfig.anonKey)
  : null;

const state = {
  session: null,
  seller: null,
  dashboard: null,
  lastGenerated: [],
};

const authScreen = document.querySelector("#auth-screen");
const mainApp = document.querySelector("#main-app");
const loginForm = document.querySelector("#login-form");
const issueForm = document.querySelector("#issue-form");
const validateForm = document.querySelector("#validate-form");
const sellerForm = document.querySelector("#seller-form");
const quantityInput = document.querySelector("#ticket-quantity");
const voucherOutput = document.querySelector("#voucher-output");
const printArea = document.querySelector("#print-area");
const toast = document.querySelector("#toast");

function showToast(message) {
  toast.textContent = message;
  toast.classList.add("show");
  window.clearTimeout(showToast.timeout);
  showToast.timeout = window.setTimeout(() => toast.classList.remove("show"), 3000);
}

function onlyDigits(value) {
  return value.replace(/\D/g, "");
}

function formatCpf(value) {
  const digits = onlyDigits(value).slice(0, 11);
  return digits.replace(/(\d{3})(\d{3})(\d{3})(\d{0,2})/, (_, a, b, c, d) =>
    d ? `${a}.${b}.${c}-${d}` : `${a}.${b}.${c}`,
  );
}

function formatLuckyNumber(number) {
  return String(number).padStart(6, "0");
}

function formatCurrency(value) {
  return Number(value || 0).toLocaleString("pt-BR", {
    style: "currency",
    currency: "BRL",
  });
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function requireConfig() {
  if (hasSupabaseConfig) {
    return true;
  }
  document.querySelector("#config-warning").textContent =
    "Configure config.js com SUPABASE_URL e SUPABASE_ANON_KEY antes de entrar.";
  return false;
}

async function callRpc(name, params = {}) {
  const { data, error } = await db.rpc(name, params);
  if (error) {
    throw error;
  }
  return data;
}

async function loadSession() {
  if (!requireConfig()) {
    authScreen.classList.remove("hidden");
    mainApp.classList.add("hidden");
    return;
  }

  const { data, error } = await db.auth.getSession();
  if (error) {
    showToast(error.message);
    return;
  }
  state.session = data.session;

  if (!state.session) {
    authScreen.classList.remove("hidden");
    mainApp.classList.add("hidden");
    return;
  }

  await loadSeller();
  authScreen.classList.add("hidden");
  mainApp.classList.remove("hidden");
  await refreshDashboard();
}

async function loadSeller() {
  const { data, error } = await db
    .from("sellers")
    .select("id, name, email, phone, role, active")
    .eq("user_id", state.session.user.id)
    .maybeSingle();

  if (error) {
    throw error;
  }

  if (!data || !data.active) {
    await db.auth.signOut();
    throw new Error("Vendedor sem acesso ativo. Peça liberacao ao dono da rifa.");
  }

  state.seller = data;
  document.querySelector("#seller-name").textContent = data.name;
  document.querySelector("#seller-role").textContent = data.role;
  document.querySelectorAll(".admin-only").forEach((element) => {
    element.classList.toggle("hidden", !["owner", "admin"].includes(data.role));
  });
}

async function refreshDashboard() {
  const dashboard = await callRpc("get_raffle_dashboard", {
    p_raffle_id: appConfig.raffleId,
  });

  state.dashboard = dashboard;
  const sellerRow = dashboard.ranking.find((row) => row.seller_id === state.seller.id);
  const available = dashboard.total_numbers - dashboard.issued_count;

  document.querySelector("#available-count").textContent = available.toLocaleString("pt-BR");
  document.querySelector("#issued-count").textContent = dashboard.issued_count.toLocaleString("pt-BR");
  document.querySelector("#revenue-total").textContent = formatCurrency(dashboard.revenue_total);
  document.querySelector("#seller-sales-count").textContent = `${sellerRow?.tickets_sold || 0} numeros`;
  document.querySelector("#seller-position").textContent = sellerRow ? `${sellerRow.position}o` : "-";
  document.querySelector("#ticket-price").value = formatCurrency(dashboard.ticket_price || appConfig.ticketPrice);

  renderRanking(dashboard.ranking);
  await renderRecords();
  if (["owner", "admin"].includes(state.seller.role)) {
    await renderSellers();
  }
  updatePurchaseTotal();
}

function renderRanking(rows) {
  const list = document.querySelector("#ranking-list");
  if (!rows.length) {
    list.innerHTML = '<div class="empty-state">Nenhuma venda registrada ainda.</div>';
    return;
  }

  list.innerHTML = rows
    .map(
      (row) => `
        <article class="ranking-row ${row.seller_id === state.seller.id ? "current" : ""}">
          <strong>${row.position}o</strong>
          <div>
            <h3>${escapeHtml(row.seller_name)}</h3>
            <p>${row.tickets_sold.toLocaleString("pt-BR")} numeros vendidos</p>
          </div>
          <span>${formatCurrency(row.revenue)}</span>
        </article>
      `,
    )
    .join("");
}

async function renderRecords() {
  const { data, error } = await db
    .from("voucher_history")
    .select("ticket_number, customer_name, seller_name, created_at, status")
    .order("created_at", { ascending: false })
    .limit(250);

  if (error) {
    throw error;
  }

  document.querySelector("#records-table").innerHTML =
    data
      .map(
        (row) => `
          <tr>
            <td>${formatLuckyNumber(row.ticket_number)}</td>
            <td>${escapeHtml(row.customer_name)}</td>
            <td>${escapeHtml(row.seller_name)}</td>
            <td>${new Date(row.created_at).toLocaleString("pt-BR")}</td>
            <td>${escapeHtml(row.status)}</td>
          </tr>
        `,
      )
      .join("") || '<tr><td colspan="5">Nenhum voucher emitido ainda.</td></tr>';
}

async function renderSellers() {
  const { data, error } = await db
    .from("sellers")
    .select("name, email, phone, role, active, created_at")
    .order("created_at", { ascending: false });

  if (error) {
    throw error;
  }

  document.querySelector("#seller-list").innerHTML =
    data
      .map(
        (seller) => `
          <article class="seller-row">
            <div>
              <h3>${escapeHtml(seller.name)}</h3>
              <p>${escapeHtml(seller.email)}${seller.phone ? ` - ${escapeHtml(seller.phone)}` : ""}</p>
            </div>
            <span>${seller.active ? seller.role : "inativo"}</span>
          </article>
        `,
      )
      .join("") || '<div class="empty-state">Nenhum vendedor cadastrado.</div>';
}

function updatePurchaseTotal() {
  const quantity = Number(quantityInput.value || 0);
  const price = state.dashboard?.ticket_price || appConfig.ticketPrice;
  document.querySelector("#purchase-total").textContent = formatCurrency(quantity * price);
}

async function makeQrDataUrl(token) {
  return window.QRCode.toDataURL(token, {
    errorCorrectionLevel: "M",
    margin: 1,
    width: 240,
    color: {
      dark: "#111111",
      light: "#ffffff",
    },
  });
}

async function voucherTemplate(voucher) {
  const qr = await makeQrDataUrl(voucher.token);
  const issuedAt = new Date(voucher.created_at).toLocaleString("pt-BR");

  return `
    <article class="voucher">
      <h3>Rifa Digital</h3>
      <p><strong>Voucher:</strong> ${escapeHtml(voucher.id)}</p>
      <div class="lucky-number">${formatLuckyNumber(voucher.ticket_number)}</div>
      <p><strong>Nome:</strong> ${escapeHtml(voucher.customer_name)}</p>
      <p><strong>Telefone:</strong> ${escapeHtml(voucher.customer_phone)}</p>
      <p><strong>Email:</strong> ${escapeHtml(voucher.customer_email)}</p>
      <p><strong>CPF:</strong> ${escapeHtml(voucher.customer_cpf)}</p>
      <p><strong>Vendedor:</strong> ${escapeHtml(voucher.seller_name)}</p>
      <p><strong>Emitido:</strong> ${issuedAt}</p>
      <img class="private-qr" src="${qr}" alt="QR Code de validacao" />
      <p class="voucher-code">${escapeHtml(voucher.token)}</p>
    </article>
  `;
}

async function renderGeneratedVouchers() {
  if (!state.lastGenerated.length) {
    voucherOutput.innerHTML = '<div class="empty-state">Os vouchers gerados aparecem aqui prontos para impressao.</div>';
    printArea.innerHTML = "";
    return;
  }

  const html = (await Promise.all(state.lastGenerated.map(voucherTemplate))).join("");
  voucherOutput.innerHTML = html;
  printArea.innerHTML = html;
}

loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!requireConfig()) {
    return;
  }

  const email = document.querySelector("#login-email").value.trim();
  const password = document.querySelector("#login-password").value;

  try {
    const { data, error } = await db.auth.signInWithPassword({ email, password });
    if (error) {
      throw error;
    }
    state.session = data.session;
    await loadSeller();
    authScreen.classList.add("hidden");
    mainApp.classList.remove("hidden");
    await refreshDashboard();
    showToast("Login realizado.");
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector("#logout-button").addEventListener("click", async () => {
  await db.auth.signOut();
  state.session = null;
  state.seller = null;
  state.lastGenerated = [];
  await renderGeneratedVouchers();
  authScreen.classList.remove("hidden");
  mainApp.classList.add("hidden");
});

issueForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const quantity = Number(quantityInput.value);

  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 100) {
    showToast("Informe uma quantidade entre 1 e 100 por venda.");
    return;
  }

  const customer = {
    name: document.querySelector("#buyer-name").value.trim(),
    phone: document.querySelector("#buyer-phone").value.trim(),
    email: document.querySelector("#buyer-email").value.trim(),
    cpf: formatCpf(document.querySelector("#buyer-cpf").value),
  };

  if (!customer.name || !customer.phone || !customer.email || onlyDigits(customer.cpf).length !== 11) {
    showToast("Preencha nome, telefone, email e CPF valido.");
    return;
  }

  try {
    issueForm.querySelector("button[type='submit']").disabled = true;
    const vouchers = await callRpc("issue_vouchers", {
      p_raffle_id: appConfig.raffleId,
      p_customer: customer,
      p_quantity: quantity,
    });
    state.lastGenerated = vouchers;
    await renderGeneratedVouchers();
    await refreshDashboard();
    issueForm.reset();
    quantityInput.value = 1;
    updatePurchaseTotal();
    showToast(`${vouchers.length} voucher(es) emitido(s).`);
  } catch (error) {
    showToast(error.message);
  } finally {
    issueForm.querySelector("button[type='submit']").disabled = false;
  }
});

validateForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const resultBox = document.querySelector("#validation-result");

  try {
    const result = await callRpc("validate_voucher_token", {
      p_token: document.querySelector("#validation-token").value.trim(),
    });

    if (!result.ok) {
      resultBox.innerHTML = `<h2 class="invalid">Invalido</h2><p>${escapeHtml(result.message)}</p>`;
      return;
    }

    resultBox.innerHTML = `
      <h2 class="valid">Validado</h2>
      <p>${escapeHtml(result.message)}</p>
      <div class="summary">
        <div><span>Numero da sorte</span><strong>${formatLuckyNumber(result.ticket_number)}</strong></div>
        <div><span>Cliente</span><strong>${escapeHtml(result.customer_name)}</strong></div>
        <div><span>Vendedor</span><strong>${escapeHtml(result.seller_name)}</strong></div>
      </div>
    `;
  } catch (error) {
    resultBox.innerHTML = `<h2 class="invalid">Invalido</h2><p>${escapeHtml(error.message)}</p>`;
  }
});

sellerForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  try {
    const { data, error } = await db.functions.invoke("admin-create-seller", {
      body: {
        name: document.querySelector("#new-seller-name").value.trim(),
        email: document.querySelector("#new-seller-email").value.trim(),
        password: document.querySelector("#new-seller-password").value,
        phone: document.querySelector("#new-seller-phone").value.trim(),
      },
    });

    if (error) {
      throw error;
    }
    if (data?.error) {
      throw new Error(data.error);
    }

    sellerForm.reset();
    await renderSellers();
    showToast("Vendedor cadastrado.");
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector("#print-vouchers").addEventListener("click", () => {
  if (!state.lastGenerated.length) {
    showToast("Gere vouchers antes de imprimir.");
    return;
  }
  window.print();
});

document.querySelector("#refresh-dashboard").addEventListener("click", async () => {
  try {
    await refreshDashboard();
    showToast("Painel atualizado.");
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector("#buyer-cpf").addEventListener("input", (event) => {
  event.target.value = formatCpf(event.target.value);
});

quantityInput.addEventListener("input", updatePurchaseTotal);

document.querySelectorAll(".tab").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((tab) => tab.classList.remove("active"));
    document.querySelectorAll(".panel").forEach((panel) => panel.classList.remove("active"));
    button.classList.add("active");
    document.querySelector(`#${button.dataset.tab}`).classList.add("active");
  });
});

document.querySelector("#ticket-price").value = formatCurrency(appConfig.ticketPrice);
updatePurchaseTotal();
renderGeneratedVouchers();
loadSession().catch((error) => showToast(error.message));
