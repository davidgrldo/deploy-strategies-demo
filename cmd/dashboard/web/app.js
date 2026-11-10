'use strict';

const $ = (id) => document.getElementById(id);
const strategies = [
  {id:'recreate',title:'Recreate',number:'01',icon:'↻',tag:'Tutup, lalu buka kembali',description:'Matikan semua Pod lama, lalu hidupkan versi baru. Lihat jeda layanan terjadi.',lesson:'Tutup toko, renovasi.',text:'Semua kasir lama berhenti sebelum kasir baru dibuka. Sederhana, tetapi ada saat ketika tidak ada yang melayani.',steps:['v1 berhenti','Jeda layanan','v2 siap'],takeaway:'Cocok ketika dua versi tidak boleh hidup bersamaan dan downtime bisa diterima.',variants:[['recreate','Downtime nyata']]},
  {id:'rolling',title:'Rolling update',number:'02',icon:'⇄',tag:'Ganti satu per satu',description:'Pod baru masuk, Pod lama keluar. Traffic tetap mengalir selama pergantian.',lesson:'Ganti kasir satu-satu.',text:'Kasir baru harus siap sebelum kasir lama pulang. Graceful shutdown memberi waktu untuk menyelesaikan request yang sedang berjalan.',steps:['v2 mulai','v2 siap','v1 berhenti'],takeaway:'Perhatikan perbedaan graceful dan naive: request yang sedang diproses bisa selesai atau terputus.',variants:[['rolling','Graceful shutdown'],['rolling-naive','Tanpa graceful']]},
  {id:'bluegreen',title:'Blue–green',number:'03',icon:'◧',tag:'Dua slot, satu pergantian',description:'Siapkan versi baru di slot lain. Alihkan seluruh traffic saat semuanya siap.',lesson:'Buka toko kembar.',text:'Blue dan green punya kasir masing-masing. Traffic pindah dengan mengganti weight route; toko lama tetap siap untuk rollback.',steps:['Green siap','Switch 100%','Blue standby'],takeaway:'Deploy dan release terpisah. Klik rollback setelah demo untuk mengalihkan traffic kembali ke slot sebelumnya.',variants:[['bluegreen','Switch & rollback']]},
  {id:'canary',title:'Canary release',number:'04',icon:'◉',tag:'Uji lewat sedikit traffic',description:'Kirim 10% traffic ke versi baru. Amati error, lalu promote atau rollback otomatis.',lesson:'Menu baru, sedikit tamu.',text:'Versi baru diuji lewat request sungguhan. Health check bisa tetap hijau meskipun user menerima error; karena itu pipeline membaca hasil traffic.',steps:['Traffic 90/10','Observasi','Promote / rollback'],takeaway:'Versi sehat dipromosikan dengan digest yang sama. Versi rusak ditarik sebelum menerima seluruh traffic.',variants:[['canary','Versi sehat'],['canary-bad','Versi rusak · 30% error']]}
];
let selected = strategies[1], state = null, connected = false, topologyKey = '', logKey = '', activeTab = 'requests', submitting = false;
let toastTimer;
const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const number = new Intl.NumberFormat('id-ID');
const clock = (value) => new Date(value).toLocaleTimeString('id-ID',{hour12:false,hour:'2-digit',minute:'2-digit',second:'2-digit'});
const pct = (n, total) => total ? Math.round(n / total * 100) : 0;

function toast(message) { $('toast').textContent = message; $('toast').hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').hidden = true, 5500); }
function choose(id) {
  selected = strategies.find(s => s.id === id) || strategies[1];
  document.querySelectorAll('.nav-item').forEach(el => { const active = el.dataset.strategy === selected.id; el.classList.toggle('active',active); el.setAttribute('aria-pressed',String(active)); });
  $('strategy-title').textContent = selected.title;
  $('strategy-number').textContent = `${selected.number} / 04`;
  $('strategy-description').textContent = selected.description;
  $('variant').innerHTML = selected.variants.map(([id,label]) => `<option value="${id}">${label}</option>`).join('');
  $('lesson-title').textContent = selected.lesson;
  $('lesson-text').textContent = selected.text;
  $('lesson-takeaway').textContent = selected.takeaway;
  $('lesson-sequence').innerHTML = selected.steps.map((s,i) => `${i ? '<span class="lesson-arrow">→</span>' : ''}<span class="lesson-step">${escapeHTML(s)}</span>`).join('');
  if (state) render(state);
  try { localStorage.setItem('deployment-strategy',selected.id); } catch {}
}
$('strategies').innerHTML = strategies.map(s => `<button class="nav-item" data-strategy="${s.id}" aria-pressed="false" title="${escapeHTML(s.title)}"><span class="nav-icon" aria-hidden="true">${s.icon}</span><span class="nav-copy">${escapeHTML(s.title)}<small>${escapeHTML(s.tag)}</small></span><span class="nav-number">${s.number}</span></button>`).join('');
$('strategies').addEventListener('click',e => { const button = e.target.closest('[data-strategy]'); if (button) choose(button.dataset.strategy); });

function actualStrategy(s) {
  const backends = s.cluster.backends || [];
  if (backends.some(b => b.name === 'app-stable')) return 'canary';
  if (backends.some(b => b.name === 'app-blue')) return 'bluegreen';
  if (backends.some(b => b.strategy === 'Recreate')) return 'recreate';
  return backends.length ? 'rolling' : '';
}
function narrative(s) {
  const active = actualStrategy(s), r = s.run, backends = s.cluster.backends || [], pods = s.cluster.pods || [];
  if (s.cluster.error) return 'Data cluster terakhir sedang ditampilkan. Sambungan kubectl perlu dipulihkan agar topologi kembali diperbarui.';
  if (!backends.length) return 'Gateway sudah disiapkan. Jalankan salah satu demo untuk membuat aplikasi dan route traffic.';
  if (r.running && r.step < 4) return `${r.phase}. Traffic saat persiapan belum menggambarkan hasil release; penghitung dimulai ulang saat fase Release.`;
  if (selected.id !== active) return `Pilihan: ${selected.title}. Topologi ini tetap menampilkan cluster nyata (${strategies.find(s => s.id === active)?.title || 'belum ada aplikasi'}). Klik Jalankan demo untuk beralih.`;
  if (r.result === 'rolled-back' && active === 'canary') return r.canary?.reason === 'insufficient-samples' ? 'Bukti belum cukup: sampel canary tidak mencapai minimum dalam batas waktu. Pipeline mempertahankan versi lama; ini bukan bukti bahwa versi baru rusak.' : 'Error canary melewati ambang. Pipeline mengembalikan 100% traffic ke stable dan menghentikan Pod canary.';
  if (active === 'canary') {
    const canary = backends.find(b => b.name === 'app-canary');
    if (canary?.weight > 0) return `Versi baru menerima ${canary.weight}% traffic. Pipeline mengamati respons X-Version dan error sebelum memutuskan promote atau rollback.`;
    if (r.result === 'promoted') return 'Canary lolos observasi. Stable kini menggunakan digest yang sama dengan versi yang diuji; traffic kembali 100% ke stable.';
    return 'Traffic masih menuju stable. Pod canary akan dinaikkan sebelum menerima sebagian traffic.';
  }
  if (active === 'bluegreen') {
    const target = backends.find(b => b.weight > 0);
    return `${target?.name || 'Slot aktif'} menerima traffic. Slot lain tetap tersedia; switch dan rollback mengubah route tanpa membangun image ulang.`;
  }
  if (pods.some(p => p.status === 'Terminating')) {
    if (active === 'recreate') return 'Pod lama sedang dihentikan. Versi baru menunggu seluruh Pod lama selesai; perhatikan error dan estimasi jeda request.';
    if (r.target === 'rolling-naive') return 'Tanpa graceful shutdown: proses lama berhenti langsung. Request yang masih diproses dapat terputus, walaupun Pod pengganti sudah ready.';
    return 'Pod lama sedang dihentikan. Pada varian graceful, proses melepas readiness, menunggu drain, lalu menyelesaikan request yang masih berjalan.';
  }
  if (pods.some(p => !p.ready)) return 'Pod pengganti sedang mulai. Readiness menentukan kapan Pod boleh menerima traffic.';
  return active === 'rolling' ? 'Semua Pod aktif siap melayani. Saat rolling berjalan, perhatikan v1 dan v2 hidup bersamaan sebelum Pod lama keluar.' : 'Semua Pod aktif siap melayani. Saat recreate berjalan, akan ada jeda di antara versi lama berhenti dan versi baru siap.';
}

function topology(s) {
  const c = s.cluster, backends = c.backends || [], pods = c.pods || [];
  const key = JSON.stringify([c.gateway,c.error,backends,pods]);
  if (key === topologyKey) return;
  topologyKey = key;
  const client = `<div class="network-node client"><span class="node-glyph">◎</span><strong>Traffic demo</strong><small>6 pengirim HTTP</small><span class="flow-particle"></span></div>`;
  const gateway = `<div class="network-node gateway ${!c.gateway ? 'disconnected' : ''}"><span class="node-glyph">⑂</span><strong>Gateway</strong><small>${c.gateway ? 'ENVOY · :8080' : 'BELUM SIAP'}</small>${c.gateway && backends.length ? '<span class="flow-particle"></span>' : ''}</div>`;
  const sumWeight = backends.reduce((sum,b) => sum + b.weight,0);
  const lanes = backends.map(b => {
    const list = pods.filter(p => p.app === b.name);
    const weight = pct(b.weight,sumWeight);
    return `<div class="lane ${!b.weight ? 'idle' : b.ready ? weight <= 10 ? 'active low-traffic' : 'active' : ''}"><div class="service"><div class="service-name">${escapeHTML(b.name)}</div><div class="service-weight">${weight}%<small>ROUTE WEIGHT</small></div></div><div class="pod-group">${list.length ? list.map(p => {
      const variant = p.version === 'v1' ? 'v1' : p.version === 'v2' ? 'v2' : 'unknown';
      const status = p.status === 'Terminating' ? 'terminating' : !p.ready ? 'pending' : '';
      return `<button class="pod ${variant} ${status}" data-pod="${escapeHTML(p.name)}" title="${escapeHTML(p.name)} · ${escapeHTML(p.status)}"><span class="pod-title"><span>${escapeHTML(p.version || '—')}</span><span class="pod-icon">⬡</span></span><small>${escapeHTML(p.name.split('-').slice(-1)[0])}</small><small class="pod-state">${escapeHTML(p.status)}</small></button>`;
    }).join('') : `<div class="scaled-zero">${b.desired ? 'Menunggu Pod…' : 'Standby · 0 replica'}</div>`}</div></div>`;
  }).join('');
  $('network').innerHTML = client + gateway + `<div class="network-lanes">${lanes || '<div class="scaled-zero">Belum ada aplikasi.<br>Jalankan demo untuk memulai.</div>'}</div>`;
}
$('network').addEventListener('click',e => { const el = e.target.closest('[data-pod]'); if (!el || !state) return; const p = state.cluster.pods.find(p => p.name === el.dataset.pod); if(p) toast(`${p.name} · ${p.version || 'versi belum diketahui'} · ${p.status}${p.status === 'Terminating' ? ' · sedang keluar dari layanan' : ''}`); });

function chart(s) {
  const now = Math.floor(new Date(s.time).getTime() / 1000), history = s.history || [], buckets = new Map(history.map(b => [b.time,b]));
  let max = 8;
  history.forEach(b => max = Math.max(max,b.v1+b.v2+b.other+b.errors));
  const colors = ['#9da4bd','#a4cd70','#8589c7','#db7565'];
  const keys = ['v1','v2','other','errors'];
  let svg = '';
  for (let i = 0;i<90;i++) {
    const b = buckets.get(now-89+i); if(!b) continue;
    let y=110;
    keys.forEach((key,index) => {const h=b[key]/max*100;if(!h)return;y-=h;svg+=`<rect x="${i*8}" y="${y.toFixed(2)}" width="5.5" height="${h.toFixed(2)}" rx="1" fill="${colors[index]}"><title>${escapeHTML(clock(b.time*1000))} · ${key}: ${b[key]} req</title></rect>`;});
  }
  $('traffic-chart').innerHTML = `<svg viewBox="0 0 720 110" preserveAspectRatio="none" aria-hidden="true">${svg}</svg>`;
  const recent = history.filter(b => b.time >= now-4);
  $('chart-rate').textContent = `${(recent.reduce((sum,b)=>sum+b.v1+b.v2+b.other+b.errors,0)/5).toFixed(1)} req/s`;
  const trend = history.slice(-20).map(b => b.errors ? 18 : 8);
  $('success-spark').innerHTML = `<svg viewBox="0 0 100 25" aria-hidden="true"><polyline points="${trend.map((y,i)=>`${i*5},${y}`).join(' ')}" fill="none" stroke="#a1c47b" stroke-width="1.5"/></svg>`;
}
const family = target => target?.startsWith('bluegreen') ? 'bluegreen' : target?.startsWith('canary') ? 'canary' : target?.startsWith('rolling') ? 'rolling' : target;
const targetName = target => target === 'rolling-naive' ? 'Rolling · tanpa graceful' : target === 'canary-bad' ? 'Canary · versi rusak' : target === 'bluegreen-rollback' ? 'Blue-green · rollback' : strategies.find(v=>v.id===target)?.title || 'Belum dijalankan';
function renderProcess(s, active) {
  const r=s.run, current=family(r.target), a=r.canary||{}, own=current===selected.id;
  $('selected-context').textContent=selected.title;
  $('run-context-label').textContent=r.running?'DEMO BERJALAN':'DEMO TERAKHIR';
  $('run-context').textContent=targetName(r.target);
  $('live-context').textContent=(strategies.find(v=>v.id===active)?.title||'Belum ada aplikasi')+(s.cluster.error?' · data terakhir':'');
  $('follow-live').hidden=selected.id===(r.running?current:active)||!(r.running?current:active);
  const topic=r.running?current:selected.id;
  const sequences={
    recreate:[['replace','Hentikan v1'],['readiness','Mulai & siapkan v2'],['complete','v2 melayani']],
    rolling:[['rolling','Ganti Pod bergantian'],['complete','v2 melayani']],
    bluegreen:[['deploy','Pasang versi baru'],['readiness','Tunggu ready'],['standby','Slot siap'],['switch','Alihkan traffic'],['complete','Selesai']],
    canary:[['deploy','Pasang canary'],['readiness','Tunggu ready'],['split','Bagi traffic'],['observe','Observasi'],['promote','Putuskan & terapkan'],['complete','Selesai']]
  };
  let steps=sequences[topic]||[], phase=r.releasePhase, index=-1;
  if(r.target==='bluegreen-rollback'&&(r.running||own))steps=[['rollback','Kembalikan route'],['complete','Selesai']];
  if(topic==='canary'&&phase==='rollback')phase='promote';
  if(topic==='recreate'&&phase==='replace'&&!(s.cluster.pods||[]).some(p=>p.version==='v1'))phase='readiness';
  if(r.running||own)index=steps.findIndex(([id])=>id===phase);
  $('release-status').textContent=r.running?`Proses ${targetName(r.target)}${r.step<4?' · menyiapkan baseline, test & image':''}`:own&&r.result?`Hasil ${targetName(r.target)} · ${r.result==='rolled-back'?'rollback':r.result==='failed'?'terhenti':'selesai'}`:`Urutan ${selected.title} · belum dijalankan`;
  $('release-steps').innerHTML=steps.map(([id,label],i)=>`<li class="${index>i||phase==='complete'&&index>=0?'done':index===i?'current':''}" ${index===i?'aria-current="step"':''}><span>${index>i||phase==='complete'&&index>=0?'✓':i+1}</span>${escapeHTML(id==='complete'&&r.result==='rolled-back'&&own?'Versi lama aktif':label)}</li>`).join('');
  const period=r.step>=4?'sejak fase Release':'selama persiapan / pengamatan';
  $('measurement-note').textContent=`Sampler dashboard · seluruh traffic ${period}, mulai ${clock(s.metrics.since)}. Jeda = rentetan request gagal sampai berhasil; bukan downtime seluruh layanan.`;
  const show=selected.id==='canary'||r.running&&current==='canary';
  $('canary-panel').hidden=!show;
  document.querySelector('.lesson').hidden=show;
  if(show){
    const available=current==='canary'&&a.available;
    $('canary-samples').textContent=available?`${a.samples} / min. ${a.minimum}`:'—';
    $('canary-rate').textContent=available?`${a.samples?(a.errors/a.samples*100).toFixed(1):'0.0'}% (${a.errors})`:'—';
    const reason=available?a.reason:'';
    $('canary-verdict').textContent=reason==='insufficient-samples'?'Bukti belum cukup':reason==='error-rate'?'Error melewati ambang':reason==='healthy'?'Canary lolos observasi':available?'Mengamati versi canary':'Menunggu demo canary';
    $('canary-panel').dataset.result=reason||'observing';
    $('canary-policy').textContent=available?`Ambang error ${(a.maximum*100).toFixed(1)}%. Promosi memerlukan ≥ ${a.minimum} sampel dan error ≤ ambang.`:'10% traffic diarahkan ke versi baru. Health check tetap bisa hijau saat request user gagal.';
    $('canary-clock').textContent=available?`${reason?'Observasi selesai':'Observasi'}: ${a.elapsed}s / window ${a.window}s${!reason&&a.elapsed>=a.window?' · menunggu sampel tambahan (maks. '+(a.window*2)+'s)':''}.`:'';
    $('canary-explanation').textContent=available?`${r.running?'Sampel live':'Hasil demo terakhir'} dari pengirim pipeline, khusus respons versi canary. Dashboard memakai pengirim terpisah dan menghitung seluruh traffic.${reason==='insufficient-samples'?' Versi lama dipertahankan; versi baru belum terbukti rusak.':` Observasi bisa berhenti lebih awal bila error terlalu tinggi.`}`:'Contoh: jika 10% traffic menerima 30% error, keberhasilan keseluruhan bisa sekitar 97%, tetapi versi canary tetap perlu ditarik.';
  }
}
$('follow-live').addEventListener('click',()=>{if(state){choose(state.run.running?family(state.run.target):actualStrategy(state));if(state.run.running&&[...$('variant').options].some(o=>o.value===state.run.target))$('variant').value=state.run.target;}});
function render(s) {
  state = s;
  const m=s.metrics,c=s.cluster,r=s.run,successful=m.total-m.errors;
  $('success-value').innerHTML = `${m.total ? ((successful/m.total)*100).toFixed(1) : '—'}<small>%</small>`;
  $('total-detail').textContent = `${number.format(successful)} dari ${number.format(m.total)} request`;
  $('v1-value').textContent = `${pct(m.v1,successful)}%`;
  $('v2-value').textContent = `${pct(m.v2,successful)}%`;
  $('mix-v1').style.width=`${pct(m.v1,successful)}%`;
  $('mix-v2').style.width=`${pct(m.v2,successful)}%`;
  $('mix-other').style.width=`${pct(m.other,successful)}%`;
  $('mix-detail').textContent = m.other ? `${number.format(m.other)} respons versi lainnya` : 'Hanya respons berhasil · bukan weight route';
  const pods=c.pods||[],backends=c.backends||[],ready=pods.filter(p=>p.ready).length,desired=backends.reduce((sum,b)=>sum+b.desired,0),terminating=pods.filter(p=>p.status==='Terminating').length;
  $('ready-value').textContent=ready;
  $('desired-value').textContent=` / ${desired}`;
  $('pod-detail').textContent=terminating?`${terminating} Pod sedang terminating`:c.error?'Data cluster belum diperbarui':`${backends.length} deployment · ${pods.length} Pod terdeteksi`;
  $('error-value').textContent=number.format(m.errors);
  $('downtime-detail').innerHTML=`Estimasi jeda request <strong>${m.downtime.toFixed(1)}s</strong>`;
  $('downtime-detail').title='Rentetan respons gagal sampai respons berhasil berikutnya; bukan pengukuran downtime seluruh layanan.';
  $('latency').textContent=`latensi rata-rata ${Math.round(m.latency)} ms`;
  $('cluster-badge').textContent=c.error?'DATA TERAKHIR':c.gateway?'LIVE TOPOLOGY':'GATEWAY BELUM SIAP';
  const active=actualStrategy(s);
  renderProcess(s,active);
  $('topology-context').textContent=`${strategies.find(v=>v.id===active)?.title || 'Cluster lokal'} · namespace default`;
  topology(s);
  $('narration').textContent=narrative(s);
  $('rollback').hidden=!(active==='bluegreen'&&backends.every(b=>b.ready>0));
  $('rollback').disabled=r.running||!connected||submitting;
  $('run-phase').textContent=r.target?r.phase:'Siap untuk demo';
  $('run-dot').classList.toggle('running-dot',r.running);
  $('run-dot').classList.toggle('bad-dot',r.result==='failed');
  $('run-button').disabled=r.running||!connected||submitting||!!c.error||!c.gateway;
  $('run-button').innerHTML=r.running?'<span>◌</span> Demo berjalan…':'<span>▶</span> Jalankan demo';
  $('variant').disabled=r.running;
  document.querySelectorAll('#pipeline li').forEach(el=>{const step=Number(el.dataset.step);el.classList.toggle('done',step<r.step||(!r.running&&r.step===5));el.classList.toggle('current',r.running&&step===r.step);});
  const end=r.running?new Date(s.time):new Date(r.finished);
  $('run-duration').textContent=r.target?`${Math.max(0,Math.floor((end-new Date(r.started))/1000))}s`:'—';
  const alert=c.error||(r.result==='failed'&&!r.running?'Demo terhenti. Buka Pipeline log untuk melihat penyebabnya.':'');
  $('alert').hidden=!alert;$('alert').textContent=alert;
  chart(s);
  $('requests-count').textContent=number.format(m.total);
  if(activeTab==='requests')renderRequests(s);
  if(activeTab==='logs')renderLogs(s);
  $('updated').textContent=`Cluster diperbarui ${c.updated&&new Date(c.updated).getFullYear()>2000?clock(c.updated):'—'} · stream 0,5s`;
}
function renderRequests(s){
  $('request-list').innerHTML=(s.recent||[]).slice(-12).reverse().map(req=>`<div class="request-row"><span>${escapeHTML(clock(req.time))}</span><span class="http-status ${req.status<200||req.status>=300?'bad':''}">${req.status||'ERR'} ${req.status===200?'OK':req.status===0?'CONNECTION':req.status>=500?'ERROR':''}</span><span class="request-version ${req.version==='v2'?'v2':''}">${escapeHTML(req.version||'—')}</span><span>${Math.round(req.latency)} ms</span></div>`).join('')||'<div class="empty-state">Menunggu traffic…</div>';
}
function renderLogs(s){
  const logs=s.run.logs||[],key=`${s.run.id}:${logs.length}:${logs[logs.length-1]?.text}`;
  if(logKey===key)return;logKey=key;
  $('log-label').textContent=s.run.target?`$ make ${s.run.target}`:'Output pipeline akan tampil saat demo dijalankan.';
  $('logs').innerHTML=logs.length?logs.map(line=>`<span class="log-time">${escapeHTML(clock(line.time))}</span> <span class="${/ROLLBACK|Error|FAIL|error:/.test(line.text)?'log-error':/PROMOTED|successfully|selesai|siap/.test(line.text)?'log-success':''}">${escapeHTML(line.text)}</span>`).join('\n'):'<span class="muted">$ make &lt;strategi&gt;</span>';
  if($('follow-logs').checked)$('logs').scrollTop=$('logs').scrollHeight;
}
function tab(name){activeTab=name;['requests','logs'].forEach(id=>{$(`tab-${id}`).setAttribute('aria-selected',String(name===id));$(`${id}-content`).hidden=name!==id;});if(state){if(name==='logs')renderLogs(state);else renderRequests(state);}}
['requests','logs'].forEach(name=>{$(`tab-${name}`).addEventListener('click',()=>tab(name));$(`tab-${name}`).addEventListener('keydown',e=>{if(e.key==='ArrowLeft'||e.key==='ArrowRight'){const next=name==='requests'?'logs':'requests';tab(next);$(`tab-${next}`).focus();e.preventDefault();}});});

async function run(target){
  if(submitting||state?.run.running)return;
  submitting=true;if(state)render(state);
  try{
    const response=await fetch('/api/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({target})});
    if(!response.ok)throw new Error(await response.text());
    tab('logs');toast(target==='bluegreen-rollback'?'Mengembalikan traffic ke slot sebelumnya…':'Demo dimulai. Baseline v1 disiapkan otomatis.');
  }catch(error){toast(error.message||'Tidak bisa memulai demo.');}
  finally{submitting=false;if(state)render(state);}
}
$('run-button').addEventListener('click',()=>run($('variant').value));
$('rollback').addEventListener('click',()=>run('bluegreen-rollback'));
$('presentation').addEventListener('click',()=>{const active=document.body.classList.toggle('presenting');$('presentation').innerHTML=active?'⛶ <span>Keluar presentasi</span>':'⛶ <span>Presentasi</span>';$('presentation').setAttribute('aria-pressed',String(active));});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&document.body.classList.contains('presenting'))$('presentation').click();});
function setTheme(dark) {
  document.documentElement.classList.toggle('dark', dark);
  document.body.classList.remove('dark');
  $('theme-button').setAttribute('aria-pressed', String(dark));
  $('theme-button').setAttribute('aria-label', dark ? 'Gunakan tema terang' : 'Gunakan tema gelap');
  $('theme-button').title = dark ? 'Gunakan tema terang' : 'Gunakan tema gelap';
  document.querySelector('meta[name="theme-color"]').content = dark ? '#141a16' : '#f5f5f0';
  try { localStorage.setItem('deployment-theme', dark ? 'dark' : 'light'); } catch {}
}
$('theme-button').addEventListener('click', () => setTheme(!document.documentElement.classList.contains('dark')));
let initial='rolling';try{initial=localStorage.getItem('deployment-strategy')||'rolling';}catch{}
setTheme(document.documentElement.classList.contains('dark'));
choose(initial);
$('run-button').disabled=true;
const stream=new EventSource('/api/events');
stream.onmessage=event=>{try{const incoming=JSON.parse(event.data);connected=true;document.body.classList.remove('offline');$('connection').textContent='Live connection';$('connection-dot').classList.remove('bad-dot');render(incoming);}catch(error){console.error('Invalid dashboard update',error);}};
stream.onerror=()=>{connected=false;document.body.classList.add('offline');$('connection').textContent='Menghubungkan ulang…';$('connection-dot').classList.add('bad-dot');$('run-button').disabled=true;$('rollback').disabled=true;$('cluster-badge').textContent='STREAM TERPUTUS';$('updated').textContent='Stream terputus · menunggu sambungan';};
