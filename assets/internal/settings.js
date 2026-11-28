(() => {
  if (location.protocol !== 'perch:' || location.hostname !== 'settings') return;
  const $ = id => document.getElementById(id);
  const make = (tag, text, cls) => {
    const node = document.createElement(tag);
    if (text) node.textContent = text;
    if (cls) node.className = cls;
    return node;
  };
  const send = (action, data = {}) => window.webkit.messageHandlers.perchSettings.postMessage({action, ...data});
  const motion = ms => matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : ms;
  const categories = [
    ['general','常规','M3 5h14M3 10h14M3 15h14M7 3v4m6 1v4m-5 1v4'],
    ['appearance','外观','M10 3a7 7 0 1 0 0 14h2c2 0 2-2 1-3s0-2 1-2h1a2 2 0 0 0 2-2 7 7 0 0 0-7-7ZM6 10h.1M8 6h.1m4 0h.1m2 3h.1'],
    ['ai','AI','M10 2l2 6 6 2-6 2-2 6-2-6-6-2 6-2 2-6Z'],
    ['bookmarks','书签与分组','M5 3h10v14l-5-4-5 4V3Z'],
    ['passwords','密码','M11 8a4 4 0 1 0-7 3 4 4 0 0 0 5 0l5 5h3v-3l-2-2h-2l-2-2V8Z'],
    ['importer','导入导出','M4 8H2l2-3 2 3H4v7h12v-3m0-7H6m10 0v4h-2l2 3 2-3h-2'],
    ['about','关于 Perch','M10 8v6m0-10h.1M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0Z']
  ];
  const currentRoute = () => location.pathname.slice(1) || 'general';
  const main = document.querySelector('main'), pages = new Map();
  let route = currentRoute(), state, building;
  for (const [id, name, path] of categories) {
    const link = make('a');
    link.href = 'perch://settings' + (id === 'general' ? '' : '/' + id);
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const shape = document.createElementNS(svg.namespaceURI, 'path');
    shape.setAttribute('d', path); svg.setAttribute('viewBox', '0 0 20 20');
    svg.setAttribute('aria-hidden', 'true'); svg.append(shape);
    link.append(svg, document.createTextNode(name)); $('navigation').append(link);
    const content = route === id ? $('content') : make('div');
    content.id = 'content';
    pages.set(id, {link, name, content, bindings: [], conditions: []});
    link.addEventListener('click', event => {
      if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      if (navigate(id)) event.preventDefault();
    });
  }
  const bind = update => building.bindings.push(update);
  function section(title) {
    const node = make('section'), card = make('div', '', 'card');
    node.append(make('h2', title), card); building.content.append(node);
    return (label, control, description, when = () => true) => {
      const row = make('div', '', 'row'), text = make('div', label);
      if (description) {
        const detail = make('small', '', 'desc');
        const update = () => { detail.textContent = typeof description === 'function' ? description(state) : description; };
        bind(update); text.append(detail);
      }
      row.append(text);
      if (control) { control.setAttribute('aria-label', label); row.append(control); }
      card.append(row); building.conditions.push([row, when]);
    };
  }
  function input(key, type, options) {
    const node = make(type === 'select' ? 'select' : 'input');
    if (type === 'select') for (const [value, name] of options) {
      const option = make('option', name); option.value = value; node.append(option);
    } else node.type = type;
    node.id = key;
    node.addEventListener('change', () => {
      const value = type === 'checkbox' ? node.checked : type === 'number' ? node.valueAsNumber :
        key === 'aiSendWithCommand' ? node.value === 'true' : node.value;
      if (typeof value !== 'number' || Number.isFinite(value)) send('change', {key, value});
    });
    bind(() => {
      if (type === 'checkbox') node.checked = state.values[key];
      else if (node !== document.activeElement || type === 'select' || !node.value) node.value = state.values[key];
    });
    return node;
  }
  function numeric(key, min, max) {
    const control = input(key, 'number'); control.min = min; control.step = key === 'chatFontSize' ? 1 : 0.1;
    if (max !== undefined) control.max = max;
    return control;
  }
  function slider(key, label, max, unit) {
    const control = make('input'), value = make('output'), wrapper = group(control,value);
    wrapper.classList.add('settings-slider');
    Object.assign(control,{type:'range',id:key,min:0,max});
    control.setAttribute('aria-label',label);
    value.setAttribute('for',key);
    const readout = () => {
      value.textContent = `${control.value} ${unit}`;
      control.setAttribute('aria-valuetext',value.textContent);
    };
    control.addEventListener('input',readout);
    control.addEventListener('change',()=>send('change',{key,value:control.valueAsNumber}));
    bind(() => {
      if (control.valueAsNumber !== state.values[key]) control.value = state.values[key];
      readout();
    });
    return wrapper;
  }
  function button(title, action) {
    const node = make('button', title, 'action');
    node.addEventListener('click', () => send(action)); return node;
  }
  const select = (key, options) => input(key, 'select', options);
  const option = (value, title) => {
    const node = make('option', title); node.value = value; return node;
  };
  function picker(options, value) {
    const node = make('select');
    node.append(...options.map(([key, name]) => option(key, name)));
    if (value != null) node.value = value;
    return node;
  }
  function field(type, value = '') {
    const node = make('input'); node.type = type;
    if (type === 'checkbox') node.checked = Boolean(value);
    else node.value = value;
    if (type === 'password') node.autocomplete = 'off';
    return node;
  }
  function group(...children) {
    const node = make('div', '', 'controls'); node.append(...children); return node;
  }
  function act(title, action) {
    const node = make('button', title, 'action'); node.type = 'button'; node.addEventListener('click', action);
    return node;
  }
  let openMenu;
  function menu(title, label, ...items) {
    const node=make('details','','settings-menu'), summary=make('summary',title), actions=make('div','','settings-menu-items');
    summary.setAttribute('aria-label',label);
    actions.append(...items); node.append(summary,actions);
    node.addEventListener('toggle',()=>{
      if(!node.open){actions.removeAttribute('style');if(openMenu===node)openMenu=null;return;}
      if(openMenu&&openMenu!==node)openMenu.open=false;
      openMenu=node;
      const anchor=summary.getBoundingClientRect(), size=actions.getBoundingClientRect();
      actions.style.right=`${Math.max(8,innerWidth-anchor.right)}px`;
      const top=anchor.bottom+size.height+8<=innerHeight?anchor.bottom:anchor.top-size.height;
      actions.style.top=`${Math.max(8,top)}px`;
    });
    return node;
  }
  document.addEventListener('click',event=>{
    if(!openMenu)return;
    if(!openMenu.contains(event.target)||event.target.closest('.settings-menu-items button'))openMenu.open=false;
  });
  document.addEventListener('keydown',event=>{
    if(!openMenu?.open||event.key!=='Escape')return;
    event.preventDefault();
    openMenu.open=false;openMenu.firstChild.focus({preventScroll:true});
  });
  document.addEventListener('scroll',event=>{
    if(openMenu&&!event.target.closest?.('.settings-menu-items'))openMenu.open=false;
  },true);
  // WebKit does not preserve the order of keys in dictionaries from Swift.
  const snapshotKey = value => JSON.stringify(value, (_, item) =>
    item && typeof item === 'object' && !Array.isArray(item)
      ? Object.fromEntries(Object.keys(item).sort().map(key => [key,item[key]])) : item);
  function replaceIfChanged(container, get, render) {
    let previous;
    bind(() => {
      const data = get(), key = snapshotKey(data);
      if (previous === key) return;
      previous = key; container.replaceChildren(...render(data));
    });
  }
  function releaseNotes(html) {
    const template = make('template');
    template.innerHTML = html;
    // Rebuild formatted text without carrying over remote attributes, links or resources.
    const tags = new Set('h1 h2 h3 h4 h5 h6 p br ul ol li strong b em i del blockquote pre code hr a div span table thead tbody tr th td'.split(' '));
    function copy(parent, source) {
      for (const child of source.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) parent.append(document.createTextNode(child.data));
        else if (tags.has(child.localName)) {
          const tag = child.localName;
          const node = tag === 'a' ? parent : make(tag);
          copy(node, child);
          if (node !== parent) parent.append(node);
        }
      }
    }
    const body = make('div', '', 'release-notes');
    copy(body, template.content);
    return body.textContent.trim() ? [body] : [];
  }
  function credentialField(hasKey) {
    const key = field('password');
    key.placeholder = hasKey ? '已保存，留空保持不变' : '输入 API 密钥';
    return key;
  }
  window.perchClearSettingsSecrets = () => {
    document.querySelectorAll('input[type=password]').forEach(input => { input.value = ''; });
  };
  window.addEventListener('blur', window.perchClearSettingsSecrets);
  window.addEventListener('pagehide', window.perchClearSettingsSecrets);
  window.addEventListener('pageshow', event => { if (event.persisted) send('ready'); });
  function labeled(title, control) {
    const label = make('label', title, 'entry-field');
    label.append(control); return label;
  }
  function buildAI() {
    const overview=make('div','','ai-overview'), editor=make('div','','ai-editor');
    editor.hidden=true; $('content').append(overview,editor);
    let request=0, pending, refreshEditor;
    function command(action,data,done) {
      if(pending)return;
      pending={id:++request,done};
      send(action,{...data,request});
    }
    function block(title) {
      const section=make('section'); section.append(make('h2',title)); overview.append(section); return section;
    }
    function panel(name, description, ...actions) {
      const text=make('div','','ai-meta'), node=make('div','','ai-panel');
      text.append(make('strong',name),make('small',description,'desc'));
      node.append(text,group(...actions)); return node;
    }
    function badge(configured,hasKey=configured) {
      return make('span',`${hasKey?'●':'○'} ${configured?'已配置':'待配置'}`,'ai-badge');
    }
    const providers=block('模型供应商'), cards=make('div','','ai-providers'), add=make('details','','ai-add');
    add.append(make('summary','＋ 添加模型供应商'),group(...state.ai.types.map(kind=>act(kind,()=>{
      add.open=false;
      const ids=new Set(state.ai.providers.map(p=>p.id));
      command('addProvider',{kind},()=>{
        const p=state.ai.providers.find(p=>!ids.has(p.id));
        if(p)openEditor(p);
      });
    }))));
    providers.append(cards,add);
    document.addEventListener('click',e=>{if(!add.contains(e.target))add.open=false;});
    add.addEventListener('keydown',e=>{
      if(e.key==='Escape'&&add.open){add.open=false;add.firstChild.focus();}
    });
    const reset=act('重置 AI 配置',()=>{if(confirm('重置无法读取的 AI 配置？'))send('reset');});
    providers.append(reset);
    bind(()=>{reset.hidden=!state.ai.needsReset; add.hidden=state.ai.needsReset;});
    replaceIfChanged(cards,()=>state.ai.providers,items=>items.map(p=>{
      const card=panel(p.name,`${p.providerID} · ${p.protocol} · ${p.models.length} 个模型`,badge(p.configured,p.hasKey),
        act('编辑',()=>openEditor(p)),act('删除',()=>{if(confirm('删除此模型供应商？'))send('deleteProvider',{id:p.id});}));
      card.dataset.provider=p.id;
      return card;
    }));
    const searchBlock=block('联网搜索供应商'), searchCard=make('div');
    searchBlock.append(searchCard);
    replaceIfChanged(searchCard,()=>[state.ai.searchName,state.ai.searchHasKey,state.ai.searchConfigured],([name,hasKey,configured])=>[
      panel(name,'独立搜索 API，可用于已支持工具调用的模型。',badge(hasKey),
        act(configured?'编辑':'添加',()=>openEditor()),
        ...(configured?[act('删除',()=>{if(confirm('删除搜索供应商？'))send('deleteSearch');})]:[]))
    ]);
    if(state.ai.directory) block('对话存储').append(panel('存储位置',state.ai.directory,button('在 Finder 中打开','directory')));
    const sender=select('aiSendWithCommand',[['false','回车'],['true','Command + 回车']]);
    sender.setAttribute('aria-label','发送消息按键');
    const general=make('div','','ai-panel');
    general.append(make('strong','发送消息按键'),sender); block('常规').append(general);
    block('流式动画').append(
      panel('动画时长','设为 0 时立即显示新内容。',slider('aiRevealDuration','动画时长',1000,'ms')),
      panel('柔边宽度','设为 0 时保留平滑出字，不显示柔边。',slider('aiRevealWidth','柔边宽度',1000,'px')));

    function openEditor(p) {
      if(pending)return;
      const searching=!p, ai=state.ai;
      const name=field('text',p?.name??ai.searchName), url=field('text',p?.baseURL??ai.searchURL),
        key=credentialField(p?.hasKey??ai.searchHasKey), grid=make('div','','ai-grid');
      const providerID=field('text',p?.providerID), api=picker(ai.protocols.map(v=>[v,v]),p?.protocol),
        search=picker([]), enabled=field('checkbox',Boolean(p&&p.search!=='none'));
      const models=new Set(p?.models??[]), manual=field('text'), catalog=make('div','','model-catalog'),
        count=make('small','','desc'), note=make('small','','desc');
      name.placeholder=searching?'搜索供应商名称':'模型供应商名称';
      providerID.placeholder='my-provider'; url.placeholder=searching?'https://api.deepseek.com/v1':'https://example.com/v1';
      manual.placeholder='手动输入模型名称'; manual.setAttribute('aria-label','手动输入模型名称');
      const payload=()=>searching?{name:name.value,baseURL:url.value,key:key.value}:{
        id:p.id,name:name.value,providerID:providerID.value,baseURL:url.value,protocol:api.value,
        search:enabled.checked?search.value:'none',key:key.value,models:[...models]
      };
      let baseline=JSON.stringify(payload());
      const main=$('content').parentElement, overviewScroll=main.scrollTop;
      const close=()=>{
        refreshEditor=null; editor.replaceChildren(); editor.hidden=true; overview.hidden=false;
        overview.animate([{opacity:.75},{opacity:1}],{duration:motion(160)});
        $('title').hidden=false; $('search').disabled=false; filter(); main.scrollTop=overviewScroll;
        const target=p?cards.querySelector(`[data-provider="${p.id}"] button`):searchCard.querySelector('button');
        target?.focus({preventScroll:true});
      };
      const save=(done,force=false)=>{
        const data=payload();
        if(!force&&JSON.stringify(data)===baseline){done?.();return;}
        command(searching?'saveSearch':'saveProvider',data,()=>{
          const saved=searching?state.ai.searchHasKey:state.ai.providers.find(v=>v.id===p.id)?.hasKey;
          if(key.value===data.key)key.value='';
          key.placeholder=credentialField(saved).placeholder;
          baseline=JSON.stringify({...data,key:''}); note.textContent='已保存';
          if(JSON.stringify(payload())===baseline)done?.();
        });
      };
      const heading=make('div','','ai-editor-heading');
      heading.append(act(searching?'‹ AI':'‹ 模型供应商',()=>save(close)),
        make('h2',searching?'编辑联网搜索供应商':'编辑模型供应商'));
      if(searching) grid.append(labeled('搜索服务',make('span','DeepSeek Search')));
      else grid.append(labeled('Provider ID',providerID));
      grid.append(labeled('显示名称',name),labeled('API 地址',url));
      if(!searching)grid.append(labeled('API 协议',api));
      grid.append(labeled('API 密钥',key));
      const remove=act('移除密钥',()=>{
        if(confirm('移除此密钥？'))command(searching?'removeSearchKey':'removeKey',{id:p?.id??''},()=>{key.value='';});
      });
      editor.replaceChildren(heading,grid);
      let lastDiscovery, discoverySource, discovered=[];
      const endpoint=()=>JSON.stringify([api.value,url.value]);
      function renderModels() {
        const names=[...new Set([...discovered,...models])].sort();
        catalog.hidden=!names.length;
        const choices=make('div','','model-choices');
        for(const n of names) {
          const box=field('checkbox',models.has(n)), label=make('label','','model-choice');
          label.title=n; label.append(box,make('span',n));
          box.addEventListener('change',()=>{
            if(box.checked)models.add(n);else models.delete(n);
            updateCount();
          });
          choices.append(label);
        }
        const toolbar=make('div','','ai-editor-heading');
        toolbar.append(make('strong','模型目录'),group(act('全选',()=>{names.forEach(n=>models.add(n));renderModels();}),
          act('清空',()=>{models.clear();renderModels();})));
        catalog.replaceChildren(toolbar,choices);updateCount();
      }
      function updateCount(){count.textContent=`${models.size} 个模型`;}
      const addModel=()=>{
        const n=manual.value.trim();
        if(n.length&&n.length<=512){models.add(n);manual.value='';addModelButton.disabled=true;renderModels();}
      };
      const addModelButton=act('添加',addModel), load=act('拉取模型',()=>{
        discoverySource=endpoint(); send('models',payload());
      });
      if(!searching) {
        addModelButton.disabled=true;
        manual.addEventListener('input',()=>{addModelButton.disabled=!manual.value.trim()||manual.value.trim().length>512;});
        manual.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();addModel();}});
        grid.append(labeled('模型',group(manual,addModelButton,load)));
        const searchOptions=make('div','','ai-search-options'), searchRow=labeled('搜索协议',search);
        const syncSearch=(preferred=search.value)=>{
          const choices=ai.searchCompatibility[api.value]??[];
          search.replaceChildren(...ai.searchModes.filter(v=>choices.includes(v.id)).map(v=>option(v.id,v.title)));
          if(choices.includes(preferred))search.value=preferred;
          enabled.disabled=!choices.length;if(!choices.length)enabled.checked=false;
          searchRow.hidden=!enabled.checked;
        };
        const toggle=make('label','','model-choice');toggle.append(enabled,make('span','联网搜索'));
        searchRow.append(make('small','需供应商支持；聊天中可随时开关。','desc'));
        searchOptions.append(toggle,searchRow); syncSearch(p.search); baseline=JSON.stringify(payload());
        api.addEventListener('change',()=>{syncSearch();discovered=[];renderModels();});
        enabled.addEventListener('change',()=>{searchRow.hidden=!enabled.checked;});
        url.addEventListener('input',()=>{discovered=[];renderModels();});
        editor.append(catalog,searchOptions); renderModels();
      } else editor.append(make('p','使用独立密钥保存。自动模式优先使用模型原生搜索，也可在聊天的地球菜单切换到此供应商。','desc'));
      const footer=make('div','','ai-editor-heading');
      footer.append(group(count,note),group(remove,act('确定',()=>save(undefined,true)),
        ...(!searching?[act('打开聊天',()=>save(()=>send('chat'),true))]:[])));
      editor.append(footer);
      refreshEditor=()=>{
        remove.hidden=!(searching?state.ai.searchHasKey:state.ai.providers.find(v=>v.id===p.id)?.hasKey);
        key.placeholder=credentialField(!remove.hidden).placeholder;
        if(searching)return;
        const {discoveryID,models:names,discovering}=state.ai;
        const stamp=JSON.stringify([discoveryID,names,discovering]);
        if(stamp===lastDiscovery)return;
        const first=lastDiscovery===undefined;lastDiscovery=stamp;
        load.disabled=p.id===discoveryID&&discovering;
        load.textContent=load.disabled?'读取中…':'拉取模型';
        if(first||discoveryID!==p.id||discovering||discoverySource!==endpoint())return;
        discovered=names;renderModels();
        if(names.length)note.textContent=`探测到 ${names.length} 个模型，请勾选需要的模型`;
      };
      refreshEditor();
      overview.hidden=true; editor.hidden=false; $('title').hidden=true; $('search').disabled=true;
      editor.animate([{opacity:.75},{opacity:1}],{duration:motion(160)});
      filter(); main.scrollTop=0; heading.firstChild.focus({preventScroll:true});
    }
    bind(()=>{
      refreshEditor?.();
      if(pending&&state.receipt===pending.id){
        const {done}=pending; pending=null; if(!state.error)done?.();
      }
    });
  }
  function buildPasswords() {
    const settings=section('密码管理');
    settings('询问是否保存网站密码', input('savePasswords','checkbox'));
    const list=make('div','','entries'), editor=make('div','','entries'), query=field('search');
    list.id='password-list';
    query.placeholder='按网站或用户名搜索';
    function edit(item) {
      const origin=field('text',item?.origin), user=field('text',item?.username), secret=field('password');
      secret.autocomplete='new-password';
      origin.disabled=user.disabled=Boolean(item);
      editor.replaceChildren(labeled('网站',origin),labeled('用户名',user),labeled('密码',secret),
        group(act('保存',()=>{
          if (!secret.value) return;
          send('save',{id:item?.id??'',origin:origin.value,username:user.value,secret:secret.value});
          secret.value='';
        }),act('取消',()=>editor.replaceChildren())));
      filter(); (item?secret:origin).focus();
    }
    settings('访问密码库',group(button('授权读取','unlock'),act('启用新密码库',()=>{
      if(confirm('启用新密码库？原密码库将保留。'))send('initialize');
    })));
    settings('已保存的密码',group(query,act('添加密码',()=>edit())));
    settings('密码编辑',editor,'',()=>editor.childElementCount !== 0);
    editor.parentElement.classList.add('password-editor-row');
    new MutationObserver(filter).observe(editor,{childList:true});
    settings('账号列表',list);list.parentElement.classList.add('password-list-row');
    function render() {
      const q=query.value.toLowerCase(), items=state.passwords.filter(p=>`${p.origin} ${p.username}`.toLowerCase().includes(q));
      list.replaceChildren(...items.map(p=>{
        const row=make('div','','password-account'), label=`${p.origin} · ${p.username || '无用户名'}`;
        const name=make('span',label);name.title=label;
        row.append(name,menu('⋯',`${label}的操作`,act('查看',()=>send('reveal',{id:p.id})),
          act('复制',()=>send('copy',{id:p.id})), act('修改',()=>edit(p)),
          act('删除',()=>{if(confirm('删除这个保存的密码？'))send('delete',{id:p.id});})));
        return row;
      }));
      if (!items.length) list.append(make('p','没有匹配的账号'));
    }
    query.addEventListener('input',render);
    let previous;
    bind(()=>{const stamp=JSON.stringify(state.passwords); if(previous!==stamp){previous=stamp;render();}});
  }
  function buildImports() {
    const source=picker(state.imports.sources.map(s=>[s,s]),state.imports.source),
      profiles=picker([]), scopes=make('div','','controls'), checks={};
    const backup=section('Perch 备份'), browser=section('从其他浏览器导入');
    const flags=group(...['cookies','bookmarks','history','passwords'].map((key,i)=>{
      checks[key]=field('checkbox',true); return labeled(['Cookie / 登录态','书签','历史记录','密码'][i],checks[key]);
    }));
    source.addEventListener('change',()=>send('source',{source:source.value}));
    profiles.addEventListener('change',()=>send('profile',{index:Number(profiles.value)}));
    const scopeChecks=state.imports.scopes.map(s=>{
      const b=field('checkbox',true); scopes.append(labeled(s.title,b));return [s.id,b];
    });
    const keys=field('checkbox'), exportButton=act('导出 ZIP…',()=>{
      const selected=scopeChecks.filter(([,b])=>b.checked).map(([id])=>id);
      if (selected.length) send('export',{scopes:selected,keys:keys.checked});
    });
    const importButton=button('导入 ZIP…','import');
    backup('备份范围',scopes);
    backup('包含 AI 密钥（明文）',keys,'仅在需要迁移密钥时开启，并妥善保管 ZIP。');
    backup('备份文件',group(exportButton,importButton),s=>s.imports.backupStatus);
    browser('来源浏览器',source);
    browser('资料配置',profiles,'',s=>s.imports.profiles.length>0);
    browser('资料目录',button('选择目录…','directory'),s=>s.imports.directory);
    browser('导入内容',flags);
    browser('密码 CSV',group(button('选择文件…','passwordFile'),button('清除','clearPasswords')),s=>s.imports.passwordFile,()=>checks.passwords.checked);
    browser('Cookie 文件',group(button('选择文件…','cookieFile'),button('使用浏览器数据','clearCookies')),s=>s.imports.cookieFile,()=>checks.cookies.checked);
    browser('读取权限',group(button('完全磁盘访问权限…','diskAccess'),button('在 Finder 显示 Perch','finder')),
      '若系统拒绝读取，请重新选择资料目录，或按需在系统设置中授权。',s=>s.imports.needsAccess);
    const start=act('开始导入',()=>send('start',Object.fromEntries(Object.entries(checks).map(([key,b])=>[key,b.checked]))));
    browser('导入操作',start,s=>s.imports.status);
    function updateControls() {
      const selected=scopeChecks.some(([,b])=>b.checked);
      keys.disabled=state.importing||!scopeChecks.some(([id,b])=>id==='ai'&&b.checked);
      start.disabled=state.importing||!Object.values(checks).some(b=>b.checked);
      exportButton.disabled=state.importing||!selected;
      importButton.disabled=state.importing;
      filter();
    }
    for(const control of [...Object.values(checks),...scopeChecks.map(([,b])=>b)])control.addEventListener('change',updateControls);
    bind(()=>{
      source.value=state.imports.source;
      profiles.replaceChildren(...state.imports.profiles.map((name,i)=>option(i,name)));
      const idx=state.imports.profiles.indexOf(state.imports.directory.split('/').pop());
      if(idx>=0)profiles.value=idx;
      start.textContent=state.importing?'处理中…':'开始导入';
      updateControls();
    });
  }
  function buildBookmarks() {
    const library=make('div','','bookmark-manager'), scope=make('div','','bookmark-sidebar'), search=field('search'),
      list=make('div','','bookmark-list'), editor=make('div','','bookmark-editor'), selected=new Set(),
      panes=make('div','','bookmark-panes'), right=make('div','','bookmark-results'),
      heading=make('div','','bookmark-heading'), footer=make('div','','bookmark-footer');
    list.id='bookmark-list'; scope.id='bookmark-scope'; search.id='bookmark-search';
    let scopeID=state.library.scope, confirmedScope=scopeID, previous, request=0, pendingScope, savedEditor, rootScope='root';
    const scrollByScope=new Map();
    search.placeholder='搜索名称或网址'; search.setAttribute('aria-label',search.placeholder);
    $('content').append(library);
    right.append(heading,list);panes.append(scope,right);
    function folders(exclude) {
      return [['','个人书签'],...state.library.folders.filter(f=>f.id!==exclude).map(f=>[f.id,f.path])];
    }
    function edit(item, folderMode=false, groupMode=false) {
      const title=field('text',item?.title ?? item?.name), address=field('text',item?.address),
        parent=picker(folders(item?.id),item?.folder ?? item?.parent ?? currentFolder()),
        home=field('checkbox',item?.home!=='false'),
        color=picker(state.library.colors.map(c=>[c.id,c.name]),item?.color);
      const controls=group(act('保存',()=>{
        const data={id:item?.id??'',title:title.value,folder:parent.value,address:address.value,home:home.checked,color:color.value};
        savedEditor={title,request:++request};
        send(groupMode?'editGroup':folderMode?'folder':'save',{...data,request});
      }),act('取消',()=>editor.replaceChildren()));
      editor.replaceChildren(make('strong',groupMode?'编辑分组':folderMode?(item?'重命名目录':'新建目录'):(item?'编辑书签':'添加书签')),
        labeled('名称',title),
        ...(groupMode?[labeled('颜色',color)]:[labeled('目录',parent)]),
        ...(folderMode||groupMode?[]:[labeled('网址',address),labeled('显示在首页',home)]),controls);
      title.focus();
    }
    const currentFolder=()=>scopeID.startsWith('folder:')?scopeID.slice(7):'';
    const qMatch=(...values)=>values.join(' ').toLowerCase().includes(search.value.trim().toLowerCase());
    const isPersonal=()=>['all','root'].includes(scopeID)||scopeID.startsWith('folder:');
    const moveTo=picker([]);
    moveTo.setAttribute('aria-label','移动到目录');
    const moveButton=act('移动',()=>send('move',{ids:editableIDs(),folder:moveTo.value}));
    const currentIDs=()=>[...selected];
    const editableIDs=()=>currentIDs().filter(id=>personalIDs.has(id));
    let personalIDs=new Set(), currentRows=[], selectionAnchor;
    const open=act('打开所选',()=>send('open',{ids:currentIDs()})),
      remove=act('删除所选…',()=>deleteItems(editableIDs())),
      copy=act('复制',()=>send('copy',{ids:currentIDs()})),
      cut=act('剪切',()=>send('cut',{ids:editableIDs()})),
      paste=act('粘贴',()=>send('paste',{folder:currentFolder()}));
    function deleteItems(ids){
      if(ids.length&&confirm(`删除 ${ids.length} 个所选项目？所选目录内的书签也会删除。`))send('delete',{ids});
    }
    const back=act('← 返回上一级',()=>{
      const parent=state.library.folders.find(f=>f.id===currentFolder())?.parent;
      changeScope(parent?'folder:'+parent:rootScope);
    });
    const add=act('添加书签',()=>edit()), addFolder=act('新建目录',()=>edit(null,true)),
      toolbar=group(search,add,addFolder), count=make('small','','desc'),
      selectAll=act('全选',()=>{currentRows.forEach(id=>selected.add(id));syncSelection();}),
      clear=act('取消选择',()=>{selected.clear();syncSelection();}),
      selectionBar=group(selectAll,clear,count), moveMenu=menu('移动到…','移动到目录',moveTo,moveButton),
      clipboard=menu('剪贴板','剪贴板',copy,cut,paste);
    toolbar.classList.add('bookmark-toolbar');selectionBar.classList.add('bookmark-selection');
    library.append(toolbar,editor,selectionBar,panes,footer);
    function changeScope(next, persist=true){
      if(next===scopeID)return;
      if(!search.value)scrollByScope.set(scopeID,list.scrollTop);
      if(next.startsWith('folder:')&&['root','all'].includes(scopeID))rootScope=scopeID;
      scopeID=next;selected.clear();selectionAnchor=null; editor.replaceChildren(); search.value='';
      render();list.scrollTop=scrollByScope.get(next)??0;
      list.getAnimations().forEach(animation=>animation.cancel());
      list.animate([{opacity:.65},{opacity:1}],{duration:motion(160),easing:'ease-out'});
      if(persist){pendingScope=++request;send('scope',{scope:next,request});}
    }
    search.addEventListener('input',()=>{selected.clear();selectionAnchor=null;render();list.scrollTop=0;});
    function syncSelection() {
      for(const row of list.querySelectorAll('button[data-item]'))row.setAttribute('aria-pressed',String(selected.has(row.dataset.item)));
      selectAll.disabled=!currentRows.length; clear.disabled=!selected.size;
      selectAll.textContent=search.value?'全选搜索结果':'全选'; count.textContent=`已选 ${selected.size} 项`;
      copy.disabled=open.disabled=!selected.size;
      cut.disabled=remove.disabled=moveTo.disabled=moveButton.disabled=!editableIDs().length;
      paste.disabled=!isPersonal();
    }
    const folderIcon='M2 5h6l2 2h8v10H2Z', bookmarkIcon=categories[3][2], tabIcon='M2 4h16v12H2Zm0 4h16',
      stackIcon='M5 3h12v12M3 6h11v11H3Z', globeIcon='M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0ZM2 10h16M10 2c5 4 5 12 0 16-5-4-5-12 0-16Z',
      openIcon='M11 3h6v6m0-6-8 8m7 0v6H3V4h6', pencilIcon='m3 13 10-10 4 4L7 17H3Zm8-8 4 4',
      houseIcon='M2 9l8-6 8 6m-2-1v9H4V8';
    function icon(path,color){
      const svg=document.createElementNS('http://www.w3.org/2000/svg','svg'), shape=document.createElementNS(svg.namespaceURI,'path');
      svg.setAttribute('viewBox','0 0 20 20');svg.setAttribute('aria-hidden','true');
      if(color)svg.style.color=color;
      shape.setAttribute('d',path); svg.append(shape);return svg;
    }
    function iconAction(title,path,activate) {
      const b=act('',activate);
      b.className='bookmark-icon-action';b.setAttribute('aria-label',title);b.title=title;b.append(icon(path));return b;
    }
    function groupActions(g) {
      const hide=act('隐藏分组',()=>send('hideGroup',{id:g.id}));hide.disabled=g.hidden;
      return [act('打开分组',()=>send('openGroup',{id:g.id})),hide,
        act('解散分组',()=>{if(confirm('解散分组并保留标签？'))send('dissolveGroup',{id:g.id});}),
        act('删除分组',()=>{if(confirm('删除此标签分组？'))send('deleteGroup',{id:g.id});}),
        act('编辑分组',()=>edit(g,false,true))];
    }
    let sidebarStamp;
    function renderSidebar(lib){
      const stamp=snapshotKey([lib.groups.map(g=>[g.id,g.name,g.color]),Object.keys(lib.imported).sort()]);
      if(stamp!==sidebarStamp){
        sidebarStamp=stamp;
        const active=scope.querySelector(':focus')?.dataset.scope;
        function item(name,target,path,color) {
          const b=act('',()=>changeScope(target)); b.className='bookmark-scope-button'; b.dataset.scope=target;
          b.append(icon(path,color),make('span',name)); b.title=name;
          return b;
        }
        const personal=item('个人书签','root',bookmarkIcon);
        dropOn(personal,'',ids=>send('move',{ids,folder:''}));
        scope.replaceChildren(item('全部书签','all',stackIcon),personal,make('h2','标签组'));
        for(const g of lib.groups)scope.append(item(g.name||'未命名分组','group:'+g.id,folderIcon,lib.colors.find(c=>c.id===g.color)?.color));
        const sources=Object.keys(lib.imported).sort();
        if(sources.length)scope.append(make('h2','浏览器导入'),...sources.map(s=>item(s,'imported:'+s,folderIcon)));
        if(active)[...scope.querySelectorAll('button')].find(b=>b.dataset.scope===active)?.focus({preventScroll:true});
      }
      for(const b of scope.querySelectorAll('button[data-scope]')){
        const active=scopeID===b.dataset.scope||(b.dataset.scope==='root'&&currentFolder());
        if(active&&!b.hasAttribute('aria-current')){
          b.setAttribute('aria-current','true');
          if(scope.scrollWidth>scope.clientWidth){
            const bar=scope.getBoundingClientRect(), item=b.getBoundingClientRect();
            if(item.left<bar.left)scope.scrollLeft+=item.left-bar.left-6;
            else if(item.right>bar.right)scope.scrollLeft+=item.right-bar.right+6;
          }
        } else if(!active)b.removeAttribute('aria-current');
      }
    }
    const expanded=new Set();
    function render(){
      const lib=state.library, folder=currentFolder(), all=scopeID==='all', query=search.value.trim();
      const source=scopeID.startsWith('imported:')?scopeID.slice(9):null;
      const g=lib.groups.find(g=>scopeID==='group:'+g.id);
      const title=g?(g.name||'未命名分组'):source!==null?`${source}/ · 只读`:
        folder?lib.folders.find(f=>f.id===folder)?.path:all?'全部书签':'个人书签';
      renderSidebar(lib);
      add.disabled=addFolder.disabled=source!==null||Boolean(g);
      add.style.visibility=addFolder.style.visibility=selectionBar.style.visibility=g?'hidden':'';
      back.hidden=!folder; heading.replaceChildren(make('strong',title),group(back,
        ...(g?[menu('⋯',`${title}的操作`,...groupActions(g))]:[])));
      currentRows=[];
      const order=lib.sites.map(s=>s.id), sitesByFolder=new Map(), foldersByParent=new Map();
      for(const [items, key, map] of [[lib.sites,'folder',sitesByFolder],[lib.folders,'parent',foldersByParent]]){
        for(const item of items){
          if(!map.has(item[key]))map.set(item[key],[]);
          map.get(item[key]).push(item);
        }
      }
      function row(item,path,activate,actions=[],inline=[]){
        const node=make('div','','bookmark-item'), label=act('',event=>{
          if(!item.id||g){activate();return;}
          if(event.shiftKey&&selectionAnchor){
            const visible=[...list.querySelectorAll('button[data-item]')].filter(b=>!b.closest('[inert]')).map(b=>b.dataset.item);
            const a=visible.indexOf(selectionAnchor), b=visible.indexOf(item.id);
            if(a>=0&&b>=0){visible.slice(Math.min(a,b),Math.max(a,b)+1).forEach(id=>selected.add(id));syncSelection();return;}
          }
          if(event.metaKey){if(selected.has(item.id))selected.delete(item.id);else selected.add(item.id);}
          else {selected.clear();selected.add(item.id);}
          selectionAnchor=item.id;syncSelection();
        });
        label.className='bookmark-item-name'; label.title=item.address??item.title;
        const text=make('span');text.append(make('span',item.title));
        if(item.address)text.append(make('small',item.address,'desc'));
        label.append(icon(path),text);
        if(item.id&&!g){
          label.dataset.item=item.id;currentRows.push(item.id);
          label.addEventListener('dblclick',activate);
          label.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();activate();}});
        }
        const openRow=iconAction(`打开 ${item.title}`,openIcon,activate);openRow.classList.add('bookmark-open');
        node.append(label,...inline,openRow);
        if(actions.length){
          const actionsMenu=menu('⋯',`${item.title}的操作`,...actions);
          node.append(actionsMenu);
          node.addEventListener('contextmenu',e=>{
            e.preventDefault();
            actionsMenu.open=true;actionsMenu.firstChild.focus();
          });
        }
        return node;
      }
      function branch(key,node,children,disclosure=true) {
        if(!children.length&&!disclosure)return node;
        const branch=make('div','','bookmark-branch'), nested=make('div','','bookmark-children'), clip=make('div');
        const toggle=act('',()=>{
          const open=!nested.hasAttribute('data-expanded');
          if(open)expanded.add(key);else expanded.delete(key);
          setExpanded(open);
        });
        toggle.className='bookmark-disclosure';
        toggle.append(icon('m7 4 6 6-6 6'));
        node.querySelector('.bookmark-item-name svg').classList.add('folder-glyph');
        function setExpanded(open){
          nested.toggleAttribute('data-expanded',open);nested.inert=!open;
          toggle.setAttribute('aria-expanded',String(open));
          toggle.setAttribute('aria-label',open?'折叠目录':'展开目录');
        }
        toggle.disabled=!children.length;
        setExpanded(Boolean(query)||expanded.has(key));
        node.prepend(toggle);clip.append(...children);nested.append(clip);
        branch.append(node,nested);return branch;
      }
      function site(s,siblings,personal) {
        const actions=[];
        const inline=[];
        if(personal){
          const toggleHome=()=>send('home',{id:s.id}), homeTitle=s.home==='false'?'显示在首页':'从首页移除';
          const home=iconAction(`${homeTitle} ${s.title}`,houseIcon,toggleHome);
          home.classList.toggle('bookmark-on-home',s.home!=='false');
          inline.push(iconAction(`编辑 ${s.title}`,pencilIcon,()=>edit(s)),home);
          actions.push(act('编辑',()=>edit(s)),act(homeTitle,toggleHome),act('删除…',()=>deleteItems([s.id])));
          if(!query)for(const [delta,label] of [[-1,'上移'],[1,'下移']]){
            const target=siblings[siblings.indexOf(s)+delta]; if(!target)continue;
            actions.push(act(label,()=>{
              const next=[...order],i=next.indexOf(s.id),j=next.indexOf(target.id);[next[i],next[j]]=[next[j],next[i]];
              send('reorder',{ids:next});
            }));
          }
        }
        actions.push(act('复制书签',()=>send('copy',{ids:[s.id]})),act('复制网址',()=>send('copyAddress',{id:s.id})),
          act('预览',()=>send('preview',{id:s.id})));
        const node=row(s,globeIcon,()=>send('open',{ids:[s.id]}),actions,inline);
        if(personal)drag(node,s.id,ids=>{
          if(query||!ids.every(id=>siblings.some(site=>site.id===id)))return;
          const moving=order.filter(id=>ids.includes(id)), rest=order.filter(id=>!ids.includes(id));
          rest.splice(rest.indexOf(s.id),0,...moving);send('reorder',{ids:rest});
        });
        return node;
      }
      function personalRows(parent,matched=false) {
        const result=[];
        for(const f of foldersByParent.get(parent)??[]){
          const self=matched||qMatch(f.title), children=personalRows(f.id,self);
          if(!self&&!children.length)continue;
          const node=row(f,folderIcon,()=>changeScope('folder:'+f.id),[
            act('新建子目录',()=>{changeScope('folder:'+f.id);edit(null,true);}),
            act('重命名目录',()=>edit(f,true)),act('粘贴到此目录',()=>send('paste',{folder:f.id})),
            act('复制目录',()=>send('copy',{ids:[f.id]})),act('删除目录…',()=>deleteItems([f.id]))
          ]);
          drag(node,f.id,ids=>send('move',{ids,folder:f.id}));
          result.push(branch(f.id,node,children));
        }
        const siblings=sitesByFolder.get(parent)??[];
        for(const s of siblings)if(matched||qMatch(s.title,s.address))result.push(site(s,siblings,true));
        return result;
      }
      function importedRows(items,matched=false){
        const result=[];
        for(const item of items) {
          const self=matched||qMatch(item.title,item.address??'');
          if(!item.children){if(self)result.push(site(item,[],false));continue;}
          const children=importedRows(item.children,self);
          if(!self&&!children.length)continue;
          const node=row(item,folderIcon,()=>node.querySelector('.bookmark-disclosure').click(),[
            act('复制目录',()=>send('copy',{ids:[item.id]}))
          ]);
          result.push(branch(item.id,node,children));
        }
        return result;
      }
      const entries=isPersonal()?personalRows(folder):[], tabs=g?.tabs.filter(t=>qMatch(t.title,t.address))??[];
      if(source!==null)entries.push(...importedRows(lib.imported[source]??[]));
      if(all)for(const [name,items] of Object.entries(lib.imported).sort(([a],[b])=>a.localeCompare(b))){
        const children=importedRows(items,qMatch(name));
        if(!query||children.length)entries.push(branch('imported:'+name,row({title:`${name}/ · 只读`},folderIcon,()=>changeScope('imported:'+name)),children));
      }
      if(g)for(const tab of tabs)entries.push(row(tab,tabIcon,()=>send('openGroup',{id:g.id,tab:tab.id})));
      list.replaceChildren(...(entries.length?entries:[make('p',g?(query?'没有匹配的标签':'此处没有标签'):(query?'没有匹配的书签':'此处没有书签'),'desc')]));
      const total=items=>items.reduce((n,item)=>n+(item.children?total(item.children):1),0);
      const bookmarkCount=lib.sites.length+Object.values(lib.imported).reduce((n,items)=>n+total(items),0);
      footer.replaceChildren(...(g?[make('span'),make('small',`${g.hidden?'已隐藏':'已打开'} · ${tabs.length} 个标签`,'desc')]:
        [group(open,remove,moveMenu,clipboard),make('small',`${bookmarkCount} 个书签`,'desc')]));
      syncSelection();
    }
    let dragging=[];
    function drag(row,id,drop) {
      row.draggable=true;
      row.addEventListener('dragstart',event=>{
        dragging=selected.has(id)?editableIDs():[id];
        event.dataTransfer.setData('application/x-perch-bookmarks','');
        event.dataTransfer.effectAllowed='move';
      });
      row.addEventListener('dragend',()=>{dragging=[];});
      dropOn(row,id,drop);
    }
    function dropOn(row,id,drop) {
      row.addEventListener('dragover',event=>{
        if(dragging.length&&!dragging.includes(id)){event.preventDefault();event.dataTransfer.dropEffect='move';}
      });
      row.addEventListener('drop',event=>{
        if(!dragging.length||dragging.includes(id))return;
        event.preventDefault();drop(dragging);dragging=[];
      });
    }
    document.addEventListener('keydown',event=>{
      if(route!=='bookmarks'||!event.metaKey||event.target.closest('input:not([type=checkbox]),textarea,select,[contenteditable]')||scopeID.startsWith('group:'))return;
      const actions={c:'copy',x:'cut',v:'paste'};
      const action=actions[event.key];
      if(!action||(action==='paste'?!isPersonal():action==='cut'?!editableIDs().length:!selected.size))return;
      event.preventDefault();send(action,{ids:action==='cut'?editableIDs():currentIDs(),folder:currentFolder()});
    });
    bind(()=>{
      const {scope:incomingScope,...lib}=state.library, stamp=snapshotKey(lib);
      if(savedEditor&&state.receipt===savedEditor.request){
        if(!state.error&&editor.contains(savedEditor.title))editor.replaceChildren();
        savedEditor=null;
      }
      const updated=stamp!==previous;
      if(updated){
        previous=stamp;
        const destination=moveTo.value;moveTo.replaceChildren(...folders().map(([key,title])=>option(key,title)));
        moveTo.value=[...moveTo.options].some(o=>o.value===destination)?destination:'';
        personalIDs=new Set([...lib.sites,...lib.folders].map(item=>item.id));
        const valid=new Set(personalIDs);
        function visit(items){for(const item of items){valid.add(item.id);if(item.children)visit(item.children);}}
        Object.values(lib.imported).forEach(visit);
        for(const id of selected)if(!valid.has(id))selected.delete(id);
      }
      const acknowledged=pendingScope&&pendingScope===state.receipt;
      if(acknowledged)pendingScope=null;
      let next=scopeID;
      if(!pendingScope&&(acknowledged||incomingScope!==confirmedScope)){
        confirmedScope=incomingScope;next=incomingScope;
      }
      const validScope=next.startsWith('folder:')?lib.folders.some(f=>'folder:'+f.id===next):
        next.startsWith('group:')?lib.groups.some(g=>'group:'+g.id===next):
        next.startsWith('imported:')?Object.hasOwn(lib.imported,next.slice(9)):['all','root'].includes(next);
      if(!validScope)next='root';
      if(next!==scopeID)changeScope(next,false);
      else if(updated)render();
    });
  }
  function build(id) {
    switch (id) {
    case 'general': {
      const launch = section('启动与窗口');
      launch('登录 Mac 时启动 Perch', input('login','checkbox'), s => s.loginNote);
      launch('启动 Perch 时打开主窗口', input('showWindowOnLaunch','checkbox'));
      launch('主窗口跟随鼠标显示', input('followMouseOnShow','checkbox'), '在鼠标所在的屏幕附近打开窗口');
      launch('系统登录项', button('打开系统设置','loginItems'));
      const search = section('搜索引擎');
      search('默认搜索', select('searchEngine', [['google','Google'],['bing','Bing'],['duckduckgo','DuckDuckGo'],['custom','自定义']]));
      search('自定义搜索网址', input('customSearchURL','text'), '用 {query} 代表关键词', s => s.values.searchEngine === 'custom');
      const preview = section('链接临时预览');
      preview('启用链接预览', input('linkPreviewEnabled','checkbox'));
      preview('等待秒数', numeric('linkPreviewDelay',0), '0 表示立即显示', s => s.values.linkPreviewEnabled);
      const agent = section('浏览器标识');
      agent('User-Agent', select('uaMode',[['safari','Safari（推荐）'],['chrome','Chrome 兼容'],['system','系统 WebKit'],['custom','自定义']]), s => s.userAgent);
      agent('自定义 User-Agent', input('customUA','text'), '', s => s.values.uaMode === 'custom');
      const shortcuts=section('快捷键');
      for(const [target,label] of [['open','打开窗口'],['close','收起窗口'],['toggle','隐藏 / 展示窗口'],['preview','链接预览触发键']]){
        const record=act('录制',()=>send('record',{target}));
        bind(()=>{record.textContent=state.recording===(target==='preview'?'linkPreview':target)?'按键…（Esc 取消）':state.shortcuts[target]||'录制';});
        shortcuts(label,group(record,...(target==='preview'?[]:[act('清除',()=>send('clearShortcut',{target}))])));
      }
      break;
    }
    case 'appearance': {
      const colors = make('div','','swatches');
      let preview;
      function previewTheme(theme) {
        clearTimeout(preview);
        preview=setTimeout(()=>{if(route==='appearance')send('previewTheme',{theme});},500);
      }
      for (const t of state.themes) {
        const color = make('button','','swatch');
        color.style.background = t.color; color.title = t.name + '色主题';
        color.setAttribute('aria-label',color.title);
        color.addEventListener('pointerenter',()=>previewTheme(t.id));
        color.addEventListener('pointerleave',()=>previewTheme(''));
        color.addEventListener('click', () => {clearTimeout(preview);send('change', {key:'theme',value:t.id});});
        bind(() => color.setAttribute('aria-pressed', String(state.values.theme === t.id)));
        colors.append(color);
      }
      window.addEventListener('blur',()=>clearTimeout(preview));
      window.addEventListener('pagehide',()=>clearTimeout(preview));
      building.leave=()=>clearTimeout(preview);
      section('主题')('主题色', colors);
      const reset=act('恢复默认',()=>send('change',{key:'chatFontSize',value:13}));
      reset.id='reset-chat-font';
      section('字体')('Chat 字号（pt）', group(numeric('chatFontSize',11,22),reset), '默认 13 pt');
      break;
    }
    case 'ai': buildAI(); break;
    case 'bookmarks': buildBookmarks(); break;
    case 'passwords': buildPasswords(); break;
    case 'importer': buildImports(); break;
    case 'about': {
      const check = button('检查更新','check');
      const release = button('下载更新','release');
      const version = make('span', '', 'about-value'), status = make('span', '', 'about-value');
      const controls = group(status, check, release);
      controls.classList.add('about-controls');
      check.id='check-update'; release.id='view-release';
      bind(() => {
        version.textContent = `版本 ${state.version}`;
        status.textContent = state.update ? `发现新版本 ${state.update}` : state.updateMessage;
        check.hidden=Boolean(state.update); release.hidden=!state.update;
        check.disabled = state.checking; check.textContent = state.checking ? '正在检查…' : '检查更新';
      });
      const about = section('关于');
      about('Perch', version);
      about('开源仓库', button('在 GitHub 打开','source'));
      about('软件更新', controls);
      const notes = make('div');
      replaceIfChanged(notes, () => state.releaseNotes || '', releaseNotes);
      const changes = section('发布说明');
      changes('', notes, null, () => Boolean(notes.firstChild));
      notes.parentElement.classList.add('release-notes-row');
      break;
    }
    }
  }
  function filter() {
    const query = $('search').value.trim().toLowerCase();
    if(route==='bookmarks')return;
    if(route==='ai'){
      const overview=$('content').querySelector('.ai-overview');
      if(!overview)return;
      for(const section of overview.children)section.hidden=Boolean(query&&!section.textContent.toLowerCase().includes(query));
      $('empty').hidden=!query||overview.hidden||Boolean(overview.querySelector('section:not([hidden])'));
      return;
    }
    for (const [row, when] of pages.get(route).conditions) {
      const title = row.closest('section').querySelector('h2').textContent;
      row.hidden = !when(state) || !(title + ' ' + row.textContent).toLowerCase().includes(query);
    }
    for (const section of $('content').children) section.hidden = !section.querySelector('.row:not([hidden])');
    $('empty').hidden = !query || Boolean($('content').querySelector('section:not([hidden])'));
  }
  function prepare(id) {
    const page = pages.get(id);
    if (page.built) return;
    building = page;
    build(id);
    building = null;
    page.built = true;
  }
  function show(page) {
    page.link.setAttribute('aria-current', 'page');
    main.dataset.route = route;
    $('title').textContent = page.name;
    $('title').hidden = page.titleHidden || false;
    $('search').hidden = route === 'bookmarks';
    $('search').disabled = $('title').hidden;
    $('search').value = page.query || '';
    $('empty').hidden = true;
  }
  function activate() {
    const id = currentRoute();
    if (id !== route) {
      const old = pages.get(route), page = pages.get(id);
      if (!page) return;
      old.scroll = main.scrollTop;
      // WebKit resets the scroll offsets of elements removed from the document.
      old.innerScroll = [...old.content.querySelectorAll('.bookmark-sidebar,.bookmark-list,.model-choices')]
        .map(node => [node, node.scrollLeft, node.scrollTop]);
      old.query = $('search').value;
      old.titleHidden = $('title').hidden;
      old.focus = old.content.contains(document.activeElement) ? document.activeElement : null;
      old.leave?.();
      if (openMenu) { openMenu.open = false; openMenu = null; }
      const add = old.content.querySelector('.ai-add[open]');
      if (add) add.open = false;
      window.perchClearSettingsSecrets();
      old.link.removeAttribute('aria-current');
      old.content.replaceWith(page.content);
      route = id;
      show(page);
      if (page.state) render(page.state, false);
      else if (page.built && state) render({...state, error: ''});
      else { state = undefined; $('status').hidden = true; }
      main.scrollTop = page.scroll || 0;
      for (const [node, left, top] of page.innerScroll || []) node.scrollTo(left, top);
      if (page.content.contains(page.focus)) page.focus.focus({preventScroll:true});
    }
    send('ready');
  }
  function navigate(id, url = pages.get(id)?.link.href) {
    const page = pages.get(id);
    if (!page) return false;
    if (url === location.href) return true;
    try { history.pushState(null, '', url); }
    catch { return false; }
    activate();
    return true;
  }
  function render(next, refresh = true) {
    const page = pages.get(route);
    state = next;
    if (refresh) {
      prepare(route);
      for (const update of page.bindings) update();
    }
    $('status').textContent = next.error ? '设置未生效：' + next.error : '';
    $('status').hidden = !next.error;
    filter();
  }
  $('search').addEventListener('input', () => { if (state) filter(); });
  window.addEventListener('popstate', activate);
  window.perchNavigateSettings = navigate;
  window.perchUpdate = next => {
    const page = pages.get(next.route);
    if (!page) return;
    if (next.route !== route) {
      if (next.receipt) page.receipt = next.receipt;
      return;
    }
    if (page.receipt && !next.receipt) next.receipt = page.receipt;
    page.receipt = null;
    page.state = next;
    render(next);
    // Build lightweight categories from the shared snapshot without fetching their data.
    for (const id of ['general', 'appearance', 'about']) prepare(id);
  };
  show(pages.get(route));
  send('ready');
})();
