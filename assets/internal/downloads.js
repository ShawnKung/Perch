(() => {
  if (location.protocol !== 'perch:' || location.hostname !== 'downloads') return;
  const send = (action, id) => window.webkit.messageHandlers.perchInternal.postMessage({action, id});
  const icons = {
    file: '<path d="M5 2h8l6 6v14H5z"/><path d="M13 2v6h6"/>',
    copy: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
    reveal: '<path d="M2 6h8l2 2h10v12H2z"/>',
    remove: '<path d="m6 6 12 12M18 6 6 18"/>'
  };
  function svg(name) {
    const element = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    element.setAttribute('viewBox', '0 0 24 24');
    element.setAttribute('aria-hidden', 'true');
    element.innerHTML = icons[name]; // Static application artwork, never record content.
    return element;
  }
  const rows = new Map();
  function makeRow(record) {
    const row = document.createElement('div'); row.className = 'row'; row.dataset.id = record.id;
    const file = document.createElement('button'); file.className = 'file'; file.dataset.action = 'open';
    const image = document.createElement('img'); image.className = 'icon'; image.alt = '';
    const fallback = document.createElement('span'); fallback.className = 'fallback'; fallback.append(svg('file'));
    const info = document.createElement('span'); info.className = 'info';
    const name = document.createElement('span'); name.className = 'name';
    const detail = document.createElement('span'); detail.className = 'detail';
    info.append(name, detail); file.append(image, fallback, info);
    const actions = document.createElement('div'); actions.className = 'actions';
    for (const [action, label] of [['copy','复制下载链接'],['reveal','在文件夹中显示'],['remove','删除下载记录']]) {
      const button = document.createElement('button');
      button.dataset.action = action; button.title = label; button.setAttribute('aria-label',label);
      button.append(svg(action)); actions.append(button);
    }
    row.append(file, actions);
    return {row,file,image,fallback,name,detail,reveal:actions.children[1]};
  }
  window.perchUpdate = state => {
    const ids = new Set(state.records.map(record => record.id));
    for (const [id, entry] of rows) if (!ids.has(id)) { entry.row.remove(); rows.delete(id); }
    const container = document.getElementById('records');
    state.records.forEach((record, index) => {
      const entry = rows.get(record.id) || makeRow(record); rows.set(record.id, entry);
      entry.name.textContent = record.name; entry.detail.textContent = record.detail;
      entry.file.disabled = !record.available; entry.reveal.disabled = !record.available;
      entry.file.setAttribute('aria-label',record.name);
      if (entry.image.getAttribute('src') !== record.icon) entry.image.setAttribute('src',record.icon);
      entry.image.hidden = !record.icon; entry.fallback.hidden = !!record.icon;
      if (container.children[index] !== entry.row) container.insertBefore(entry.row,container.children[index] || null);
    });
    document.getElementById('clear').disabled = !state.records.length;
    document.getElementById('empty').hidden = !!state.records.length;
    const error = document.getElementById('error');
    error.textContent = state.error || ''; error.hidden = !state.error;
  };
  document.addEventListener('click', event => {
    const button = event.target.closest('button');
    if (!button || button.disabled) return;
    if (button.id === 'clear') send('clear');
    else if (button.dataset.action) send(button.dataset.action,button.closest('.row').dataset.id);
  });
  send('ready');
})();
