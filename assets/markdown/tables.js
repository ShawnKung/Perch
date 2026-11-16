const tableRows = table => Array.from(table.rows, row => Array.from(row.cells, cell => cell.textContent));
const spreadsheetCell = value => /^[\s]*[=+\-@]/.test(value) ? "'" + value : value;
window.tableCSV = rows => rows.map(row => row.map(value => '"' + spreadsheetCell(value).replace(/"/g, '""') + '"').join(',')).join('\r\n');
window.enhanceTable = table => {
  const wrap = document.createElement('div'), tools = document.createElement('div');
  wrap.className = 'table-wrap'; tools.className = 'table-tools';
  table.replaceWith(wrap); wrap.append(tools, table);
  const action = (label, run) => {
    const button = document.createElement('button'); button.textContent = label; button.onclick = run; tools.append(button);
  };
  action('复制表格', () => window.webkit.messageHandlers.markdown.postMessage({
    copy:tableRows(table).map(row => row.map(value => spreadsheetCell(value).replace(/\t/g,' ').replace(/\r?\n/g,' ')).join('\t')).join('\n')
  }));
  action('导出 CSV', () => window.webkit.messageHandlers.markdown.postMessage({csv:tableCSV(tableRows(table))}));
  if (!window.tableExpanded) action('展开', () => window.webkit.messageHandlers.markdown.postMessage({table:tableRows(table)}));
  let sortedColumn = -1, direction = 1;
  Array.from(table.tHead?.rows[0]?.cells || []).forEach((cell, column) => {
    const label = cell.textContent, button = document.createElement('button');
    button.textContent = label; button.title = '按此列排序'; cell.replaceChildren(button);
    button.onclick = () => {
      direction = sortedColumn === column ? -direction : 1; sortedColumn = column;
      Array.from(table.tHead.rows[0].cells).forEach((header, index) => header.setAttribute('aria-sort',
        index === column ? direction === 1 ? 'ascending' : 'descending' : 'none'));
      const number = value => /^[-+]?(?:\d+\.?\d*|\.\d+)$/.test(value.trim()) ? Number(value) : NaN;
      for (const body of table.tBodies) {
        const rows = Array.from(body.rows);
        rows.sort((a,b) => {
          const left = a.cells[column]?.textContent || '', right = b.cells[column]?.textContent || '';
          const x = number(left), y = number(right);
          return direction * (Number.isFinite(x) && Number.isFinite(y) ? x - y : left.localeCompare(right,undefined,{numeric:true}));
        });
        body.append(...rows);
      }
    };
  });
};
window.renderTable = rows => {
  window.tableExpanded = true;
  const table = document.createElement('table'), head = table.createTHead().insertRow(), body = table.createTBody();
  rows.forEach((row,index) => {
    const target = index === 0 ? head : body.insertRow();
    row.forEach(value => {const cell=document.createElement(index === 0 ? 'th' : 'td');cell.textContent=value;target.append(cell);});
  });
  document.getElementById('content').replaceChildren(table); enhanceTable(table);
  document.documentElement.style.overflow='auto'; document.body.style.overflow='auto'; document.body.style.padding='12px';
};
window.enhanceCitations = (root, sources) => {
  const known = new Map(sources.map(source => [source.url, source]));
  root.querySelectorAll('a').forEach(link => {
    const source = known.get(link.href);
    if (!source) return;
    link.classList.add('source-citation');
    link.setAttribute('aria-label', link.textContent + ' · ' + source.title);
    const show=()=>{
      const r=link.getBoundingClientRect();
      window.webkit.messageHandlers.markdown.postMessage({citation:{
        action:'enter',url:source.url,x:r.x,y:r.y,width:r.width,height:r.height
      }});
    };
    const hide=()=>window.webkit.messageHandlers.markdown.postMessage({citation:{action:'leave',url:source.url}});
    link.addEventListener('mouseenter',show); link.addEventListener('mouseleave',hide);
    link.addEventListener('focus',show); link.addEventListener('blur',hide);
  });
};
