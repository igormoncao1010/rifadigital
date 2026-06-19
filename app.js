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
  raffles: [],
  currentRaffleId: window.RIFA_CONFIG?.raffleId || null,
  dashboard: null,
  adminDashboard: null,
  lastGenerated: [],
};

const authScreen = document.querySelector("#auth-screen");
const mainApp = document.querySelector("#main-app");
const loginForm = document.querySelector("#login-form");
const issueForm = document.querySelector("#issue-form");
const validateForm = document.querySelector("#validate-form");
const sellerForm = document.querySelector("#seller-form");
const raffleCreateForm = document.querySelector("#raffle-create-form");
const raffleSettingsForm = document.querySelector("#raffle-settings-form");
const voucherSearchForm = document.querySelector("#voucher-search-form");
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

function isAdmin() {
  return ["owner", "admin"].includes(state.seller?.role);
}

function setActiveTab(panelId) {
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.tab === panelId);
  });
  document.querySelectorAll(".panel").forEach((panel) => {
    panel.classList.toggle("active", panel.id === panelId);
  });
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
  await loadRaffles();
  authScreen.classList.add("hidden");
  mainApp.classList.remove("hidden");
  if (isAdmin()) {
    setActiveTab("admin-control-panel");
  }
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
    throw new Error("Vendedor sem acesso ativo. Peca liberacao ao dono da rifa.");
  }

  state.seller = data;
  document.querySelector("#seller-name").textContent = data.name;
  document.querySelector("#seller-role").textContent = data.role;
  document.querySelector("#main-title").textContent = isAdmin() ? "Painel de controle ADM" : "Emissao e ranking";
  document.querySelectorAll(".admin-only").forEach((element) => {
    element.classList.toggle("hidden", !isAdmin());
  });
}

async function loadRaffles() {
  const raffles = await callRpc("list_raffles", {});
  state.raffles = raffles;

  if (!state.currentRaffleId || !raffles.some((raffle) => raffle.id === state.currentRaffleId)) {
    state.currentRaffleId = raffles[0]?.id || null;
  }

  renderRaffleList();
}

function currentRaffle() {
  return state.raffles.find((raffle) => raffle.id === state.currentRaffleId) || null;
}

function renderRaffleList() {
  const list = document.querySelector("#raffle-list");
  if (!state.raffles.length) {
    list.innerHTML = '<div class="empty-state">Nenhuma rifa ativa cadastrada.</div>';
    return;
  }

  list.innerHTML = state.raffles
    .map((raffle) => {
      const available = Number(raffle.total_numbers || 0) - Number(raffle.reserved_count || 0);
      const image = raffle.image_url
        ? `<img src="${escapeHtml(raffle.image_url)}" alt="${escapeHtml(raffle.name)}" />`
        : '<div class="raffle-image-placeholder">RIFA</div>';
      return `
        <button class="raffle-card ${raffle.id === state.currentRaffleId ? "active" : ""}" data-raffle-id="${escapeHtml(
          raffle.id,
        )}" type="button">
          ${image}
          <span>
            <strong>${escapeHtml(raffle.name)}</strong>
            <small>${escapeHtml(raffle.prize_description || "Premio nao informado")}</small>
            <em>${available.toLocaleString("pt-BR")} livres - ${formatCurrency(raffle.ticket_price)}</em>
          </span>
        </button>
      `;
    })
    .join("");

  document.querySelectorAll("[data-raffle-id]").forEach((button) => {
    button.addEventListener("click", async () => {
      state.currentRaffleId = button.dataset.raffleId;
      state.lastGenerated = [];
      renderRaffleList();
      await renderGeneratedVouchers();
      await refreshDashboard();
      showToast("Rifa selecionada.");
    });
  });
}

async function refreshDashboard() {
  const dashboard = await callRpc("get_raffle_dashboard", {
    p_raffle_id: state.currentRaffleId,
  });

  state.dashboard = dashboard;
  const sellerRow = dashboard.ranking.find((row) => row.seller_id === state.seller.id);
  const available = dashboard.total_numbers - (dashboard.reserved_count ?? dashboard.issued_count);

  document.querySelector("#available-count").textContent = available.toLocaleString("pt-BR");
  document.querySelector("#issued-count").textContent = dashboard.issued_count.toLocaleString("pt-BR");
  document.querySelector("#revenue-total").textContent = formatCurrency(dashboard.revenue_total);
  document.querySelector("#seller-sales-count").textContent = `${sellerRow?.tickets_sold || 0} numeros`;
  document.querySelector("#seller-position").textContent = sellerRow ? `${sellerRow.position}o` : "-";
  document.querySelector("#ticket-price").value = formatCurrency(dashboard.ticket_price || appConfig.ticketPrice);
  document.querySelector("#main-title").textContent = currentRaffle()?.name || (isAdmin() ? "Painel de controle ADM" : "Emissao e ranking");

  renderRanking(dashboard.ranking);
  await renderRecords();
  if (isAdmin()) {
    await renderSellers();
    await renderAdminDashboard();
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
  const data = await callRpc("search_reprint_vouchers", {
    p_raffle_id: state.currentRaffleId,
    p_query: document.querySelector("#voucher-search")?.value.trim() || "",
  });

  document.querySelector("#records-table").innerHTML =
    data
      .map(
        (row, index) => `
          <tr class="clickable-row" data-voucher-index="${index}">
            <td>${formatLuckyNumber(row.ticket_number)}</td>
            <td>${escapeHtml(row.customer_name)}</td>
            <td>${escapeHtml(row.customer_cpf)}</td>
            <td>${escapeHtml(row.seller_name)}</td>
            <td>${new Date(row.created_at).toLocaleString("pt-BR")}</td>
            <td>${escapeHtml(row.status)}</td>
          </tr>
        `,
      )
      .join("") || '<tr><td colspan="6">Nenhum voucher encontrado.</td></tr>';

  document.querySelectorAll("[data-voucher-index]").forEach((row) => {
    row.addEventListener("click", async () => {
      const voucher = data[Number(row.dataset.voucherIndex)];
      const saleVouchers = data.filter((item) => item.sale_id === voucher.sale_id);
      state.lastGenerated = saleVouchers.length ? saleVouchers : [voucher];
      await renderGeneratedVouchers();
      setActiveTab("issue-panel");
      showToast(`${state.lastGenerated.length} voucher(es) carregado(s) para reimpressao.`);
    });
  });
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

async function renderAdminDashboard() {
  if (!isAdmin()) {
    return;
  }

  const data = await callRpc("get_admin_dashboard", {
    p_raffle_id: state.currentRaffleId,
  });
  state.adminDashboard = data;

  document.querySelector("#admin-revenue").textContent = formatCurrency(data.revenue_total);
  document.querySelector("#admin-issued").textContent = Number(data.issued_count || 0).toLocaleString("pt-BR");
  document.querySelector("#admin-available").textContent = Number(data.available_count || 0).toLocaleString("pt-BR");
  document.querySelector("#admin-customers").textContent = Number(data.customer_count || 0).toLocaleString("pt-BR");
  fillRaffleSettings();

  document.querySelector("#admin-seller-performance").innerHTML =
    data.sellers
      .map(
        (seller) => `
          <article class="ranking-row">
            <strong>${seller.position}o</strong>
            <div>
              <h3>${escapeHtml(seller.seller_name)}</h3>
              <p>${Number(seller.sales_count || 0).toLocaleString("pt-BR")} vendas - ${Number(
                seller.tickets_sold || 0,
              ).toLocaleString("pt-BR")} numeros</p>
            </div>
            <span>${formatCurrency(seller.revenue)}</span>
          </article>
        `,
      )
      .join("") || '<div class="empty-state">Nenhum vendedor com venda ainda.</div>';

  document.querySelector("#marketing-contacts").innerHTML =
    data.contacts
      .map(
        (contact) => `
          <article class="contact-row">
            <div>
              <h3>${escapeHtml(contact.name)}</h3>
              <p>${escapeHtml(contact.email)} - ${escapeHtml(contact.phone)}</p>
            </div>
            <div class="row-actions">
              <span>${Number(contact.purchases || 0)} compra(s)</span>
              <button class="button tiny" data-optout-customer="${escapeHtml(contact.customer_id)}" type="button">Remover marketing</button>
            </div>
          </article>
        `,
      )
      .join("") || '<div class="empty-state">Nenhum contato autorizado ainda.</div>';

  document.querySelector("#admin-sales-table").innerHTML =
    data.recent_sales
      .map(
        (sale) => `
          <tr>
            <td>${new Date(sale.created_at).toLocaleString("pt-BR")}</td>
            <td>${escapeHtml(sale.seller_name)}</td>
            <td>${escapeHtml(sale.customer_name)}</td>
            <td>${escapeHtml(sale.customer_email)}<br />${escapeHtml(sale.customer_phone)}</td>
            <td>${Number(sale.quantity || 0).toLocaleString("pt-BR")}</td>
            <td>${formatCurrency(sale.total_amount)}</td>
            <td>${escapeHtml(sale.status)}</td>
            <td>
              ${
                sale.status === "cancelled"
                  ? "-"
                  : `<button class="button tiny danger" data-cancel-sale="${escapeHtml(sale.id)}" type="button">Cancelar</button>`
              }
            </td>
          </tr>
        `,
      )
      .join("") || '<tr><td colspan="8">Nenhuma venda registrada ainda.</td></tr>';

  document.querySelectorAll("[data-cancel-sale]").forEach((button) => {
    button.addEventListener("click", async () => {
      const reason = prompt("Motivo do cancelamento:");
      if (!reason) {
        return;
      }

      try {
        await callRpc("cancel_sale", {
          p_sale_id: button.dataset.cancelSale,
          p_reason: reason,
        });
        await refreshDashboard();
        showToast("Venda cancelada.");
      } catch (error) {
        showToast(error.message);
      }
    });
  });

  document.querySelectorAll("[data-optout-customer]").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        await callRpc("set_customer_marketing_consent", {
          p_customer_id: button.dataset.optoutCustomer,
          p_consent: false,
        });
        await renderAdminDashboard();
        showToast("Contato removido das campanhas.");
      } catch (error) {
        showToast(error.message);
      }
    });
  });
}

function exportMarketingContacts() {
  const contacts = state.adminDashboard?.contacts || [];
  if (!contacts.length) {
    showToast("Nao ha contatos autorizados para exportar.");
    return;
  }

  downloadCsv("contatos-marketing-rifa.csv", [
    ["nome", "email", "telefone", "cpf", "compras"],
    ...contacts.map((contact) => [contact.name, contact.email, contact.phone, contact.cpf, String(contact.purchases || 0)]),
  ]);
}

function downloadCsv(filename, rows) {
  const csv = rows
    .map((row) => row.map((cell) => `"${String(cell ?? "").replace(/"/g, '""')}"`).join(","))
    .join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}

function downloadJson(filename, data) {
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}

function fillRaffleSettings() {
  const raffle = state.adminDashboard?.raffle;
  if (!raffle) {
    return;
  }

  document.querySelector("#raffle-name").value = raffle.name || "";
  document.querySelector("#raffle-image").value = raffle.image_url || "";
  document.querySelector("#raffle-prize").value = raffle.prize_description || "";
  document.querySelector("#raffle-draw-date").value = raffle.draw_date || "";
  document.querySelector("#raffle-ticket-price").value = Number(raffle.ticket_price || 0).toFixed(2);
  document.querySelector("#raffle-total-numbers").value = raffle.total_numbers || "";
  document.querySelector("#raffle-privacy-text").value = raffle.privacy_text || "";
}

function exportRanking() {
  const sellers = state.adminDashboard?.sellers || [];
  downloadCsv("ranking-vendedores.csv", [
    ["posicao", "vendedor", "vendas", "numeros", "faturamento"],
    ...sellers.map((seller) => [
      seller.position,
      seller.seller_name,
      seller.sales_count || 0,
      seller.tickets_sold || 0,
      seller.revenue || 0,
    ]),
  ]);
}

function exportSales() {
  const sales = state.adminDashboard?.recent_sales || [];
  downloadCsv("vendas-rifa.csv", [
    ["data", "vendedor", "cliente", "email", "telefone", "cpf", "quantidade", "total", "status"],
    ...sales.map((sale) => [
      sale.created_at,
      sale.seller_name,
      sale.customer_name,
      sale.customer_email,
      sale.customer_phone,
      sale.customer_cpf,
      sale.quantity || 0,
      sale.total_amount || 0,
      sale.status,
    ]),
  ]);
}

function updatePurchaseTotal() {
  const quantity = Number(quantityInput.value || 0);
  const price = state.dashboard?.ticket_price || appConfig.ticketPrice;
  document.querySelector("#purchase-total").textContent = formatCurrency(quantity * price);
}

async function makeQrDataUrl(token) {
  if (window.QRCode?.toDataURL) {
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

  if (window.qrcode) {
    const qr = window.qrcode(0, "M");
    qr.addData(token);
    qr.make();
    const svg = qr.createSvgTag({ cellSize: 6, margin: 1 });
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  }

  return makeFallbackCodeDataUrl(token);
}

function makeFallbackCodeDataUrl(token) {
  const size = 33;
  const cell = 7;
  const quiet = 4;
  const canvas = document.createElement("canvas");
  canvas.width = (size + quiet * 2) * cell;
  canvas.height = canvas.width;
  const context = canvas.getContext("2d");

  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#111111";

  const bits = [...token].map((char) => char.charCodeAt(0).toString(2).padStart(8, "0")).join("");

  function drawFinder(x, y) {
    context.fillRect((x + quiet) * cell, (y + quiet) * cell, 7 * cell, 7 * cell);
    context.fillStyle = "#ffffff";
    context.fillRect((x + quiet + 1) * cell, (y + quiet + 1) * cell, 5 * cell, 5 * cell);
    context.fillStyle = "#111111";
    context.fillRect((x + quiet + 2) * cell, (y + quiet + 2) * cell, 3 * cell, 3 * cell);
  }

  drawFinder(0, 0);
  drawFinder(size - 7, 0);
  drawFinder(0, size - 7);

  let index = 0;
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const inFinder =
        (x < 8 && y < 8) ||
        (x >= size - 8 && y < 8) ||
        (x < 8 && y >= size - 8);
      if (inFinder) {
        continue;
      }

      const bit = bits[index % bits.length] === "1";
      const mask = (x * 7 + y * 11 + index) % 5 === 0;
      if (bit !== mask) {
        context.fillRect((x + quiet) * cell, (y + quiet) * cell, cell, cell);
      }
      index += 1;
    }
  }

  return canvas.toDataURL("image/png");
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
    if (isAdmin()) {
      setActiveTab("admin-control-panel");
    }
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
    marketing_consent: document.querySelector("#marketing-consent").checked,
  };

  if (!customer.name || !customer.phone || !customer.email || onlyDigits(customer.cpf).length !== 11) {
    showToast("Preencha nome, telefone, email e CPF valido.");
    return;
  }

  try {
    issueForm.querySelector("button[type='submit']").disabled = true;
    const vouchers = await callRpc("issue_vouchers", {
      p_raffle_id: state.currentRaffleId,
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
    await renderAdminDashboard();
    showToast("Vendedor cadastrado.");
  } catch (error) {
    showToast(error.message);
  }
});

raffleCreateForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  try {
    const raffle = await callRpc("create_raffle", {
      p_name: document.querySelector("#new-raffle-name").value.trim(),
      p_image_url: document.querySelector("#new-raffle-image").value.trim(),
      p_prize_description: document.querySelector("#new-raffle-prize").value.trim(),
      p_total_numbers: Number(document.querySelector("#new-raffle-total").value || 0),
      p_ticket_price: Number(document.querySelector("#new-raffle-price").value || 0),
      p_draw_date: document.querySelector("#new-raffle-date").value || null,
    });
    raffleCreateForm.reset();
    state.currentRaffleId = raffle.id;
    await loadRaffles();
    await refreshDashboard();
    showToast("Rifa criada e selecionada.");
  } catch (error) {
    showToast(error.message);
  }
});

raffleSettingsForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  try {
    await callRpc("update_raffle_settings", {
      p_raffle_id: state.currentRaffleId,
      p_name: document.querySelector("#raffle-name").value.trim(),
      p_image_url: document.querySelector("#raffle-image").value.trim(),
      p_prize_description: document.querySelector("#raffle-prize").value.trim(),
      p_draw_date: document.querySelector("#raffle-draw-date").value || null,
      p_ticket_price: Number(document.querySelector("#raffle-ticket-price").value || 0),
      p_total_numbers: Number(document.querySelector("#raffle-total-numbers").value || 0),
      p_privacy_text: document.querySelector("#raffle-privacy-text").value.trim(),
    });
    await loadRaffles();
    await refreshDashboard();
    showToast("Configuracoes salvas.");
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

document.querySelector("#refresh-raffles").addEventListener("click", async () => {
  try {
    await loadRaffles();
    await refreshDashboard();
    showToast("Rifas atualizadas.");
  } catch (error) {
    showToast(error.message);
  }
});

voucherSearchForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await renderRecords();
    showToast("Busca concluida.");
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector("#clear-voucher-search").addEventListener("click", async () => {
  document.querySelector("#voucher-search").value = "";
  try {
    await renderRecords();
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector("#refresh-admin-dashboard").addEventListener("click", async () => {
  try {
    await renderAdminDashboard();
    showToast("Painel ADM atualizado.");
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector("#export-contacts").addEventListener("click", exportMarketingContacts);
document.querySelector("#export-contacts-panel").addEventListener("click", exportMarketingContacts);
document.querySelector("#export-ranking").addEventListener("click", exportRanking);
document.querySelector("#export-sales").addEventListener("click", exportSales);
document.querySelector("#export-backup").addEventListener("click", async () => {
  try {
    const backup = await callRpc("get_backup_snapshot", {
      p_raffle_id: state.currentRaffleId,
    });
    downloadJson(`backup-rifa-${new Date().toISOString().slice(0, 10)}.json`, backup);
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
    setActiveTab(button.dataset.tab);
  });
});

document.querySelector("#ticket-price").value = formatCurrency(appConfig.ticketPrice);
updatePurchaseTotal();
renderGeneratedVouchers();
loadSession().catch((error) => showToast(error.message));
