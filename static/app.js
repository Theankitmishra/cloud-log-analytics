// =============================================================================
// Cloud Log Analytics & Anomaly Detection — Frontend Controller
// Author: Ankit Kumar Mishra (DTU M.Tech CS)
// =============================================================================

let streamEventCount = 0;
let volumeChartInstance = null;
const maxTerminalEntries = 75;

document.addEventListener('DOMContentLoaded', () => {
  initChart();
  initSSEStream();
  initPolling();
  initActionButtons();
});

// ─────────────────────────────────────────────────────────
// Chart.js Setup
// ─────────────────────────────────────────────────────────
function initChart() {
  const ctx = document.getElementById('volumeChart');
  if (!ctx) return;

  const labels = Array.from({ length: 12 }, (_, i) => `${(11 - i) * 15}s ago`);
  const volumeData = [18, 22, 25, 20, 24, 28, 30, 26, 32, 35, 40, 38];
  const errorData = [0, 1, 0, 1, 0, 2, 1, 0, 1, 40, 2, 1];

  volumeChartInstance = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        {
          label: 'Total Logs',
          data: volumeData,
          backgroundColor: 'rgba(56, 189, 248, 0.4)',
          borderColor: '#38bdf8',
          borderWidth: 1,
          borderRadius: 4,
          yAxisID: 'y'
        },
        {
          label: 'Errors / Spike',
          data: errorData,
          backgroundColor: 'rgba(244, 63, 94, 0.8)',
          borderColor: '#f43f5e',
          borderWidth: 1,
          borderRadius: 4,
          yAxisID: 'y'
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 400 },
      scales: {
        x: {
          grid: { color: 'rgba(255, 255, 255, 0.05)' },
          ticks: { color: '#64748b', font: { family: 'JetBrains Mono', size: 10 } }
        },
        y: {
          beginAtZero: true,
          grid: { color: 'rgba(255, 255, 255, 0.05)' },
          ticks: { color: '#64748b', font: { family: 'JetBrains Mono', size: 10 } }
        }
      },
      plugins: {
        legend: {
          labels: { color: '#94a3b8', font: { family: 'Plus Jakarta Sans', size: 11 } }
        }
      }
    }
  });
}

// ─────────────────────────────────────────────────────────
// Server-Sent Events (SSE) Live Log Stream
// ─────────────────────────────────────────────────────────
function initSSEStream() {
  const terminal = document.getElementById('logTerminal');
  const counter = document.getElementById('streamCounter');
  if (!terminal) return;

  const evtSource = new EventSource('/logs/stream');

  evtSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      streamEventCount++;
      if (counter) counter.textContent = `${streamEventCount} events streamed`;

      const entry = document.createElement('div');
      entry.className = 'log-entry';

      const timeStr = data.ts ? data.ts.substring(11, 19) : new Date().toTimeString().substring(0, 8);
      const lvl = data.level || 'INFO';
      const srv = data.service || 'unknown';
      const msg = data.message || '';
      const lat = data.latency_ms ? `${data.latency_ms}ms` : '';

      entry.innerHTML = `
        <span class="log-ts">${timeStr}</span>
        <span class="log-srv">${srv}</span>
        <span class="log-badge ${lvl}">${lvl}</span>
        <span class="log-msg">${escapeHtml(msg)}</span>
        <span class="log-lat">${lat}</span>
      `;

      terminal.appendChild(entry);
      terminal.scrollTop = terminal.scrollHeight;

      // Limit max terminal elements in memory
      while (terminal.children.length > maxTerminalEntries) {
        terminal.removeChild(terminal.children[1]);
      }
    } catch (err) {
      console.warn('SSE parse error:', err);
    }
  };

  evtSource.onerror = () => {
    console.info('SSE stream disconnected, auto-retrying...');
  };
}

// ─────────────────────────────────────────────────────────
// Real-Time Polling: Metrics & Anomalies
// ─────────────────────────────────────────────────────────
function initPolling() {
  fetchMetrics();
  fetchAnomalies();
  setInterval(fetchMetrics, 4000);
  setInterval(fetchAnomalies, 5000);
}

async function fetchMetrics() {
  try {
    const res = await fetch('/metrics/summary');
    if (!res.ok) return;
    const data = await res.json();

    // KPIs
    const elTotal = document.getElementById('kpiTotalEvents');
    const elError = document.getElementById('kpiErrorRate');
    const elBadge = document.getElementById('kpiErrorBadge');
    const elAnomalies = document.getElementById('kpiAnomalies');
    const elAvgLat = document.getElementById('kpiAvgLatency');
    const elP95 = document.getElementById('kpiP95');

    if (elTotal) elTotal.textContent = Number(data.total_events || 0).toLocaleString();
    if (elError) elError.textContent = `${(data.error_rate_pct || 0).toFixed(1)}%`;
    if (elAnomalies) elAnomalies.textContent = data.anomaly_count || 0;
    if (elAvgLat) elAvgLat.textContent = `${Math.round(data.avg_latency_ms || 0)} ms`;
    if (elP95) elP95.textContent = `p95: ${Math.round(data.p95_latency_ms || 0)} ms`;

    // Status Badge
    if (elBadge) {
      const rate = data.error_rate_pct || 0;
      elBadge.className = 'kpi-badge ' + (rate > 25 ? 'critical' : rate > 5 ? 'warning' : 'healthy');
      elBadge.textContent = rate > 25 ? 'CRITICAL' : rate > 5 ? 'WARNING' : 'HEALTHY';
    }

    // Service Matrix
    renderServiceMatrix(data.services || []);

    // Update Chart with live tick
    if (volumeChartInstance) {
      const dsVol = volumeChartInstance.data.datasets[0].data;
      const dsErr = volumeChartInstance.data.datasets[1].data;
      dsVol.shift();
      dsVol.push(Math.max(10, Math.round((data.total_events || 30) % 50) + Math.floor(Math.random() * 8)));
      dsErr.shift();
      dsErr.push(data.error_count > 0 ? Math.min(45, data.error_count) : (Math.random() > 0.8 ? 1 : 0));
      volumeChartInstance.update();
    }
  } catch (err) {
    console.warn('Metrics polling error:', err);
  }
}

function renderServiceMatrix(services) {
  const container = document.getElementById('serviceMatrix');
  if (!container) return;

  if (!services || services.length === 0) {
    services = [
      { service: 'auth-service', total: 45, errors: 0 },
      { service: 'api-gateway', total: 110, errors: 2 },
      { service: 'payment-api', total: 32, errors: 0 },
      { service: 'cache', total: 40, errors: 40 },
      { service: 'database', total: 68, errors: 1 },
      { service: 'worker', total: 54, errors: 0 }
    ];
  }

  container.innerHTML = services.map((s) => {
    const total = s.total || 0;
    const errors = s.errors || 0;
    const errRate = total > 0 ? (errors / total * 100) : 0;
    const statusClass = errRate > 25 ? 'red' : errRate > 5 ? 'amber' : 'green';

    return `
      <div class="matrix-tile ${statusClass}">
        <div class="tile-name">${s.service}</div>
        <div class="tile-events">${total} events</div>
        <div class="tile-err">${errRate.toFixed(1)}% err</div>
      </div>
    `;
  }).join('');
}

async function fetchAnomalies() {
  try {
    const res = await fetch('/anomalies?limit=6');
    if (!res.ok) return;
    const data = await res.json();
    const feed = document.getElementById('anomalyFeed');
    if (!feed) return;

    const items = data.items || [];
    if (items.length === 0) {
      feed.innerHTML = '<div class="anomaly-empty">No anomalies detected in the last evaluation window.</div>';
      return;
    }

    feed.innerHTML = items.map((a) => {
      const sev = a.severity || 'LOW';
      const srv = a.service || 'unknown';
      const score = typeof a.score === 'number' ? (a.score > 1 ? a.score : (a.score * 100).toFixed(1) + '%') : a.score;
      const desc = a.description || 'Isolation Forest anomaly detected';
      const ts = a.detected_at ? a.detected_at.substring(11, 19) : 'Just now';

      return `
        <div class="anomaly-card ${sev}">
          <div class="anomaly-header">
            <span class="anomaly-type">🚨 ${srv.toUpperCase()} · ${sev}</span>
            <span class="anomaly-score">${score}</span>
          </div>
          <div class="anomaly-desc">${escapeHtml(desc)}</div>
          <div class="anomaly-meta">
            <span>Algorithm: IsolationForest (n=100)</span>
            <span>${ts}</span>
          </div>
        </div>
      `;
    }).join('');
  } catch (err) {
    console.warn('Anomalies polling error:', err);
  }
}

// ─────────────────────────────────────────────────────────
// Simulator Action Buttons
// ─────────────────────────────────────────────────────────
function initActionButtons() {
  const btnNorm = document.getElementById('btnSimulateNormal');
  const btnAnom = document.getElementById('btnSimulateAnomaly');
  const btnClear = document.getElementById('btnClearStream');

  if (btnNorm) {
    btnNorm.addEventListener('click', async () => {
      btnNorm.disabled = true;
      try {
        await fetch('/simulate/normal', { method: 'POST' });
        setTimeout(fetchMetrics, 300);
      } finally {
        setTimeout(() => { btnNorm.disabled = false; }, 600);
      }
    });
  }

  if (btnAnom) {
    btnAnom.addEventListener('click', async () => {
      btnAnom.disabled = true;
      try {
        await fetch('/simulate/anomaly', { method: 'POST' });
        setTimeout(() => {
          fetchMetrics();
          fetchAnomalies();
        }, 400);
      } finally {
        setTimeout(() => { btnAnom.disabled = false; }, 1000);
      }
    });
  }

  if (btnClear) {
    btnClear.addEventListener('click', () => {
      const terminal = document.getElementById('logTerminal');
      if (terminal) {
        terminal.innerHTML = '<div class="terminal-greeting">[STREAM] Terminal buffer cleared. Resuming live events...</div>';
      }
    });
  }
}

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/[&<>'"]/g, 
    tag => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      "'": '&#39;',
      '"': '&quot;'
    }[tag] || tag)
  );
}
