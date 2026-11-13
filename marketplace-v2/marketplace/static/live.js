// Live view: poll /api/live and update elements in place so state changes animate instead of flickering.
(() => {
  const $ = (id) => document.getElementById(id);
  const tiles = new Map(), seenEvents = new Set();
  let first = true;

  const eth = (wei) => { const n = Number(wei) / 1e18; return (n >= 0.01 ? n.toFixed(3) : n.toPrecision(2)).replace(/\.?0+$/, '') + ' ETH'; };
  const short = (s) => (s && s.length > 12 ? s.slice(0, 6) + '…' + s.slice(-4) : s || '');
  const mins = (s) => (s >= 3600 ? Math.floor(s / 3600) + 'h ' + Math.floor((s % 3600) / 60) + 'm' : Math.max(0, Math.floor(s / 60)) + 'm ' + (s % 60) + 's');
  const label = { ready: 'Ready', pending: 'Pending', live: 'Live', offline: 'Offline', other: 'Unavailable' };

  function setCounter(id, value) {
    const el = $(id);
    if (el.textContent !== String(value)) { el.textContent = value; el.classList.add('bump'); setTimeout(() => el.classList.remove('bump'), 260); }
  }

  function renderTile(t) {
    let el = tiles.get(t.machine);
    if (!el) { el = document.createElement('div'); tiles.set(t.machine, el); $('tiles').appendChild(el); }
    el.className = 'tile ' + t.state;
    const specs = t.state === 'offline' ? '<span>not in the pool</span>'
      : `<span><b>${t.cpus}</b> CPU</span><span><b>${(t.memoryMiB / 1024).toFixed(1)}</b> GiB RAM</span><span>${t.apptainer ? 'Apptainer ✓' : 'no Apptainer'}</span>`;
    const meta = [];
    if (t.listingId) meta.push(`Listing #${t.listingId} · ${eth(t.priceWei)} / hour`);
    if (t.rentalId) meta.push(`<span class="rent">Rental #${t.rentalId} · ${mins(t.rentalEndsInSeconds)} left</span>`);
    el.innerHTML = `<h3>${t.machine}</h3><span class="badge">${label[t.state] || t.state}</span><div class="specs">${specs}</div><div class="meta">${meta.join('<br>')}</div>`;
  }

  function renderFeed(events, explorer) {
    const ul = $('feed');
    if (!events.length) { ul.innerHTML = '<li class="empty">No on-chain activity indexed yet.</li>'; return; }
    ul.innerHTML = '';
    for (const e of events) {
      const key = e.kind + e.id + e.tx, li = document.createElement('li');
      if (!first && !seenEvents.has(key)) li.className = 'new';
      seenEvents.add(key);
      const what = e.kind === 'rental'
        ? `<span class="k rental">Rental #${e.id}</span> · ${e.machine} · ${eth(e.priceWei)}`
        : `<span class="k listing">Listed #${e.id}</span> · ${e.machine} · ${eth(e.priceWei)}/h`;
      const tx = explorer && e.tx ? `<a href="${explorer}/tx/${e.tx}" target="_blank" rel="noopener">${short(e.tx)}</a>` : short(e.tx);
      li.innerHTML = `${what}<small>${e.kind === 'rental' ? 'by' : 'provider'} ${short(e.actor)} · tx ${tx} · block ${e.block}</small>`;
      ul.appendChild(li);
    }
  }

  async function tick() {
    try {
      const v = await (await fetch('/api/live', { cache: 'no-store' })).json();
      $('dot').className = 'dot' + (v.poolUp ? ' up' : '');
      $('clock').textContent = (v.poolUp ? 'live · ' : 'pool unreachable · ') + new Date(v.now * 1000).toLocaleTimeString();
      setCounter('c-ready', v.counters.Ready); setCounter('c-pending', v.counters.Pending);
      setCounter('c-live', v.counters.Live); setCounter('c-total', v.counters.Registered);
      const names = new Set(v.tiles.map((t) => t.machine));
      for (const [name, el] of tiles) if (!names.has(name)) { el.remove(); tiles.delete(name); }
      v.tiles.forEach(renderTile);
      renderFeed(v.events || [], v.explorer);
      $('chain').textContent = v.explorer ? '(Ethereum Sepolia)' : '';
      first = false;
    } catch (e) { $('dot').className = 'dot'; $('clock').textContent = 'backend unreachable'; }
  }
  tick(); setInterval(tick, 2000);
})();
