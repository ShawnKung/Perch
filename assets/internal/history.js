(() => {
  if (location.protocol !== 'perch:' || location.hostname !== 'history') return;
  const send = (action, values = {}) => window.webkit.messageHandlers.perchHistory.postMessage({action, ...values});
  const byID = id => document.getElementById(id);
  const search = byID('search'), timeline = byID('timeline'), dialog = byID('confirmation');
  const rows = new Map(), days = new Map();
  const dateFormat = new Intl.DateTimeFormat('zh-CN', {year:'numeric', month:'long', day:'numeric', weekday:'long'});
  const timeFormat = new Intl.DateTimeFormat('zh-CN', {hour:'2-digit', minute:'2-digit', hour12:false});
  let records = [], filtered = [], selected = new Set(), limit = 100, initialized = false, pendingDelete = [];
  function saveView() {
    if (initialized) send('viewState', {query:search.value, selected:[...selected], scroll:scrollY, limit});
  }
  function svg(paths) {
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('viewBox','0 0 24 24'); icon.setAttribute('aria-hidden','true');
    icon.innerHTML = paths; // Application artwork only; history content uses textContent.
    return icon;
  }
  function makeRow(record) {
    const row = document.createElement('div'); row.className = 'row'; row.dataset.id = record.id;
    const select = document.createElement('label'); select.className = 'select';
    const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; select.append(checkbox);
    const time = document.createElement('time');
    const icon = document.createElement('span'); icon.className = 'site-icon';
    icon.append(svg('<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>'));
    const visit = document.createElement('button'); visit.className = 'visit';
    const title = document.createElement('span'); title.className = 'title';
    const address = document.createElement('span'); address.className = 'address'; visit.append(title,address);
    const remove = document.createElement('button'); remove.className = 'remove';
    remove.title = '删除此条记录'; remove.setAttribute('aria-label','删除此条记录');
    remove.append(svg('<path d="m6 6 12 12M18 6 6 18"/>'));
    row.append(select,time,icon,visit,remove);
    return {row,checkbox,time,visit,title,address};
  }
  function render() {
    const query = search.value.trim().toLocaleLowerCase();
    filtered = records.filter(record => !query || `${record.title}\n${record.address}`.toLocaleLowerCase().includes(query));
    const matching = new Set(filtered.map(record => record.id));
    selected = new Set([...selected].filter(id => matching.has(id)));
    const visible = filtered.slice(0,limit), keep = new Set(visible.map(record => record.id)), activeDays = new Set();
    for (const [id, entry] of rows) if (!keep.has(id)) { entry.row.remove(); rows.delete(id); }
    const today = new Date(), yesterday = new Date(); yesterday.setDate(today.getDate()-1);
    let dayIndex = 0, rowIndex = 0, previousDay = '';
    for (const record of visible) {
      const date = new Date(record.date), key = date.toDateString();
      let day = days.get(key);
      if (!day) {
        const section = document.createElement('section'); section.className = 'day';
        const heading = document.createElement('h2'), list = document.createElement('div');
        section.append(heading,list); day = {section,heading,list}; days.set(key,day);
      }
      const relative = key === today.toDateString() ? '今天 · ' : key === yesterday.toDateString() ? '昨天 · ' : '';
      day.heading.textContent = relative + dateFormat.format(date);
      if (!activeDays.has(key)) {
        if (timeline.children[dayIndex] !== day.section) timeline.insertBefore(day.section,timeline.children[dayIndex] || null);
        dayIndex++; activeDays.add(key);
      }
      if (previousDay !== key) { rowIndex = 0; previousDay = key; }
      const entry = rows.get(record.id) || makeRow(record); rows.set(record.id,entry);
      entry.title.textContent = record.title || record.address; entry.address.textContent = record.address;
      entry.visit.title = record.address; entry.checkbox.setAttribute('aria-label',`选择 ${record.title || record.address}`);
      entry.checkbox.checked = selected.has(record.id); entry.row.classList.toggle('selected',entry.checkbox.checked);
      entry.time.textContent = timeFormat.format(date); entry.time.dateTime = date.toISOString();
      if (day.list.children[rowIndex] !== entry.row) day.list.insertBefore(entry.row,day.list.children[rowIndex] || null);
      rowIndex++;
    }
    for (const [key, day] of days) if (!activeDays.has(key)) { day.section.remove(); days.delete(key); }
    const all = byID('select-all');
    all.disabled = !filtered.length; all.checked = filtered.length > 0 && selected.size === filtered.length;
    all.indeterminate = selected.size > 0 && selected.size < filtered.length;
    byID('count').textContent = selected.size ? `已选择 ${selected.size} 条` : query ? `找到 ${filtered.length} 条记录` : `${records.length} 条记录`;
    byID('delete').hidden = byID('cancel-selection').hidden = !selected.size;
    byID('clear').disabled = !records.length;
    byID('empty').hidden = !!filtered.length; byID('empty').textContent = query ? '没有找到匹配的历史记录' : '暂无历史记录';
    byID('more').hidden = filtered.length <= limit;
    byID('more').textContent = `显示更多（还有 ${Math.max(0,filtered.length-limit)} 条）`;
  }
  window.perchRestore = view => {
    search.value = view.query || ''; selected = new Set(view.selected || []); limit = view.limit || 100;
    render();
    requestAnimationFrame(() => scrollTo(0,view.scroll || 0));
  };
  window.perchUpdate = state => {
    records = state.records.slice().sort((a,b) => b.date-a.date);
    byID('recording').checked = state.recording; byID('paused').hidden = state.recording;
    byID('error').textContent = state.error; byID('error').hidden = !state.error;
    const restore = !initialized;
    if (restore) {
      initialized = true;
      window.perchRestore(state.viewState || {});
    } else {
      render();
    }
  };
  function confirmDelete(ids) {
    if (!ids.length) return;
    pendingDelete = ids;
    byID('confirmation-detail').textContent = `将删除 ${ids.length} 条历史记录，此操作不可撤销。书签和 Cookie 不受影响。`;
    dialog.showModal();
  }
  search.addEventListener('input', () => { selected.clear(); limit = 100; render(); saveView(); });
  byID('select-all').addEventListener('change', event => {
    selected = event.target.checked ? new Set(filtered.map(record => record.id)) : new Set(); render(); saveView();
  });
  byID('recording').addEventListener('change', event => send('recording',{enabled:event.target.checked}));
  byID('cancel-selection').addEventListener('click', () => { selected.clear(); render(); saveView(); });
  byID('delete').addEventListener('click', () => confirmDelete([...selected]));
  byID('clear').addEventListener('click', () => confirmDelete(records.map(record => record.id)));
  byID('cancel-delete').addEventListener('click', () => dialog.close());
  byID('confirm-delete').addEventListener('click', () => { send('delete',{ids:pendingDelete}); dialog.close(); });
  dialog.addEventListener('close', () => { pendingDelete = []; });
  byID('more').addEventListener('click', () => { limit = Math.min(10000,limit+100); render(); saveView(); });
  timeline.addEventListener('change', event => {
    const row = event.target.closest('.row');
    if (!row || event.target.type !== 'checkbox') return;
    if (event.target.checked) selected.add(row.dataset.id); else selected.delete(row.dataset.id);
    render(); saveView();
  });
  timeline.addEventListener('click', event => {
    const row = event.target.closest('.row'); if (!row) return;
    if (event.target.closest('.visit')) send('open',{id:row.dataset.id,background:event.metaKey});
    if (event.target.closest('.remove')) confirmDelete([row.dataset.id]);
  });
  let scrolling = false;
  addEventListener('scroll', () => {
    if (!scrolling) { scrolling = true; requestAnimationFrame(() => { scrolling = false; saveView(); }); }
  }, {passive:true});
  addEventListener('pagehide',saveView);
  send('ready');
})();
