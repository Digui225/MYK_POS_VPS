HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>__TITLE__</title>
  <style>
    :root {
      --bg-main: #0f172a;
      --bg-card: #1e293b;
      --bg-input: #0b132b;
      --border: #334155;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #38bdf8;
      --get: #10b981;
      --post: #3b82f6;
      --patch: #8b5cf6;
      --delete: #ef4444;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background-color: var(--bg-main); color: var(--text); display: flex; height: 100vh; overflow: hidden; }
    #sidebar { width: 340px; background: #0b1120; border-right: 1px solid var(--border); display: flex; flex-direction: column; }
    .header-brand { padding: 20px 16px 12px; border-bottom: 1px solid var(--border); }
    .header-brand h1 { font-size: 18px; font-weight: 700; color: #fff; display: flex; align-items: center; gap: 8px; }
    .header-brand .badge { font-size: 11px; background: rgba(56, 189, 248, 0.2); color: var(--accent); padding: 2px 8px; border-radius: 9999px; font-weight: 600; }
    .search-box { padding: 12px 16px; border-bottom: 1px solid var(--border); }
    .search-box input { width: 100%; background: var(--bg-input); border: 1px solid var(--border); border-radius: 6px; padding: 8px 12px; color: #fff; font-size: 13px; outline: none; }
    .search-box input:focus { border-color: var(--accent); }
    .nav-items { flex: 1; overflow-y: auto; padding: 12px 8px; }
    .nav-group-title { font-size: 11px; text-transform: uppercase; color: var(--text-muted); font-weight: 700; padding: 12px 8px 6px; letter-spacing: 0.5px; }
    .nav-item { display: flex; align-items: center; gap: 8px; padding: 8px; border-radius: 6px; font-size: 13px; color: var(--text); text-decoration: none; cursor: pointer; transition: background 0.15s; margin-bottom: 2px; }
    .nav-item:hover, .nav-item.active { background: rgba(56, 189, 248, 0.1); color: #fff; }
    .method-badge { font-size: 10px; font-weight: 800; padding: 2px 6px; border-radius: 4px; color: #fff; min-width: 44px; text-align: center; }
    .m-get { background: var(--get); }
    .m-post { background: var(--post); }
    .m-patch { background: var(--patch); }
    .m-delete { background: var(--delete); }

    #main-content { flex: 1; overflow-y: auto; display: flex; flex-direction: column; }
    .topbar { padding: 12px 24px; border-bottom: 1px solid var(--border); background: #0b1120; display: flex; align-items: center; justify-content: space-between; }
    .auth-input { display: flex; align-items: center; gap: 10px; }
    .auth-input input { background: var(--bg-input); border: 1px solid var(--border); border-radius: 6px; padding: 6px 12px; color: #fff; font-size: 12px; width: 320px; outline: none; }
    .auth-input button { background: var(--accent); color: #000; border: none; font-weight: 600; padding: 6px 14px; border-radius: 6px; font-size: 12px; cursor: pointer; }

    .content-body { padding: 32px 40px; max-width: 1000px; }
    .endpoint-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 24px; margin-bottom: 24px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.2); }
    .endpoint-header { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }
    .endpoint-path { font-size: 18px; font-weight: 700; font-family: monospace; }
    .endpoint-summary { font-size: 15px; color: var(--text-muted); margin-bottom: 20px; }

    .section-title { font-size: 13px; font-weight: 700; text-transform: uppercase; color: var(--text-muted); margin: 16px 0 8px; }
    .param-table { width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 13px; }
    .param-table th, .param-table td { padding: 8px 12px; text-align: left; border-bottom: 1px solid var(--border); }
    .param-table th { color: var(--text-muted); font-size: 11px; }
    .param-name { font-weight: 600; color: var(--accent); font-family: monospace; }

    .body-editor { width: 100%; height: 140px; background: var(--bg-input); border: 1px solid var(--border); border-radius: 6px; color: #38bdf8; font-family: monospace; font-size: 13px; padding: 12px; outline: none; resize: vertical; }
    .execute-btn { background: var(--get); color: #fff; border: none; font-size: 14px; font-weight: 700; padding: 10px 20px; border-radius: 6px; cursor: pointer; margin-top: 16px; transition: opacity 0.15s; }
    .execute-btn:hover { opacity: 0.9; }
    .response-area { margin-top: 20px; border-top: 1px solid var(--border); padding-top: 16px; display: none; }
    .response-status { font-weight: 700; font-size: 14px; margin-bottom: 8px; }
    .response-status.s-2xx { color: var(--get); }
    .response-status.s-4xx { color: var(--delete); }
    .response-body { background: var(--bg-input); border: 1px solid var(--border); border-radius: 6px; padding: 12px; font-family: monospace; font-size: 13px; color: #cbd5e1; overflow-x: auto; max-height: 350px; white-space: pre-wrap; }
  </style>
</head>
<body>

  <!-- Barre latérale -->
  <div id="sidebar">
    <div class="header-brand">
      <h1>OsisPos <span class="badge">v1.0</span></h1>
      <p style="font-size: 12px; color: var(--text-muted); margin-top: 4px;">Point de Vente & API FNE</p>
    </div>
    <div class="search-box">
      <input type="text" id="searchInput" placeholder="Filtrer les endpoints..." oninput="filterEndpoints()">
    </div>
    <div class="nav-items" id="navItems">
      <div style="padding: 16px; color: var(--text-muted); font-size: 13px;">Chargement des routes...</div>
    </div>
  </div>

  <!-- Contenu Principal -->
  <div id="main-content">
    <div class="topbar">
      <div style="font-size: 13px; color: var(--text-muted);">
        Serveur local : <strong style="color: #fff;">http://127.0.0.1:8001</strong>
      </div>
      <div class="auth-input">
        <input type="text" id="authToken" placeholder="Bearer JWT ou Token d'accès...">
        <button onclick="setAuthToken()">Appliquer</button>
      </div>
    </div>

    <div class="content-body" id="endpointsContainer">
      <!-- Rendu dynamique des cartes endpoints -->
    </div>
  </div>

  <script>
    let spec = null;
    let token = localStorage.getItem("caisse_api_token") || "";
    if (token) document.getElementById("authToken").value = token;

    function setAuthToken() {
      token = document.getElementById("authToken").value.trim();
      localStorage.setItem("caisse_api_token", token);
      alert(token ? "Token appliqué pour toutes les requêtes !" : "Token réinitialisé.");
    }

    async function loadSpec() {
      try {
        const res = await fetch("/openapi.json");
        spec = await res.json();
        renderNav();
        renderAllEndpoints();
      } catch (err) {
        document.getElementById("endpointsContainer").innerHTML = `
          <div style="color: #ef4444; padding: 24px; background: rgba(239, 68, 68, 0.1); border-radius: 8px;">
            Erreur de chargement du schéma OpenAPI: ${err.message}
          </div>
        `;
      }
    }

    function renderNav() {
      const nav = document.getElementById("navItems");
      nav.innerHTML = "";

      const tags = {};
      for (const [path, methods] of Object.entries(spec.paths)) {
        for (const [method, op] of Object.entries(methods)) {
          const tag = (op.tags && op.tags[0]) || "Autres";
          if (!tags[tag]) tags[tag] = [];
          tags[tag].push({ path, method: method.toUpperCase(), op });
        }
      }

      for (const [tag, items] of Object.entries(tags)) {
        const groupTitle = document.createElement("div");
        groupTitle.className = "nav-group-title";
        groupTitle.textContent = tag;
        nav.appendChild(groupTitle);

        items.forEach((item) => {
          const el = document.createElement("a");
          el.className = "nav-item";
          el.href = `#${item.method}-${item.path}`;
          el.dataset.filter = `${item.method} ${item.path} ${item.op.summary || ""}`.toLowerCase();
          el.innerHTML = `
            <span class="method-badge m-${item.method.toLowerCase()}">${item.method}</span>
            <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">${item.op.summary || item.path}</span>
          `;
          nav.appendChild(el);
        });
      }
    }

    function renderAllEndpoints() {
      const container = document.getElementById("endpointsContainer");
      container.innerHTML = "";

      for (const [path, methods] of Object.entries(spec.paths)) {
        for (const [method, op] of Object.entries(methods)) {
          const m = method.toUpperCase();
          const cardId = `${m}-${path}`;

          const card = document.createElement("div");
          card.className = "endpoint-card";
          card.id = cardId;

          let bodyTemplate = "";
          if (op.requestBody && op.requestBody.content && op.requestBody.content["application/json"]) {
            const schemaRef = op.requestBody.content["application/json"].schema;
            bodyTemplate = JSON.stringify(generateSampleFromSchema(schemaRef), null, 2);
          }

          card.innerHTML = `
            <div class="endpoint-header">
              <span class="method-badge m-${method.toLowerCase()}" style="font-size: 13px; padding: 4px 10px;">${m}</span>
              <span class="endpoint-path">${path}</span>
            </div>
            <div class="endpoint-summary">${op.summary || ""}</div>

            ${op.parameters && op.parameters.length ? `
              <div class="section-title">Paramètres</div>
              <table class="param-table">
                <thead><tr><th>Nom</th><th>Type</th><th>Requis</th><th>Description</th></tr></thead>
                <tbody>
                  ${op.parameters.map(p => `
                    <tr>
                      <td class="param-name">${p.name}</td>
                      <td>${p.in}</td>
                      <td>${p.required ? '<span style="color:#ef4444;">Oui</span>' : 'Non'}</td>
                      <td style="color:var(--text-muted);">${p.description || '-'}</td>
                    </tr>
                  `).join('')}
                </tbody>
              </table>
            ` : ''}

            ${bodyTemplate ? `
              <div class="section-title">Corps de requête (JSON)</div>
              <textarea class="body-editor" id="body-${cardId}">${bodyTemplate}</textarea>
            ` : ''}

            <button class="execute-btn" onclick="executeRequest('${m}', '${path}', '${cardId}')">
              Tester la requête
            </button>

            <div class="response-area" id="res-area-${cardId}">
              <div class="response-status" id="res-status-${cardId}"></div>
              <pre class="response-body" id="res-body-${cardId}"></pre>
            </div>
          `;
          container.appendChild(card);
        }
      }
    }

    function generateSampleFromSchema(schema) {
      if (!schema) return {};
      if (schema.$ref) {
        const refName = schema.$ref.replace('#/components/schemas/', '');
        const target = spec.components.schemas[refName];
        return generateSampleFromSchema(target);
      }
      if (schema.type === 'object' && schema.properties) {
        const sample = {};
        for (const [k, prop] of Object.entries(schema.properties)) {
          if (prop.default !== undefined) sample[k] = prop.default;
          else if (prop.type === 'string') sample[k] = prop.enum ? prop.enum[0] : (k.includes('date') ? '2026-09-28' : 'test');
          else if (prop.type === 'integer' || prop.type === 'number') sample[k] = prop.minimum || 1000;
          else if (prop.type === 'boolean') sample[k] = true;
          else sample[k] = null;
        }
        return sample;
      }
      return {};
    }

    async function executeRequest(method, path, cardId) {
      const resArea = document.getElementById(`res-area-${cardId}`);
      const statusEl = document.getElementById(`res-status-${cardId}`);
      const bodyEl = document.getElementById(`res-body-${cardId}`);

      resArea.style.display = "block";
      statusEl.textContent = "Exécution...";
      statusEl.className = "response-status";
      bodyEl.textContent = "";

      let resolvedPath = path;
      const bodyTextarea = document.getElementById(`body-${cardId}`);
      let bodyData = undefined;

      if (bodyTextarea && bodyTextarea.value.trim()) {
        bodyData = bodyTextarea.value.trim();
      }

      const matches = path.match(/\{([^}]+)\}/g);
      if (matches) {
        for (const m of matches) {
          const paramName = m.replace(/[{}]/g, '');
          const val = prompt(`Valeur pour le paramètre d'URL '${paramName}' :`, '1');
          if (val === null) return;
          resolvedPath = resolvedPath.replace(m, encodeURIComponent(val));
        }
      }

      const headers = {
        'Content-Type': 'application/json',
        'X-Device-Id': 'pos-browser-dev',
        'Idempotency-Key': 'web-idem-' + Date.now(),
      };
      if (token) headers['Authorization'] = token.startsWith('Bearer ') ? token : `Bearer ${token}`;

      try {
        const t0 = performance.now();
        const response = await fetch(resolvedPath, {
          method,
          headers,
          body: ['POST', 'PUT', 'PATCH'].includes(method) ? bodyData : undefined,
        });
        const duration = Math.round(performance.now() - t0);

        statusEl.textContent = `Status: ${response.status} ${response.statusText} (${duration}ms)`;
        statusEl.className = `response-status ${response.ok ? 's-2xx' : 's-4xx'}`;

        const contentType = response.headers.get('content-type');
        if (contentType && contentType.includes('application/json')) {
          const data = await response.json();
          bodyEl.textContent = JSON.stringify(data, null, 2);
        } else {
          bodyEl.textContent = await response.text();
        }
      } catch (err) {
        statusEl.textContent = "Erreur réseau";
        statusEl.className = "response-status s-4xx";
        bodyEl.textContent = err.message;
      }
    }

    function filterEndpoints() {
      const query = document.getElementById("searchInput").value.toLowerCase();
      const items = document.querySelectorAll(".nav-item");
      items.forEach(el => {
        el.style.display = el.dataset.filter.includes(query) ? "flex" : "none";
      });
    }

    loadSpec();
  </script>
</body>
</html>
"""


def get_offline_docs_html(title: str = "OsisPos - Documentation API") -> str:
    """Retourne une interface de documentation interactive ultra-rapide 100% autonome et hors-ligne."""
    return HTML_TEMPLATE.replace("__TITLE__", title)
