#!/usr/bin/env python3
"""
Cloudflare AsBuilt - Local Proxy Server
----------------------------------------
Run this script, then open http://localhost:8765 in your browser.
The server proxies requests to api.cloudflare.com so CORS is not an issue.

Requirements: Python 3.7+ (no extra packages needed)

Usage:
    python cf_asbuilt_server.py
"""

import http.server
import urllib.request
import urllib.error
import json
import os
import sys
import threading
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 8765
CF_API = "https://api.cloudflare.com/client/v4"

HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cloudflare AsBuilt Generator</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f4; color: #1c1c1a; font-size: 14px; line-height: 1.6; }
  .container { max-width: 1100px; margin: 0 auto; padding: 2rem 1.5rem; }
  h1 { font-size: 20px; font-weight: 600; margin-bottom: 4px; }
  .subtitle { color: #666; font-size: 13px; margin-bottom: 1.5rem; }
  .card { background: #fff; border: 1px solid #e5e5e3; border-radius: 10px; margin-bottom: 14px; overflow: hidden; }
  .card-header { padding: 12px 18px; display: flex; align-items: center; justify-content: space-between; cursor: pointer; user-select: none; }
  .card-header:hover { background: #fafaf9; }
  .card-header h2 { font-size: 14px; font-weight: 600; }
  .card-header .arrow { font-size: 10px; color: #999; transition: transform 0.15s; }
  .card-header.open .arrow { transform: rotate(90deg); }
  .card-body { padding: 16px 18px; border-top: 1px solid #e5e5e3; display: none; }
  .card-body.open { display: block; }
  .field-row { display: grid; grid-template-columns: 150px 1fr; gap: 8px; align-items: center; margin-bottom: 10px; }
  .field-row label { font-size: 13px; color: #555; }
  .field-row input, .field-row select { font-size: 13px; padding: 7px 10px; border: 1px solid #d4d4d2; border-radius: 6px; width: 100%; background: #fff; color: #1c1c1a; }
  .field-row input:focus, .field-row select:focus { outline: none; border-color: #888; }
  .btn { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; padding: 7px 16px; border: 1px solid #d4d4d2; border-radius: 6px; background: #fff; color: #1c1c1a; cursor: pointer; font-family: inherit; }
  .btn:hover { background: #f5f5f4; }
  .btn:disabled { opacity: 0.4; cursor: not-allowed; }
  .btn-primary { background: #1c1c1a; color: #fff; border-color: #1c1c1a; }
  .btn-primary:hover { background: #333; }
  .status { font-size: 12px; color: #666; margin-top: 8px; min-height: 16px; }
  .status.ok { color: #15803d; }
  .status.err { color: #b91c1c; }
  .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(110px, 1fr)); gap: 10px; margin: 12px 0; }
  .metric { background: #f5f5f4; border-radius: 8px; padding: 10px 14px; }
  .metric .label { font-size: 11px; color: #888; margin-bottom: 2px; text-transform: uppercase; letter-spacing: 0.04em; }
  .metric .value { font-size: 22px; font-weight: 600; }
  table { width: 100%; border-collapse: collapse; font-size: 12px; margin-top: 10px; }
  th { text-align: left; padding: 6px 8px; font-weight: 600; color: #888; border-bottom: 1px solid #e5e5e3; font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  td { padding: 7px 8px; border-bottom: 1px solid #f0f0ee; vertical-align: top; word-break: break-all; max-width: 300px; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #fafaf9; }
  .badge { display: inline-block; font-size: 10px; padding: 2px 7px; border-radius: 4px; font-weight: 600; }
  .badge-green { background: #dcfce7; color: #15803d; }
  .badge-yellow { background: #fef9c3; color: #a16207; }
  .badge-red { background: #fee2e2; color: #b91c1c; }
  .badge-blue { background: #dbeafe; color: #1d4ed8; }
  .badge-gray { background: #f0f0ee; color: #555; }
  .badge-orange { background: #ffedd5; color: #c2410c; }
  .mono { font-family: 'Courier New', monospace; font-size: 11px; }
  .proxy-on { display: inline-block; font-size: 10px; padding: 1px 6px; border-radius: 3px; background: #ffedd5; color: #c2410c; font-weight: 600; }
  .proxy-off { display: inline-block; font-size: 10px; padding: 1px 6px; border-radius: 3px; background: #f0f0ee; color: #888; font-weight: 600; }
  .error-box { font-size: 12px; color: #b91c1c; background: #fee2e2; border-radius: 6px; padding: 8px 12px; margin-top: 8px; }
  .info-box { font-size: 12px; color: #1d4ed8; background: #dbeafe; border-radius: 6px; padding: 10px 14px; margin-bottom: 14px; line-height: 1.7; }
  .empty { font-size: 13px; color: #aaa; padding: 10px 0; }
  .actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 4px; }
  .progress-wrap { margin-top: 10px; }
  .progress-label { font-size: 12px; color: #666; margin-bottom: 4px; }
  progress { width: 100%; height: 6px; border-radius: 3px; accent-color: #1c1c1a; }
  .section-note { font-size: 12px; color: #888; margin-bottom: 10px; }
</style>
</head>
<body>
<div class="container">

<h1>Cloudflare AsBuilt Documentation Generator</h1>
<p class="subtitle">Running via local proxy on port 8765 — no CORS issues</p>

<div class="info-box">
  <strong>Connected:</strong> This page is served by the local Python proxy, which forwards all API calls to <code>api.cloudflare.com</code> server-side.<br>
  <strong>Token permissions needed (Read only):</strong> Zone · DNS Records · Zero Trust (Access, Gateway, Tunnels, Devices, Posture)<br>
  Create a token at <strong>dash.cloudflare.com → My Profile → API Tokens → Create Custom Token</strong>.
</div>

<div class="card">
  <div class="card-header open" onclick="toggleCard(this)"><h2>🔑 Credentials</h2><span class="arrow">▶</span></div>
  <div class="card-body open">
    <div class="field-row"><label>API Token</label><input type="password" id="cf-token" placeholder="Bearer token" autocomplete="off"/></div>
    <div class="field-row"><label>Account ID</label><input type="text" id="cf-account" placeholder="32-char hex from dashboard sidebar" autocomplete="off"/></div>
    <div class="actions"><button class="btn btn-primary" onclick="verifyToken()">Verify token</button></div>
    <div class="status" id="status-verify"></div>
  </div>
</div>

<div class="card">
  <div class="card-header open" onclick="toggleCard(this)"><h2>⚡ Pull Everything</h2><span class="arrow">▶</span></div>
  <div class="card-body open">
    <p class="section-note">Runs all sections sequentially. Best starting point for a full AsBuilt export.</p>
    <button class="btn btn-primary" id="btn-all" onclick="pullAll()">Pull all sections</button>
    <div id="progress-section" style="display:none;margin-top:12px;">
      <div class="progress-label" id="progress-label">Starting…</div>
      <progress id="progress-bar" max="8" value="0"></progress>
    </div>
    <div class="status" id="status-all"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>🌐 Zones &amp; Domains</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <button class="btn" id="btn-zones" onclick="fetchZones()">Pull zones</button>
    <div class="status" id="status-zones"></div>
    <div id="zones-metrics"></div><div id="zones-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>📋 DNS Records</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <div class="field-row"><label>Zone</label><select id="dns-zone-select"><option value="">— pull zones first —</option></select></div>
    <div class="actions">
      <button class="btn" id="btn-dns" onclick="fetchDNS()">Pull selected zone</button>
      <button class="btn" id="btn-dns-all" onclick="fetchAllDNS()">Pull all zones</button>
    </div>
    <div class="status" id="status-dns"></div>
    <div id="dns-metrics"></div><div id="dns-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>🔒 Zero Trust — Access Applications</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <button class="btn" id="btn-zt" onclick="fetchAccessApps()">Pull Access apps</button>
    <div class="status" id="status-zt"></div>
    <div id="zt-metrics"></div><div id="zt-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>🛡️ Zero Trust — Gateway Policies</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <button class="btn" id="btn-gw" onclick="fetchGateway()">Pull Gateway policies</button>
    <div class="status" id="status-gw"></div>
    <div id="gw-metrics"></div><div id="gw-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>🚇 Zero Trust — Cloudflare Tunnels</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <button class="btn" id="btn-tunnels" onclick="fetchTunnels()">Pull tunnels</button>
    <div class="status" id="status-tunnels"></div>
    <div id="tunnels-metrics"></div><div id="tunnels-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>🪪 Zero Trust — Identity Providers</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <button class="btn" id="btn-idp" onclick="fetchIdPs()">Pull identity providers</button>
    <div class="status" id="status-idp"></div>
    <div id="idp-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>💻 Zero Trust — WARP Devices</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <button class="btn" id="btn-devices" onclick="fetchDevices()">Pull WARP devices</button>
    <div class="status" id="status-devices"></div>
    <div id="devices-metrics"></div><div id="devices-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header" onclick="toggleCard(this)"><h2>🩺 Zero Trust — Device Posture Rules</h2><span class="arrow">▶</span></div>
  <div class="card-body">
    <button class="btn" id="btn-posture" onclick="fetchPosture()">Pull posture rules</button>
    <div class="status" id="status-posture"></div>
    <div id="posture-result"></div>
  </div>
</div>

<div class="card">
  <div class="card-header open" onclick="toggleCard(this)"><h2>📄 Export AsBuilt</h2><span class="arrow">▶</span></div>
  <div class="card-body open">
    <p class="section-note">Download the raw data or a formatted Markdown report. Use "Copy for Claude" to paste into Claude.ai for a polished Word/PDF report.</p>
    <div class="actions">
      <button class="btn btn-primary" onclick="exportJSON()">↓ Download JSON</button>
      <button class="btn" onclick="exportMarkdown()">↓ Download Markdown</button>
      <button class="btn" onclick="copyForClaude()">📋 Copy summary for Claude</button>
    </div>
    <div class="status" id="status-export"></div>
  </div>
</div>

</div>

<script>
const BASE = '/api';
let store = { zones:[], dns:{}, accessApps:[], gateway:{dns:[],http:[],network:[]}, tunnels:[], idps:[], devices:[], posture:[] };

function getToken()  { return document.getElementById('cf-token').value.trim(); }
function getAccount(){ return document.getElementById('cf-account').value.trim(); }

function toggleCard(header) {
  const open = header.classList.toggle('open');
  header.nextElementSibling.classList.toggle('open', open);
}

function setStatus(id, msg, type) {
  const el = document.getElementById('status-' + id);
  if (!el) return;
  el.textContent = msg;
  el.className = 'status' + (type ? ' ' + type : '');
}

async function cfGet(path) {
  const token = getToken();
  if (!token) throw new Error('No API token entered.');
  const r = await fetch(BASE + path, {
    headers: { 'X-CF-Token': token, 'Content-Type': 'application/json' }
  });
  const d = await r.json();
  if (!d.success) {
    const e = (d.errors && d.errors[0]) ? (d.errors[0].message || JSON.stringify(d.errors[0])) : 'Unknown API error';
    throw new Error(e);
  }
  return d;
}

async function cfGetAll(path, perPage=100) {
  let all=[], page=1;
  while (true) {
    const sep = path.includes('?') ? '&' : '?';
    const d = await cfGet(`${path}${sep}per_page=${perPage}&page=${page}`);
    all = all.concat(d.result || []);
    const info = d.result_info || {};
    const total = info.total_count || all.length;
    if (all.length >= total || !(d.result && d.result.length)) break;
    page++;
    if (page > 100) break;
  }
  return all;
}

function esc(s) {
  if (s == null) return '—';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function renderMetrics(id, items) {
  const el = document.getElementById(id);
  if (!el) return;
  el.innerHTML = `<div class="metrics">${items.map(i=>`<div class="metric"><div class="label">${esc(i.label)}</div><div class="value">${esc(String(i.value))}</div></div>`).join('')}</div>`;
}

function renderTable(id, cols, rows) {
  const el = document.getElementById(id);
  if (!el) return;
  if (!rows.length) { el.innerHTML='<p class="empty">No results returned.</p>'; return; }
  el.innerHTML=`<div style="overflow-x:auto"><table><thead><tr>${cols.map(c=>`<th>${esc(c)}</th>`).join('')}</tr></thead><tbody>${rows.map(r=>`<tr>${r.map(c=>`<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
}

function statusBadge(s) {
  const m={active:'badge-green',healthy:'badge-green',pending:'badge-yellow',degraded:'badge-yellow',inactive:'badge-gray',down:'badge-red'};
  return `<span class="badge ${m[s]||'badge-gray'}">${esc(s||'unknown')}</span>`;
}
function actionBadge(a) {
  const m={block:'badge-red',allow:'badge-green',override:'badge-orange',isolate:'badge-blue',audit:'badge-yellow',bypass:'badge-gray'};
  return `<span class="badge ${m[a]||'badge-gray'}">${esc(a||'—')}</span>`;
}

async function verifyToken() {
  setStatus('verify','Verifying…');
  try {
    const d = await cfGet('/user/tokens/verify');
    setStatus('verify','✓ Token valid — ' + (d.result.status||'active'), 'ok');
  } catch(e) { setStatus('verify','✗ ' + e.message, 'err'); }
}

async function fetchZones() {
  const acct=getAccount();
  if (!acct) { setStatus('zones','Enter Account ID first.','err'); return; }
  setStatus('zones','Fetching zones…');
  document.getElementById('btn-zones').disabled=true;
  try {
    const all = await cfGetAll(`/zones?account.id=${acct}`);
    store.zones = all;
    renderMetrics('zones-metrics',[
      {label:'Total zones', value:all.length},
      {label:'Active', value:all.filter(z=>z.status==='active').length},
      {label:'Pending', value:all.filter(z=>z.status==='pending').length},
      {label:'Full setup', value:all.filter(z=>z.type==='full').length}
    ]);
    renderTable('zones-result',
      ['Domain','Zone ID','Plan','Type','Status','Nameservers'],
      all.map(z=>[
        `<strong>${esc(z.name)}</strong>`,
        `<span class="mono">${esc(z.id)}</span>`,
        esc(z.plan?.name||'—'),
        esc(z.type||'full'),
        statusBadge(z.status),
        (z.name_servers||[]).join('<br>')
      ])
    );
    const sel = document.getElementById('dns-zone-select');
    sel.innerHTML = '<option value="">— select a zone —</option>' + all.map(z=>`<option value="${esc(z.id)}">${esc(z.name)}</option>`).join('');
    setStatus('zones',`✓ ${all.length} zone(s) loaded`,'ok');
  } catch(e) {
    setStatus('zones','✗ '+e.message,'err');
    document.getElementById('zones-result').innerHTML=`<div class="error-box">${esc(e.message)}</div>`;
  }
  document.getElementById('btn-zones').disabled=false;
}

async function fetchDNS(zoneId, zoneName) {
  if (!zoneId) {
    zoneId = document.getElementById('dns-zone-select').value;
    zoneName = document.getElementById('dns-zone-select').selectedOptions[0]?.text;
  }
  if (!zoneId) { setStatus('dns','Select a zone first.','err'); return; }
  setStatus('dns',`Fetching DNS for ${zoneName||zoneId}…`);
  document.getElementById('btn-dns').disabled=true;
  try {
    const all = await cfGetAll(`/zones/${zoneId}/dns_records`);
    store.dns[zoneId]=all;
    renderMetrics('dns-metrics',[
      {label:'Records', value:all.length},
      {label:'Proxied', value:all.filter(r=>r.proxied).length},
      {label:'DNS only', value:all.filter(r=>!r.proxied).length},
      {label:'Types', value:[...new Set(all.map(r=>r.type))].sort().join(', ')}
    ]);
    renderTable('dns-result',
      ['Type','Name','Content','TTL','Proxy','Priority'],
      all.map(r=>[
        `<span class="badge badge-blue">${esc(r.type)}</span>`,
        `<span class="mono">${esc(r.name)}</span>`,
        `<span class="mono" style="font-size:11px">${esc((r.content||'').substring(0,80))}${r.content&&r.content.length>80?'…':''}</span>`,
        r.ttl===1?'Auto':esc(r.ttl),
        r.proxied?'<span class="proxy-on">Proxied</span>':'<span class="proxy-off">DNS only</span>',
        r.priority!=null?esc(r.priority):'—'
      ])
    );
    setStatus('dns',`✓ ${all.length} records for ${zoneName||zoneId}`,'ok');
  } catch(e) {
    setStatus('dns','✗ '+e.message,'err');
  }
  document.getElementById('btn-dns').disabled=false;
}

async function fetchAllDNS() {
  if (!store.zones.length) { setStatus('dns','Pull zones first.','err'); return; }
  document.getElementById('btn-dns-all').disabled=true;
  setStatus('dns',`Fetching DNS for ${store.zones.length} zone(s)…`);
  for (const z of store.zones) {
    try { store.dns[z.id] = await cfGetAll(`/zones/${z.id}/dns_records`); }
    catch(e) { store.dns[z.id]=[]; }
  }
  const merged = Object.entries(store.dns).flatMap(([zid,recs])=>{
    const z=store.zones.find(z=>z.id===zid);
    return recs.map(r=>({...r,_zone:z?z.name:zid}));
  });
  const total = merged.length;
  renderMetrics('dns-metrics',[
    {label:'Total records', value:total},
    {label:'Proxied', value:merged.filter(r=>r.proxied).length},
    {label:'Zones', value:store.zones.length}
  ]);
  renderTable('dns-result',
    ['Zone','Type','Name','Content','TTL','Proxy'],
    merged.map(r=>[
      `<strong>${esc(r._zone)}</strong>`,
      `<span class="badge badge-blue">${esc(r.type)}</span>`,
      `<span class="mono">${esc(r.name)}</span>`,
      `<span class="mono" style="font-size:11px">${esc((r.content||'').substring(0,70))}${r.content&&r.content.length>70?'…':''}</span>`,
      r.ttl===1?'Auto':esc(r.ttl),
      r.proxied?'<span class="proxy-on">Proxied</span>':'<span class="proxy-off">DNS only</span>'
    ])
  );
  setStatus('dns',`✓ ${total} total records across ${store.zones.length} zone(s)`,'ok');
  document.getElementById('btn-dns-all').disabled=false;
}

async function fetchAccessApps() {
  const acct=getAccount();
  if (!acct) { setStatus('zt','Enter Account ID first.','err'); return; }
  setStatus('zt','Fetching Access applications…');
  document.getElementById('btn-zt').disabled=true;
  try {
    const apps = await cfGetAll(`/accounts/${acct}/access/apps`);
    store.accessApps=apps;
    renderMetrics('zt-metrics',[
      {label:'Applications', value:apps.length},
      {label:'Self-hosted', value:apps.filter(a=>a.type==='self_hosted').length},
      {label:'SaaS', value:apps.filter(a=>a.type==='saas').length},
      {label:'SSH/Infra', value:apps.filter(a=>['ssh','rdp','vnc','infrastructure'].includes(a.type)).length}
    ]);
    renderTable('zt-result',
      ['Name','Domain','Type','Session TTL','App Launcher'],
      apps.map(a=>[
        `<strong>${esc(a.name||'—')}</strong>`,
        `<span class="mono" style="font-size:11px">${esc((a.domain||a.self_hosted_domains?.[0]||a.aud||'—').substring(0,60))}</span>`,
        `<span class="badge badge-blue">${esc(a.type||'—')}</span>`,
        esc(a.session_duration||'24h'),
        a.app_launcher_visible?'✓':'—'
      ])
    );
    setStatus('zt',`✓ ${apps.length} application(s) loaded`,'ok');
  } catch(e) {
    setStatus('zt','✗ '+e.message,'err');
    document.getElementById('zt-result').innerHTML=`<div class="error-box">${esc(e.message)}</div>`;
  }
  document.getElementById('btn-zt').disabled=false;
}

async function fetchGateway() {
  const acct=getAccount();
  if (!acct) { setStatus('gw','Enter Account ID first.','err'); return; }
  setStatus('gw','Fetching Gateway DNS, HTTP, and Network policies…');
  document.getElementById('btn-gw').disabled=true;
  try {
    const [dR,hR,nR]=await Promise.allSettled([
      cfGetAll(`/accounts/${acct}/gateway/rules?filters[rule_type]=dns`),
      cfGetAll(`/accounts/${acct}/gateway/rules?filters[rule_type]=http`),
      cfGetAll(`/accounts/${acct}/gateway/rules?filters[rule_type]=l4`)
    ]);
    store.gateway.dns    = dR.status==='fulfilled'?dR.value:[];
    store.gateway.http   = hR.status==='fulfilled'?hR.value:[];
    store.gateway.network= nR.status==='fulfilled'?nR.value:[];
    const all=[...store.gateway.dns,...store.gateway.http,...store.gateway.network];
    renderMetrics('gw-metrics',[
      {label:'DNS policies',     value:store.gateway.dns.length},
      {label:'HTTP policies',    value:store.gateway.http.length},
      {label:'Network policies', value:store.gateway.network.length}
    ]);
    renderTable('gw-result',
      ['Layer','Name','Action','Enabled','Precedence','Description'],
      [
        ...store.gateway.dns.map(r=>    ['<span class="badge badge-blue">DNS</span>',    `<strong>${esc(r.name)}</strong>`,actionBadge(r.action),r.enabled?'✓':'✗',r.precedence??'—',esc((r.description||'').substring(0,50))]),
        ...store.gateway.http.map(r=>   ['<span class="badge badge-orange">HTTP</span>', `<strong>${esc(r.name)}</strong>`,actionBadge(r.action),r.enabled?'✓':'✗',r.precedence??'—',esc((r.description||'').substring(0,50))]),
        ...store.gateway.network.map(r=>['<span class="badge badge-gray">L4</span>',    `<strong>${esc(r.name)}</strong>`,actionBadge(r.action),r.enabled?'✓':'✗',r.precedence??'—',esc((r.description||'').substring(0,50))])
      ]
    );
    setStatus('gw',`✓ ${all.length} policy rule(s) loaded`,'ok');
  } catch(e) {
    setStatus('gw','✗ '+e.message,'err');
    document.getElementById('gw-result').innerHTML=`<div class="error-box">${esc(e.message)}</div>`;
  }
  document.getElementById('btn-gw').disabled=false;
}

async function fetchTunnels() {
  const acct=getAccount();
  if (!acct) { setStatus('tunnels','Enter Account ID first.','err'); return; }
  setStatus('tunnels','Fetching Cloudflare Tunnels…');
  document.getElementById('btn-tunnels').disabled=true;
  try {
    const tunnels=await cfGetAll(`/accounts/${acct}/cfd_tunnel?is_deleted=false`);
    store.tunnels=tunnels;
    renderMetrics('tunnels-metrics',[
      {label:'Tunnels',  value:tunnels.length},
      {label:'Healthy',  value:tunnels.filter(t=>t.status==='healthy').length},
      {label:'Degraded', value:tunnels.filter(t=>t.status==='degraded').length},
      {label:'Inactive', value:tunnels.filter(t=>!t.status||t.status==='inactive').length}
    ]);
    renderTable('tunnels-result',
      ['Name','Tunnel ID','Status','Type','Created'],
      tunnels.map(t=>[
        `<strong>${esc(t.name||'—')}</strong>`,
        `<span class="mono">${esc(t.id)}</span>`,
        statusBadge(t.status||'unknown'),
        esc(t.tun_type||'cfd'),
        t.created_at?new Date(t.created_at).toLocaleDateString():'—'
      ])
    );
    setStatus('tunnels',`✓ ${tunnels.length} tunnel(s) loaded`,'ok');
  } catch(e) {
    setStatus('tunnels','✗ '+e.message,'err');
    document.getElementById('tunnels-result').innerHTML=`<div class="error-box">${esc(e.message)}</div>`;
  }
  document.getElementById('btn-tunnels').disabled=false;
}

async function fetchIdPs() {
  const acct=getAccount();
  if (!acct) { setStatus('idp','Enter Account ID first.','err'); return; }
  setStatus('idp','Fetching identity providers…');
  document.getElementById('btn-idp').disabled=true;
  try {
    const idps=await cfGetAll(`/accounts/${acct}/access/identity_providers`);
    store.idps=idps;
    renderTable('idp-result',
      ['Name','Type','ID','SCIMv2'],
      idps.map(i=>[
        `<strong>${esc(i.name||'—')}</strong>`,
        `<span class="badge badge-blue">${esc(i.type||'—')}</span>`,
        `<span class="mono">${esc(i.id)}</span>`,
        i.scim_config?.enabled?'✓ Enabled':'—'
      ])
    );
    setStatus('idp',`✓ ${idps.length} identity provider(s) loaded`,'ok');
  } catch(e) {
    setStatus('idp','✗ '+e.message,'err');
  }
  document.getElementById('btn-idp').disabled=false;
}

async function fetchDevices() {
  const acct=getAccount();
  if (!acct) { setStatus('devices','Enter Account ID first.','err'); return; }
  setStatus('devices','Fetching WARP devices…');
  document.getElementById('btn-devices').disabled=true;
  try {
    // physical-devices uses CursorPagination:
    //   request:  ?per_page=100&cursor=<token>
    //   response: result_info.cursor holds the next cursor (flat string)
    //             result_info.total_count is always null for this endpoint
    let devs=[], cursor=null, pageNum=0;
    while (true) {
      pageNum++;
      setStatus('devices',`Fetching WARP devices (batch ${pageNum}, ${devs.length} loaded so far)...`);
      const qs=cursor
        ? 'per_page=100&cursor='+encodeURIComponent(cursor)
        : 'per_page=100';
      const d=await cfGet('/accounts/'+acct+'/devices/physical-devices?'+qs);
      const batch=d.result||[];
      devs=devs.concat(batch);
      const nextCursor=(d.result_info&&d.result_info.cursor)||null;
      // stop when: no next cursor, same cursor returned, or empty batch
      if (!nextCursor||nextCursor===cursor||batch.length===0) break;
      cursor=nextCursor;
      if (devs.length>10000) break; // safety cap for very large fleets
    }
    store.devices=devs;
    const osCounts={};
    devs.forEach(d=>{
      const k=(d.os_distro_name||'Unknown').toLowerCase();
      const label=k.includes('win')?'Windows':k.includes('mac')?'macOS':k.includes('linux')?'Linux':k.includes('ios')?'iOS':k.includes('android')?'Android':'Other';
      osCounts[label]=(osCounts[label]||0)+1;
    });
    renderMetrics('devices-metrics',[
      {label:'Total devices',value:devs.length},
      ...Object.entries(osCounts).map(([k,v])=>({label:k,value:v}))
    ]);
    renderTable('devices-result',
      ['Hostname','OS','OS Version','Last seen','Serial'],
      devs.map(d=>[
        `<strong>${esc(d.name||d.hostname||'—')}</strong>`,
        esc(d.os_distro_name||'—'),
        esc(d.os_version||'—'),
        d.last_seen?new Date(d.last_seen).toLocaleString():'—',
        `<span class="mono">${esc(d.serial_number||'—')}</span>`
      ])
    );
    setStatus('devices',`✓ ${devs.length} device(s) loaded`,'ok');
  } catch(e) {
    setStatus('devices','✗ '+e.message,'err');
    document.getElementById('devices-result').innerHTML=`<div class="error-box">${esc(e.message)}</div>`;
  }
  document.getElementById('btn-devices').disabled=false;
}

async function fetchPosture() {
  const acct=getAccount();
  if (!acct) { setStatus('posture','Enter Account ID first.','err'); return; }
  setStatus('posture','Fetching device posture rules…');
  document.getElementById('btn-posture').disabled=true;
  try {
    const rules=await cfGetAll(`/accounts/${acct}/devices/posture`);
    store.posture=rules;
    renderTable('posture-result',
      ['Name','Type','Description'],
      rules.map(r=>[
        `<strong>${esc(r.name||'—')}</strong>`,
        `<span class="badge badge-blue">${esc(r.type||'—')}</span>`,
        esc((r.description||'—').substring(0,80))
      ])
    );
    setStatus('posture',`✓ ${rules.length} posture rule(s) loaded`,'ok');
  } catch(e) {
    setStatus('posture','✗ '+e.message,'err');
  }
  document.getElementById('btn-posture').disabled=false;
}

async function pullAll() {
  document.getElementById('btn-all').disabled=true;
  const steps=[
    ['Zones & domains',     fetchZones],
    ['DNS records (all)',   fetchAllDNS],
    ['Access applications', fetchAccessApps],
    ['Gateway policies',    fetchGateway],
    ['Cloudflare Tunnels',  fetchTunnels],
    ['Identity providers',  fetchIdPs],
    ['WARP devices',        fetchDevices],
    ['Device posture',      fetchPosture]
  ];
  document.getElementById('progress-section').style.display='block';
  const bar=document.getElementById('progress-bar');
  const lbl=document.getElementById('progress-label');
  bar.max=steps.length; bar.value=0;
  for (let i=0;i<steps.length;i++) {
    lbl.textContent=`Step ${i+1}/${steps.length}: ${steps[i][0]}…`;
    bar.value=i;
    try { await steps[i][1](); } catch(e) {}
  }
  bar.value=steps.length;
  lbl.textContent='✓ All sections complete';
  const totalDNS=Object.values(store.dns).reduce((a,b)=>a+b.length,0);
  setStatus('all',`✓ Done — ${store.zones.length} zones · ${totalDNS} DNS records · ${store.accessApps.length} apps · ${[...store.gateway.dns,...store.gateway.http,...store.gateway.network].length} policies · ${store.tunnels.length} tunnels · ${store.idps.length} IdPs · ${store.devices.length} devices`,'ok');
  document.querySelectorAll('.card-header:not(.open)').forEach(h=>{
    h.classList.add('open');
    h.nextElementSibling.classList.add('open');
  });
  document.getElementById('btn-all').disabled=false;
}

function download(filename, content, type) {
  const blob=new Blob([content],{type});
  const url=URL.createObjectURL(blob);
  const a=document.createElement('a');
  a.href=url; a.download=filename; a.click();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
}

function exportJSON() {
  const doc={
    _meta:{generated:new Date().toISOString(),account_id:getAccount()},
    zones:store.zones, dns_records:store.dns,
    zero_trust:{access_applications:store.accessApps,gateway_policies:store.gateway,tunnels:store.tunnels,identity_providers:store.idps,warp_devices:store.devices,device_posture_rules:store.posture}
  };
  download('cloudflare-asbuilt.json',JSON.stringify(doc,null,2),'application/json');
  setStatus('export','✓ JSON downloaded','ok');
}

function exportMarkdown() {
  const ts=new Date().toISOString().split('T')[0];
  let md=`# Cloudflare AsBuilt Documentation\n\n**Account ID:** \`${getAccount()}\`  \n**Generated:** ${ts}\n\n---\n\n`;
  md+=`## 1. Zones & Domains\n\n`;
  if (store.zones.length) {
    md+=`| Domain | Zone ID | Plan | Type | Status | Nameservers |\n|---|---|---|---|---|---|\n`;
    store.zones.forEach(z=>{md+=`| ${z.name} | \`${z.id}\` | ${z.plan?.name||'—'} | ${z.type||'full'} | ${z.status} | ${(z.name_servers||[]).join(', ')} |\n`;});
  } else md+=`_No zones pulled._\n`;
  md+=`\n## 2. DNS Records\n\n`;
  Object.entries(store.dns).forEach(([zid,recs])=>{
    const z=store.zones.find(z=>z.id===zid);
    md+=`### ${z?z.name:zid} (${recs.length} records)\n\n| Type | Name | Content | TTL | Proxied | Priority |\n|---|---|---|---|---|---|\n`;
    recs.forEach(r=>{md+=`| ${r.type} | ${r.name} | ${r.content||''} | ${r.ttl===1?'Auto':r.ttl} | ${r.proxied?'Yes':'No'} | ${r.priority??'—'} |\n`;});
    md+='\n';
  });
  md+=`## 3. Zero Trust — Access Applications\n\n`;
  if (store.accessApps.length) {
    md+=`| Name | Domain | Type | Session TTL |\n|---|---|---|---|\n`;
    store.accessApps.forEach(a=>{md+=`| ${a.name||'—'} | ${a.domain||a.self_hosted_domains?.[0]||'—'} | ${a.type||'—'} | ${a.session_duration||'24h'} |\n`;});
  } else md+=`_No apps pulled._\n`;
  md+=`\n## 4. Zero Trust — Gateway Policies\n\n`;
  ['dns','http','network'].forEach(t=>{
    const label={dns:'DNS',http:'HTTP',network:'Network (L4)'}[t];
    md+=`### ${label} Policies\n\n`;
    if (store.gateway[t].length) {
      md+=`| Name | Action | Enabled | Precedence | Description |\n|---|---|---|---|---|\n`;
      store.gateway[t].forEach(r=>{md+=`| ${r.name||'—'} | ${r.action||'—'} | ${r.enabled?'Yes':'No'} | ${r.precedence??'—'} | ${r.description||''} |\n`;});
    } else md+=`_No ${label} policies._\n`;
    md+='\n';
  });
  md+=`## 5. Zero Trust — Cloudflare Tunnels\n\n`;
  if (store.tunnels.length) {
    md+=`| Name | Tunnel ID | Status | Type | Created |\n|---|---|---|---|---|\n`;
    store.tunnels.forEach(t=>{md+=`| ${t.name||'—'} | \`${t.id}\` | ${t.status||'unknown'} | ${t.tun_type||'cfd'} | ${t.created_at?new Date(t.created_at).toLocaleDateString():'—'} |\n`;});
  } else md+=`_No tunnels pulled._\n`;
  md+=`\n## 6. Identity Providers\n\n`;
  if (store.idps.length) {
    md+=`| Name | Type | ID | SCIMv2 |\n|---|---|---|---|\n`;
    store.idps.forEach(i=>{md+=`| ${i.name||'—'} | ${i.type||'—'} | \`${i.id}\` | ${i.scim_config?.enabled?'Yes':'No'} |\n`;});
  } else md+=`_No IdPs pulled._\n`;
  md+=`\n## 7. WARP Devices\n\n`;
  if (store.devices.length) {
    md+=`| Hostname | OS | OS Version | Last Seen | Serial |\n|---|---|---|---|---|\n`;
    store.devices.forEach(d=>{md+=`| ${d.name||d.hostname||'—'} | ${d.os_distro_name||'—'} | ${d.os_version||'—'} | ${d.last_seen?new Date(d.last_seen).toLocaleDateString():'—'} | ${d.serial_number||'—'} |\n`;});
  } else md+=`_No devices pulled._\n`;
  md+=`\n## 8. Device Posture Rules\n\n`;
  if (store.posture.length) {
    md+=`| Name | Type | Description |\n|---|---|---|\n`;
    store.posture.forEach(r=>{md+=`| ${r.name||'—'} | ${r.type||'—'} | ${r.description||''} |\n`;});
  } else md+=`_No posture rules pulled._\n`;
  download(`cloudflare-asbuilt-${ts}.md`,md,'text/markdown');
  setStatus('export','✓ Markdown downloaded','ok');
}

function copyForClaude() {
  const totalDNS=Object.values(store.dns).reduce((a,b)=>a+b.length,0);
  const summary={
    account_id:getAccount(),
    counts:{zones:store.zones.length,dns_records:totalDNS,access_apps:store.accessApps.length,gateway_dns:store.gateway.dns.length,gateway_http:store.gateway.http.length,gateway_network:store.gateway.network.length,tunnels:store.tunnels.length,idps:store.idps.length,warp_devices:store.devices.length,posture_rules:store.posture.length},
    zones:store.zones.map(z=>({name:z.name,status:z.status,plan:z.plan?.name,nameservers:z.name_servers})),
    dns_sample:Object.entries(store.dns).map(([zid,recs])=>({zone:store.zones.find(z=>z.id===zid)?.name||zid,records:recs.map(r=>({type:r.type,name:r.name,content:r.content,proxied:r.proxied,ttl:r.ttl}))})),
    access_apps:store.accessApps.map(a=>({name:a.name,domain:a.domain||a.self_hosted_domains?.[0],type:a.type,session_duration:a.session_duration})),
    gateway_dns:store.gateway.dns.map(r=>({name:r.name,action:r.action,enabled:r.enabled,precedence:r.precedence,description:r.description})),
    gateway_http:store.gateway.http.map(r=>({name:r.name,action:r.action,enabled:r.enabled,precedence:r.precedence,description:r.description})),
    gateway_network:store.gateway.network.map(r=>({name:r.name,action:r.action,enabled:r.enabled,precedence:r.precedence})),
    tunnels:store.tunnels.map(t=>({name:t.name,id:t.id,status:t.status,type:t.tun_type})),
    idps:store.idps.map(i=>({name:i.name,type:i.type,scim:i.scim_config?.enabled})),
    posture_rules:store.posture.map(r=>({name:r.name,type:r.type,description:r.description}))
  };
  const text=`Please generate a professional AsBuilt documentation report in Markdown for this Cloudflare account. Include: executive summary, Account Overview, Zones & DNS (with full record tables), Zero Trust Access Applications, Gateway Policies (DNS/HTTP/Network), Cloudflare Tunnels, Identity Providers, WARP Devices, and Device Posture Rules.\n\nDATA:\n${JSON.stringify(summary,null,2)}`;
  navigator.clipboard.writeText(text).then(()=>{
    setStatus('export','✓ Copied — paste into Claude for a full Markdown/Word report','ok');
  }).catch(()=>{
    setStatus('export','✗ Clipboard not available — use Download JSON instead','err');
  });
}
</script>
</body>
</html>
"""

class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"  {args[0]} {args[1]}", flush=True)

    def send_cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-CF-Token")

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            body = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/api/"):
            cf_path = self.path[4:]  # strip /api
            token = self.headers.get("X-CF-Token", "")
            cf_url = CF_API + cf_path

            try:
                req = urllib.request.Request(
                    cf_url,
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/json",
                        "User-Agent": "cf-asbuilt-generator/1.0"
                    }
                )
                with urllib.request.urlopen(req, timeout=30) as resp:
                    body = resp.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_cors()
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            except urllib.error.HTTPError as e:
                body = e.read()
                self.send_response(e.code)
                self.send_header("Content-Type", "application/json")
                self.send_cors()
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            except Exception as e:
                err = json.dumps({"success": False, "errors": [{"message": str(e)}]}).encode()
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_cors()
                self.send_header("Content-Length", str(len(err)))
                self.end_headers()
                self.wfile.write(err)
            return

        self.send_response(404)
        self.end_headers()


def main():
    server = HTTPServer(("127.0.0.1", PORT), ProxyHandler)
    url = f"http://localhost:{PORT}"

    print("=" * 55)
    print("  Cloudflare AsBuilt Generator — Local Proxy Server")
    print("=" * 55)
    print(f"\n  Listening on {url}")
    print(f"\n  Opening browser automatically...")
    print(f"\n  Press Ctrl+C to stop the server.\n")

    # Open browser after short delay
    def open_browser():
        import time; time.sleep(0.8)
        webbrowser.open(url)
    threading.Thread(target=open_browser, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\n  Server stopped.")
        sys.exit(0)


if __name__ == "__main__":
    main()
