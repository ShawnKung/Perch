(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const scroll = $('scroll'), messages = $('messages'), composer = $('composer');
  let state = null, revision = 0, composing = false, mention = null, mentionIndex = 0, focus = '';
  let followsBottom = true, anchor = null, applying = false, lastUser = '', edit = '', renderID = 0;
  let restoredLayout = '';
  const layoutSize = () => [scroll.clientWidth,scroll.clientHeight,messages.scrollHeight].join(':');
  const cards = new Map(), selections = new Map(), fileCards = new Set();
  window.nativeCitationHover = true;
  window.updateChatHover = (x,y) => {
    const target = Number.isFinite(x) && Number.isFinite(y) ? document.elementFromPoint(x,y) : null;
    for (const card of cards.values()) card.root.classList.toggle('hovered',card.root === target?.closest('.message'));
    for (const element of messages.querySelectorAll('.icon-button,.followup-send,.markdown pre'))
      element.classList.toggle('hovered',!!target && element.contains(target));
    return !!target?.closest('#toolbar');
  };
  const graphemes = new Intl.Segmenter(undefined,{granularity:'grapheme'});
  const characterCount = value => Array.from(graphemes.segment(value)).length;
  const send = (action, data = {}) => {
    if (state) window.webkit.messageHandlers.perchInternal.postMessage({action, owner:state.owner, conversation:state.conversation, ...data});
  };
  const node = (tag, className = '', text = '') => {
    const element = document.createElement(tag); element.className = className; element.textContent = text; return element;
  };
  const button = (label, run, className = '') => {
    const element = node('button', className, label); element.type = 'button'; element.onclick = run; return element;
  };
  const paths = {
    plus:'M12 4v16M4 12h16', send:'M12 20V4m-6 6 6-6 6 6', stop:'M7 7h10v10H7z',
    globe:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0ZM3 12h18M12 3c-5 5-5 13 0 18 5-5 5-13 0-18Z',
    close:'m6 6 12 12M6 18 18 6', copy:'M8 8h12v13H8zM16 8V3H3v13h5',
    edit:'M4 10h10a6 6 0 0 1 0 12M4 10l6-6M4 10l6 6',
    fork:'M12 21v-7c0-4-4-6-8-10M12 14c0-4 4-6 8-10', fill:'M12 4v16M4 12h16',
    quote:'M3 13V9a5 5 0 0 1 5-5v3a2 2 0 0 0-2 2h4v10H3ZM14 13V9a5 5 0 0 1 5-5v3a2 2 0 0 0-2 2h4v10h-7Z',
    photo:'M3 4h18v16H3ZM3 17l6-6 5 5 3-3 4 4M16 8h.01',
    document:'M14 3H5v18h14V8ZM14 3v5h5M8 12h8M8 16h8',
    right:'M4 12h16m-6-6 6 6-6 6',
    bubble:'M5 4h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-7l-5 4v-4H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2ZM7 11h.01M12 11h.01M17 11h.01',
    quoteBubble:'M5 3h14a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-7l-5 4v-4H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2ZM7 8h3v4H7v-1m7-3h3v4h-3v-1',
    removeFile:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z'
  };
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg','svg');
    svg.setAttribute('viewBox','0 0 24 24'); svg.setAttribute('class','icon'); svg.setAttribute('aria-hidden','true');
    const path = document.createElementNS(svg.namespaceURI,'path'); path.setAttribute('d',paths[name]); svg.append(path);
    if (name === 'fork') {
      const heads=document.createElementNS(svg.namespaceURI,'path');heads.setAttribute('d','M3 3l1 7 6-6ZM21 3l-1 7-6-6Z');
      heads.setAttribute('fill','currentColor');heads.setAttribute('stroke','none');svg.append(heads);
    }
    if (name === 'removeFile') {
      path.setAttribute('fill','currentColor');path.setAttribute('stroke','none');
      const cross=document.createElementNS(svg.namespaceURI,'path');cross.setAttribute('d','M8 8l8 8M8 16l8-8');
      cross.setAttribute('stroke','var(--perch-mint)');svg.append(cross);
    }
    return svg;
  }
  function iconButton(name, label, run) {
    const b = button('',run,'icon-button'); b.append(icon(name)); b.title = label; b.setAttribute('aria-label',label); return b;
  }
  for (const [id,name] of [['attach','plus'],['send','send'],['stop','stop'],['search-enabled','globe']]) $(id).append(icon(name));
  function text(element, value) { if (element.textContent !== value) element.textContent = value; }
  // NSDictionary bridge keys have no stable order; DOM identity must depend on values.
  const signature = value => JSON.stringify(value,(_,item) => item && typeof item === 'object' && !Array.isArray(item)
    ? Object.fromEntries(Object.keys(item).sort().map(key => [key,item[key]])) : item);
  function preserve(key, element, signature, render) {
    if (element[key] === signature) return;
    element[key] = signature; render();
  }
  function link(title, url) {
    const a = node('a','',title);
    try {
      const parsed = new URL(url);
      if (['http:','https:'].includes(parsed.protocol) && !parsed.username && !parsed.password) {
        a.href = parsed.href; a.onclick = event => { event.preventDefault(); send('open',{url:parsed.href}); };
      }
    } catch (_) {}
    return a;
  }
  window.answerRootForSelection = selection => {
    const element = selection?.anchorNode?.nodeType === 1 ? selection.anchorNode : selection?.anchorNode?.parentElement;
    return element?.closest('.markdown');
  };
  window.perchMarkdown = payload => {
    if (payload.quote) {
      const root = window.answerRootForSelection(getSelection());
      if (root) send('quote',{id:root.closest('.message').dataset.id,text:payload.quote,range:payload.range});
    } else if (payload.removeQuote) {
      send('removeQuote',{id:payload.messageID,text:payload.text});
    } else send('markdown',{payload});
  };
  window.updateDiagramBounds = () => {};
  const style = node('style'); style.textContent = ''; document.head.append(style);
  window.perchDiagramStyle = css => { style.textContent = css; };
  function capture(allowBottomFollow = true) {
    if (!state || applying || !cards.size || scroll.clientHeight === 0) return;
    // Layout-generated scroll events can arrive before ResizeObserver; preserve the previous anchor first.
    if (layoutSize() !== restoredLayout) { restore(); return; }
    const top = scroll.getBoundingClientRect().top;
    const card = Array.from(messages.children).find(card => card.dataset.id && card.getBoundingClientRect().bottom > top) ||
      Array.from(messages.children).reverse().find(card => card.dataset.id);
    if (!card) return;
    anchor = {messageID:card.dataset.id,offset:top-card.getBoundingClientRect().top};
    followsBottom = allowBottomFollow && scroll.scrollHeight-scroll.clientHeight-scroll.scrollTop < 4;
    send('reading',{id:anchor.messageID,offset:anchor.offset});
  }
  function restore() {
    if (!state || scroll.clientHeight === 0) return;
    restoredLayout = layoutSize();
    applying = true;
    if (followsBottom) scroll.scrollTop = scroll.scrollHeight;
    else if (anchor) {
      const card = cards.get(anchor.messageID)?.root;
      if (card) scroll.scrollTop += card.getBoundingClientRect().top-scroll.getBoundingClientRect().top+anchor.offset;
    }
    applying = false;
  }
  function anchorDisclosure(summary) {
    summary.addEventListener('click', event => {
      if (event.defaultPrevented) return;
      event.preventDefault();
      const top = summary.getBoundingClientRect().top;
      const details = summary.parentElement;
      details.open = !details.open;
      scroll.scrollTop += summary.getBoundingClientRect().top - top;
      restoredLayout = layoutSize();
      capture(false);
    });
  }
  let scrolling = false;
  scroll.addEventListener('scroll',() => {
    if (applying) return;
    window.updateCitationHover?.(null,null);
    window.perchMarkdown({citation:{action:'clear'}});
    window.quoteViewport = {top:0,bottom:scroll.getBoundingClientRect().bottom};
    window.updateQuoteSelection?.();
    if (!scrolling) { scrolling = true; requestAnimationFrame(() => { scrolling = false; capture(); }); }
  });
  scroll.addEventListener('wheel',() => { followsBottom = false; requestAnimationFrame(() => capture()); },{passive:true});
  scroll.addEventListener('keydown',event => {
    if (['PageUp','PageDown','Home','End','ArrowUp','ArrowDown',' '].includes(event.key)) followsBottom = false;
  });
  document.addEventListener('mousedown',() => {window.updateCitationHover?.(null,null);window.perchMarkdown({citation:{action:'clear'}});});
  document.addEventListener('mousemove',event => {
    if (event.buttons) window.perchMarkdown({citation:{action:'clear'}});
  });
  new ResizeObserver(() => { restore(); window.quoteViewport = {top:0,bottom:scroll.getBoundingClientRect().bottom}; }).observe(messages);
  new ResizeObserver(restore).observe(scroll);

  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const reveals = new Map(), glyphClass = 'chat-reveal-glyph';
  const measure = document.createElement('canvas').getContext('2d'), widths = new Map();
  let revealFrame = 0, revealTime = 0, revealFont = '';
  const canReveal = () => state?.revealDuration > 0 && followsBottom && !document.hidden && !reducedMotion.matches;
  const selected = root => {
    const selection = getSelection();
    return selection?.rangeCount && !selection.isCollapsed && selection.getRangeAt(0).intersectsNode(root);
  };
  function showGlyph(glyph, keepNode) {
    glyph.style.opacity = '';
    if (!keepNode && glyph.isConnected) glyph.replaceWith(glyph.firstChild);
  }
  function finishReveal(root) {
    const stream = reveals.get(root);
    if (!stream) return;
    const keep = selected(root);
    for (const item of stream.items) showGlyph(item.glyph,keep);
    reveals.delete(root);
  }
  function finishReveals() {
    for (const root of reveals.keys()) finishReveal(root);
    cancelAnimationFrame(revealFrame); revealFrame = revealTime = 0;
  }
  function animateReveal(time) {
    revealFrame = 0;
    const dt = revealTime ? Math.min(32,time-revealTime) : 0;
    revealTime = time;
    if (!canReveal()) {finishReveals();return;}
    for (const [root,stream] of reveals) {
      if (!root.isConnected || (stream.thinking && !root.parentElement.open) || selected(root)) {
        finishReveal(root);continue;
      }
      const pending = stream.items.reduce((n,item) => n + (item.born === null),0);
      let release = 0;
      if (pending) {
        const target = Math.min(650,Math.max(55,pending/0.13));
        stream.speed += (target-stream.speed)*(1-Math.exp(-dt/60));
        stream.credit += stream.speed*dt/1000;
        release = Math.min(pending,Math.floor(stream.credit));
        stream.credit -= release;
      } else {
        stream.speed *= Math.exp(-dt/60);
        stream.credit = 0;
      }
      for (const item of stream.items) {
        if (item.born !== null) continue;
        if (!release) break;
        release--; item.born = time; stream.head = item.middle;
      }
      const edge = state.revealWidth, duration = state.revealDuration;
      stream.items = stream.items.filter(item => {
        if (item.born === null) return true;
        item.progress = edge ? Math.min(1,Math.max(item.progress,(stream.head-item.middle)/edge,(time-item.born)/duration)) : 1;
        if (item.progress === 1) {showGlyph(item.glyph,false);return false;}
        item.glyph.style.opacity = String(0.03 + 0.97*(1-Math.log1p(5*(1-item.progress))/Math.log(6)));
        return true;
      });
      if (!stream.items.length) reveals.delete(root);
    }
    if (reveals.size) revealFrame = requestAnimationFrame(animateReveal);
    else revealTime = 0;
  }
  function bindReveal(root, previous, thinking = false) {
    let stream = reveals.get(root);
    const full = root.textContent, value = full.trimEnd();
    let common = previous.length;
    if (!value.startsWith(previous)) {
      common = 0;
      while (common < previous.length && previous[common] === value[common]) common++;
    }
    // Rebind the unfinished tail after a Markdown commit. Its time and distance
    // belong to the stream, so the next packet cannot reset an earlier fade.
    const old = new Map(stream?.items.filter(item => item.end <= common).map(item => [item.start,item]));
    const from = Math.max(0,value.length-192,Math.min(common,...old.keys()));
    if (from >= value.length) {finishReveal(root);return;}
    stream ??= {thinking,items:[],speed:0,credit:0,distance:0,head:0};
    const font = getComputedStyle(root);
    const key = `${font.fontWeight} ${font.fontSize} ${font.fontFamily}`;
    if (measure && key !== revealFont) {measure.font = revealFont = key;widths.clear();}
    const walker = document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
    let last = root;
    while (last.lastChild) last = last.lastChild;
    walker.currentNode = last;
    let offset = full.length;
    const groups = [];
    for (let tail = last.nodeType === Node.TEXT_NODE ? last : walker.previousNode(); tail && offset > from; tail = walker.previousNode()) {
      const end = offset;
      offset -= tail.length;
      if (!thinking && tail.parentElement.closest('pre,code,table,blockquote,svg,button,.mermaid-diagram,.quoted-text,a')) continue;
      const start = Math.max(0,from-offset), limit = Math.min(end,value.length)-offset;
      if (start < limit) groups.push({tail,offset,start,limit});
    }
    stream.items = [];
    for (const {tail,offset,start,limit} of groups.reverse()) {
      const fragment = document.createDocumentFragment();
      let cursor = 0;
      // Start at a complete grapheme even when the bounded tail begins inside one.
      const boundary = graphemes.segment(tail.data).containing(start).index;
      for (const {segment,index} of graphemes.segment(tail.data.slice(boundary,limit))) {
        if (!segment.trim()) continue;
        const at = boundary + index, position = offset+at;
        let item = old.get(position);
        if (!item) {
          if (position < common || (common < previous.length && previous.length-common > 2)) continue;
          if (!widths.has(segment)) {
            if (widths.size >= 512) widths.clear();
            widths.set(segment,measure?.measureText(segment).width ?? parseFloat(font.fontSize));
          }
          const width = widths.get(segment);
          item = {start:position,end:position+segment.length,middle:stream.distance+width/2,born:null,progress:0};
          stream.distance += width;
        }
        if (at > cursor) fragment.append(tail.data.slice(cursor,at));
        const glyph = node('span',glyphClass,segment);
        glyph.style.opacity = item.glyph?.style.opacity || '0';
        fragment.append(glyph);
        stream.items.push(Object.assign(item,{glyph}));
        cursor = at+segment.length;
      }
      if (cursor) {
        fragment.append(tail.data.slice(cursor));
        tail.replaceWith(fragment);
      }
    }
    if (!stream.items.length) {reveals.delete(root);return;}
    reveals.set(root,stream);
    if (!revealFrame) revealFrame = requestAnimationFrame(animateReveal);
  }
  document.addEventListener('visibilitychange',() => {if (document.hidden) finishReveals();});

  async function markdown(card, value, active = false) {
    if (!window.marked || !window.DOMPurify) {text(card.body,'Markdown 组件缺失，请重新安装应用。');return;}
    if (card.markdownText === value.text && card.sourcesKey === signature(value.searchSources || [])) return;
    const selection = window.answerSelection?.();
    if (selection && card.body.contains(selection.anchorNode)) { card.pending = value; return; }
    const animate = active && card.body.isConnected && canReveal();
    const previous = animate ? card.body.textContent.trimEnd() : '';
    if (!animate) finishReveal(card.body);
    card.pending = null; card.markdownText = value.text; card.sourcesKey = signature(value.searchSources || []);
    const revision = ++card.revision, root = card.body;
    const diagramStates = new Map(Array.from(root.querySelectorAll('.mermaid-diagram'), d => [d.dataset.source,d]));
    root.innerHTML = DOMPurify.sanitize(marked.parse(value.text,{gfm:true,breaks:true}),{
      USE_PROFILES:{html:true}, FORBID_TAGS:['style','form','iframe','img','button','input','select','textarea'], FORBID_ATTR:['style','id','name']
    });
    root.querySelectorAll('pre').forEach(pre => {
      const code = pre.querySelector('code'), tools = node('div','code-tools');
      const copy = button('复制代码',() => { window.perchMarkdown({copy:code?.textContent || ''}); copy.textContent = '已复制'; });
      tools.append(copy); pre.prepend(tools);
      if (code && !code.classList.contains('language-mermaid')) tools.append(button('另存为',() =>
        window.perchMarkdown({saveCode:code.textContent,language:Array.from(code.classList).find(c => c.startsWith('language-'))?.slice(9) || ''})));
    });
    root.querySelectorAll('table').forEach(enhanceTable);
    root.querySelectorAll('a').forEach(a => {
      try {
        const url = new URL(a.href);
        if (!['http:','https:'].includes(url.protocol) || url.username || url.password) { a.removeAttribute('href'); return; }
        a.onclick = event => {event.preventDefault();send('open',{url:url.href});};
      } catch (_) { a.removeAttribute('href'); }
    });
    enhanceCitations(root,value.searchSources || [],payload => send('markdown',{payload,id:value.id}));
    updateQuotedText();
    if (animate) bindReveal(root,previous);
    for (const code of root.querySelectorAll('pre code.language-mermaid')) {
      if (!window.mermaid) { card.markdownText = null; continue; }
      const source = code.textContent, prior = diagramStates.get(source);
      if (prior) { code.parentElement.replaceWith(prior); continue; }
      try {
        const result = await mermaid.render('chatDiagram'+(++renderID),source);
        if (revision !== card.revision || !code.isConnected) return;
        const diagram = makeDiagram(result.svg,source); diagram.dataset.source = source; code.parentElement.replaceWith(diagram);
      } catch (_) { /* A partial streamed diagram remains copyable source. */ }
      finally { document.getElementById('dchatDiagram'+renderID)?.remove(); }
    }
    updateQuotedText();restore();
  }
  document.addEventListener('selectionchange',() => {
    if (!window.answerSelection?.()) for (const card of cards.values()) if (card.pending) markdown(card,card.pending);
    for (const card of cards.values()) if (card.pendingReasoning) reasoning(card,...card.pendingReasoning);
  });
  function reasoning(card,value,active) {
    const selection=getSelection(), root=card.reasoningText;
    if (selection && !selection.isCollapsed && root.contains(selection.anchorNode)) {
      card.pendingReasoning=[value,active];return;
    }
    card.pendingReasoning=null;
    const atBottom=root.scrollHeight-root.clientHeight-root.scrollTop<4;
    value ||= '';
    const previous = root.textContent;
    if (previous !== value) {
      const animate = active && atBottom && card.reasoning.open && root.isConnected && canReveal();
      if (!animate) finishReveal(root);
      root.textContent = value;
      if (animate) bindReveal(root,previous.trimEnd(),true);
    }
    if (active && atBottom) root.scrollTop=root.scrollHeight;
  }
  function makeMessage(value) {
    const root = node('article','message'); root.dataset.id = value.id;
    const header = node('header'), author = node('span','truncate'), actions = node('div','message-actions');
    const refs = node('div','chips'), quote = node('blockquote'), evidence = node('details'), sources = node('div','sources');
    const searchTitle = node('summary'); evidence.append(searchTitle,sources);
    const reasoning = node('details'), reasoningTitle = node('summary'), reasoningText = node('div','reasoning-text');
    reasoning.append(reasoningTitle,reasoningText);
    anchorDisclosure(searchTitle);
    anchorDisclosure(reasoningTitle);
    const body = node('div',value.role === 'assistant' ? 'markdown' : 'plain-text'), files = node('div'), interactions = node('div'), time = node('time');
    header.append(author,time,actions); root.append(header,refs,quote,evidence,reasoning,body,files,interactions);
    const card = {root,author,actions,refs,quote,evidence,searchTitle,sources,reasoning,reasoningTitle,reasoningText,body,files,interactions,time,revision:0};
    cards.set(value.id,card); return card;
  }
  function updateMessage(value,index) {
    const card = cards.get(value.id) || makeMessage(value), active = state.busy && index === state.messages.length-1;
    card.root.setAttribute('aria-busy',String(active));
    const editIndex = state.messages.findIndex(m => m.id === state.edit), last = index === state.messages.length-1;
    card.root.classList.add(value.role);
    card.root.classList.toggle('editing',state.edit === value.id);
    card.root.classList.toggle('dimmed',editIndex >= 0 && index > editIndex);
    text(card.author,value.role === 'user' ? '你' : value.providerName || state.provider);
    preserve('signature',card.actions,signature([value.role,state.archived,!!value.text]),() => {
      card.actions.replaceChildren();
      if (value.role === 'user' && !state.archived) card.actions.append(
        iconButton('fork','从这轮 Fork 新对话',() => send('fork',{id:value.id})),
        iconButton('edit','重新编辑这条消息',() => send('edit',{id:value.id})));
      if (value.text) card.actions.append(iconButton('copy','复制内容',() => send('copy',{id:value.id})));
    });
    preserve('signature',card.refs,signature([value.references,value.source,value.sourceURL,value.attachments]),() => {
      card.refs.replaceChildren();
      const refs = value.references?.length ? value.references : value.source ? [{title:value.source,url:value.sourceURL}] : [];
      for (const ref of refs) {
        const a = link('',ref.url);a.className='chip source-chip';a.title=ref.title;
        a.append(icon(value.references?.length ? 'globe' : 'quoteBubble'),node('span','truncate',ref.title));card.refs.append(a);
      }
      for (const file of value.attachments || []) {
        const label=node('span','message-attachment');
        label.append(icon(file.image ? 'photo' : 'document'),node('span','truncate',file.name));card.refs.append(label);
      }
    });
    card.quote.hidden = !value.quote; text(card.quote,value.quote?.text || '');
    card.evidence.hidden = !value.searchVisible;
    text(card.searchTitle,(value.searchStatus || '联网搜索')+((value.searchSources || []).length ? ` · ${value.searchSources.length} 个来源` : ''));
    preserve('signature',card.sources,signature(value.searchSources),() => {
      card.sources.replaceChildren(...(value.searchSources || []).map(source => link(source.title,source.url)));
      if (!value.searchSources?.length) card.sources.append(node('span','muted','暂无搜索来源'));
      enhanceCitations(card.sources,value.searchSources || [],payload => send('markdown',{payload,id:value.id}));
    });
    card.reasoning.hidden = value.role !== 'assistant' || (!value.reasoning && !active);
    if (!!value.text !== !!card.hasBody ||
        (!value.text && value.phase === '正在思考…' && (card.phase !== value.phase || !card.hasReasoning))) {
      card.reasoning.open = !value.text && value.phase === '正在思考…' && !!value.reasoning;
    }
    card.hasBody = !!value.text; card.phase = value.phase; card.hasReasoning = !!value.reasoning;
    preserve('signature',card.reasoningTitle,signature([value.phase,active]),() => {
      card.reasoningTitle.replaceChildren(document.createTextNode(value.phase || '思考过程'));
      if (active) card.reasoningTitle.append(node('span','spinner'));
    });
    reasoning(card,value.reasoning,active);
    if (value.role === 'assistant' && value.text) markdown(card,value,active || card.active);
    else text(card.body,value.text || (value.role === 'assistant' && !active && !value.reasoning && !value.generatedFiles?.length && !value.clarification ? '已停止' : ''));
    card.active = active;
    preserve('signature',card.files,signature([value.generatedFiles,value.versions]),() => {
      for (const file of Array.from(fileCards)) if (card.files.contains(file.root)) fileCards.delete(file);
      card.files.replaceChildren(...(value.generatedFiles || []).map(file => makeFile(file,value.versions[file.id] || [file],value.id)));
    });
    preserve('signature',card.interactions,signature([value.clarification,value.followups,!state.archived && !state.busy && !state.edit && last]),() => {
      const drafts = Array.from(card.interactions.querySelectorAll('input[type=text]'), input => input.value);
      card.interactions.replaceChildren();
      const enabled = !state.archived && !state.busy && !state.edit && last;
      if (value.clarification) card.interactions.append(clarification(value.id,value.clarification,enabled,drafts));
      if (enabled) for (const suggestion of value.followups || []) {
        const row = node('div','followup');
        const primary = button('',() => send('followup',{id:value.id,text:suggestion}),'followup-send');
        const arrow = node('span','icon-button'); arrow.append(icon('right'));
        primary.append(node('span','',suggestion),arrow);primary.title='直接发送';
        primary.setAttribute('aria-label','直接发送：'+suggestion);
        const add=iconButton('bubble','添加到对话：'+suggestion,() => send('fillFollowup',{id:value.id,text:suggestion}));
        add.title='添加到对话';row.append(primary,add);
        card.interactions.append(row);
      }
    });
    text(card.time,value.timestamp || '');
    card.time.title = value.timestamp || '';
    return card.root;
  }
  function clarification(id,value,enabled,drafts) {
    const root = node('section','clarification'), fields = [];
    for (const [index,question] of value.questions.entries()) {
      const field = node('fieldset'); field.disabled = !enabled && !value.answers;
      field.append(node('legend','detail',question.label)); root.append(field);
      if (value.answers) { field.append(node('div','',value.answers[index])); continue; }
      const input = node('input'); input.type = 'text'; input.placeholder = '选择上方选项，或输入你的回答';
      input.setAttribute('aria-label',question.label); input.value = drafts[index] || ''; fields.push(input);
      for (const option of question.options) {
        const label = node('label','detail'), radio = node('input'); radio.type = 'radio'; radio.name = id+'-'+index;
        radio.checked = input.value === option; radio.onchange = () => {input.value = option;validate();};
        label.append(radio,document.createTextNode(option)); field.append(label);
      }
      input.oninput = () => {field.querySelectorAll('input[type=radio]').forEach(r => r.checked = r.nextSibling.textContent === input.value);validate();};
      field.append(input);
    }
    const submit = button('提交并继续',() => send('clarify',{id,answers:fields.map(f => f.value)}));
    function validate() { submit.disabled = !enabled || fields.some(f => !f.value.trim() || characterCount(f.value.trim()) > 1000); }
    validate(); root.append(value.answers ? node('span','small muted','已提交') : submit); return root;
  }
  function makeFile(current,versions,message) {
    const root = node('section','file'), header = node('div','row'), label = node('div','grow');
    const title = node('strong','detail',current.name), size = node('div','small muted'), controls = node('div','file-controls'), content = node('div'), result = node('div','file-result');
    let selected = current, mode = /\.(html?|svg)$/i.test(current.name) ? 'preview' : 'closed';
    const record = {root,id:current.id,result,content}; fileCards.add(record);
    const action = operation => send('file',{id:selected.id,card:current.id,message,operation});
    label.append(title,size); header.append(label,button('下载',() => action('download')),button('另存为…',() => action('save')),button('复制源码',() => action('copy')));
    root.append(header,controls,content,result);
    if (versions.length > 1) {
      const select = node('select'); select.setAttribute('aria-label','文件版本');
      versions.forEach((v,i) => {const option = node('option','',`v${i+1}${v.id === current.id ? ' · 此轮' : ''}`);option.value=v.id;select.append(option);});
      select.value = current.id; select.onchange = () => {selected = versions.find(v => v.id === select.value);result.replaceChildren();render();}; controls.append(select);
    }
    const preview = button('预览',() => {mode='preview';render();}), source = button('查看源码',() => {mode=mode === 'source' ? 'closed' : 'source';render();});
    if (/\.(html?|svg)$/i.test(current.name)) controls.append(preview);
    controls.append(source);
    const diff = button('显示变更',() => {mode=mode === 'diff' ? 'source' : 'diff';render();});
    if (versions.length > 1) controls.append(diff);
    function render() {
      record.id = selected.id; content.replaceChildren(); diff.disabled = selected.id === versions[0].id;
      text(size,new TextEncoder().encode(selected.content).length.toLocaleString()+' 字节');
      if (mode === 'preview') {
        const frame = node('iframe'); frame.title = selected.name+' 文件预览'; frame.setAttribute('sandbox','allow-scripts'); frame.referrerPolicy='no-referrer';
        frame.srcdoc = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; form-action 'none'; base-uri 'none';">`+selected.content;
        content.append(frame,node('div','small muted','本地沙箱 · 不加载外部资源'));
      } else if (mode === 'source') content.append(node('pre','',selected.content));
      else if (mode === 'diff') { if (selected.id === versions[0].id) {mode='source';render();} else action('diff'); }
    }
    record.showDiff = value => {
      if (mode !== 'diff') return;
      const pre=node('pre','file-diff');
      value.split('\n').forEach((line,index) => pre.append(node('span',index > 0 && line.startsWith('+ ') ? 'added' : line.startsWith('− ') ? 'removed' : '',line+'\n')));
      content.replaceChildren(pre);
    };
    record.complete = value => {
      result.replaceChildren(value.saved ? button('已保存 · 在 Finder 中显示',() => action('reveal')) : node('span','error',value.error || ''));
    };
    render(); return root;
  }
  window.perchFileResult = value => {for (const file of fileCards) if (file.id === value.id) file.complete(value);};
  window.perchFileDifference = (id,value) => {for (const file of fileCards) if (file.id === id) file.showDiff(value);};
  function publish(action = 'draft') {
    if (composing || !state) return;
    revision++; send(action,{text:composer.value,revision}); updateSend();
  }
  function updateSend() {
    if (!state) return;
    const hasContent = !!composer.value.trim() || !!state.files.length;
    $('send').hidden = state.archived || (state.busy && !hasContent);
    $('send').disabled = !hasContent || characterCount(composer.value) > 8000 || state.loadingFiles || !state.ready || composing;
    const label = state.busy && !state.edit ? '加入发送队列' : '发送';
    $('send').setAttribute('aria-label',label); $('send').title = label === '发送' ? state.sendWithCommand ? '⌘↩ 发送' : '↩ 发送 · ⇧↩ 换行' : label;
    text($('length-error'),characterCount(composer.value) > 8000 ? '问题最多 8,000 字。' : '');
  }
  function candidates() {
    return state.pages.filter(page => !state.references.includes(page.id) &&
      (!mention?.query || (page.title+' '+page.address).toLocaleLowerCase().includes(mention.query.toLocaleLowerCase())));
  }
  function updateMention() {
    if (composing || !state) return;
    const end = composer.selectionStart, prefix = composer.value.slice(0,end), start = prefix.lastIndexOf('@');
    const query = start < 0 ? '' : prefix.slice(start+1);
    if (start < 0 || /[\r\n]/.test(query) || document.activeElement !== composer) mention = null;
    else { if (mention?.query !== query) mentionIndex = 0; mention = {start,end,query}; }
    renderMention();
  }
  function chooseReference(page) {
    if (!mention) return;
    composer.setRangeText('',mention.start,mention.end,'end');
    mention = null; publish(); send('reference',{id:page.id}); renderMention(); composer.focus();
  }
  function renderMention() {
    $('mentions').hidden = !mention;
    if (!mention) return;
    const choices = candidates(); mentionIndex = Math.max(0,Math.min(mentionIndex,choices.length-1));
    $('mention-list').replaceChildren(...choices.map((page,index) => {
      const b = button('',() => chooseReference(page)); b.onmousedown = event => event.preventDefault();
      b.setAttribute('role','option'); b.setAttribute('aria-selected',String(index === mentionIndex));
      b.append(node('span','truncate',page.title),node('small','truncate',page.address)); return b;
    }));
    if (!choices.length) $('mention-list').append(node('span','small muted','没有可引用的标签页'));
    $('mention-list').querySelector('[aria-selected=true]')?.scrollIntoView({block:'nearest'});
  }
  composer.addEventListener('compositionstart',() => {composing=true;$('mentions').hidden=true;updateSend();});
  composer.addEventListener('compositionend',() => {composing=false;publish();updateMention();});
  composer.addEventListener('input',event => {if (!event.isComposing && !composing) {publish();updateMention();}});
  composer.addEventListener('click',updateMention);
  composer.addEventListener('keyup',event => {if (!['Escape','Enter'].includes(event.key)) updateMention();});
  composer.addEventListener('keydown',event => {
    if (composing || event.isComposing || event.keyCode === 229) return;
    const plain = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
    if (mention && plain && ['ArrowUp','ArrowDown','Enter','Escape'].includes(event.key)) {
      event.preventDefault();
      if (event.key === 'Escape') mention=null;
      else if (event.key === 'Enter') {const page=candidates()[mentionIndex];if (page) chooseReference(page);}
      else mentionIndex += event.key === 'ArrowDown' ? 1 : -1;
      renderMention(); return;
    }
    if (event.key === 'Escape' && state.edit) {event.preventDefault();send('cancelEdit');return;}
    if (event.key !== 'Enter') return;
    const submit = state.sendWithCommand ? event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey : plain;
    if (submit) {event.preventDefault();publish('send');mention=null;renderMention();}
    else if (event.metaKey || event.ctrlKey || event.altKey) {event.preventDefault();document.execCommand('insertText',false,'\n');}
  });
  composer.addEventListener('paste',event => {
    if (state.archived || composing) return;
    if (Array.from(event.clipboardData?.items || []).some(item => item.kind === 'file' && item.type.startsWith('image/'))) {
      event.preventDefault();send('pasteImage');
    }
  });
  $('send').onclick = () => {if (!$('send').disabled) {publish('send');composer.focus();}};
  for (const [id,action] of [['attach','attach'],['stop','stop'],['settings','settings'],['restore','restore'],['cancel-edit','cancelEdit'],['resume-queue','resumeQueue'],['search-enabled','searchEnabled']]) $(id).onclick = () => send(action);
  $('search-source').onchange = () => send('searchSource',{source:$('search-source').value});
  $('model-button').onclick = () => {$('models').hidden=!$('models').hidden;if (!$('models').hidden) {$('model-search').focus();renderModels();}};
  $('model-search').oninput = renderModels;
  function renderModels() {
    if (!state) return;
    const query = $('model-search').value.trim().toLocaleLowerCase();
    preserve('signature',$('model-list'),signature([query,state.providers,state.providerID,state.model]),() => {
    $('model-list').replaceChildren();
    for (const provider of state.providers) {
      const models = provider.models.filter(m => (provider.name+' '+m).toLocaleLowerCase().includes(query));
      if (!models.length) continue;
      $('model-list').append(node('div','small muted',provider.name));
      for (const model of models) {
        const b = button(model,() => {send('model',{id:provider.id,model});$('models').hidden=true;composer.focus();});
        b.setAttribute('aria-selected',String(provider.id === state.providerID && model === state.model)); $('model-list').append(b);
      }
    }
    if (!$('model-list').children.length) $('model-list').append(node('div','detail muted',query ? '没有匹配的模型' : '请先在 AI 设置中添加模型。'));
    });
  }
  document.addEventListener('mousedown',event => {
    if (!$('models').contains(event.target) && !$('model-button').contains(event.target)) $('models').hidden=true;
    if (!$('references').contains(event.target) && !event.target.closest('#more-references')) hideReferences();
  });
  document.addEventListener('keydown',event => {
    if (event.key === 'Escape' && (!$('models').hidden || !$('references').hidden)) {
      $('models').hidden=true;hideReferences();composer.focus();
    }
  });
  function hideReferences() {
    $('references').hidden=true;$('more-references')?.setAttribute('aria-expanded','false');
  }
  function referenceChip(ref, closed = false) {
    const row=node('div','chip'+(closed ? ' closed-reference' : ''));
    row.append(icon('globe'),node('span',closed ? 'grow truncate' : 'truncate',ref.title));
    if (closed) row.append(node('span','muted','发送时恢复引用'));
    const remove=iconButton('close','移除引用',() => send('removeReference',{id:ref.id}));
    remove.classList.add('reference-close');row.append(remove);return row;
  }
  function draftItems() {
    preserve('signature',$('draft-items'),signature([state.quote,state.files,state.references,state.closedReferences,state.pages]),() => {
      const root=$('draft-items');root.replaceChildren();
      if (state.quote) {
        const row=node('div','row');row.id='draft-quote';row.title=state.quote.text;
        const excerpt=state.quote.messageID ? button('',()=>{
          if (window.highlightQuotedText?.(true)) {followsBottom=false;capture();}
        },'grow quote-source') : node('span','grow quote-text',state.quote.text);
        if (state.quote.messageID) {
          excerpt.append(node('span','quote-text',state.quote.text));
          excerpt.title='定位并高亮引用原文\n'+state.quote.text;
        }
        row.append(icon('quote'),excerpt,iconButton('close','移除引用',() => send('removeQuote')));root.append(row);
      }
      for (const ref of state.closedReferences) root.append(referenceChip(ref,true));
      const pages=state.pages.filter(p => state.references.includes(p.id)), popup=$('references');
      popup.replaceChildren();
      if (pages.length) {
        const refs=node('div','chips');root.append(refs);
        for (const ref of pages.slice(0,2)) refs.append(referenceChip(ref));
        if (pages.length > 2) {
          const more=button('+'+(pages.length-2),() => {
            popup.hidden=!popup.hidden;more.setAttribute('aria-expanded',String(!popup.hidden));
          },'chip');
          more.id='more-references';more.style.flex='none';
          more.setAttribute('aria-label','查看全部引用');more.setAttribute('aria-expanded',String(!popup.hidden));
          refs.append(more);
          for (const ref of pages) popup.append(referenceChip(ref));
        } else popup.hidden=true;
      } else popup.hidden=true;
      for (const file of state.files) {
        const row=node('div','chip attachment');
        if (file.image) {const image=node('img');image.src=file.image;image.alt=file.name;row.append(image);}
        row.append(icon(file.image ? 'photo' : 'document'),node('span','grow truncate',file.name),
          iconButton('removeFile','移除附件',() => send('removeFile',{id:file.id})));root.append(row);
      }
    });
  }
  function saveSelection() {
    if (state && !composing) {
      const value={start:composer.selectionStart,end:composer.selectionEnd,scroll:composer.scrollTop,focused:document.activeElement === composer};
      selections.set(state.owner,value);send('inputState',value);
    }
  }
  for (const event of ['select','keyup','mouseup','scroll','focus']) composer.addEventListener(event,saveSelection);
  const updateQuotedText = () => window.updateQuotedText?.(
    Array.from(cards,([id,card])=>({id,root:card.body})),state?.quote);
  window.perchSuspend = () => {finishReveals();saveSelection();capture();window.closeQuotePopover?.();window.clearQuotedTextHighlight?.();window.updateChatHover(null,null);window.updateCitationHover?.(null,null);window.perchMarkdown({citation:{action:'clear'}});};
  window.perchUpdate = next => {
    const changed = !state || state.owner !== next.owner || state.conversation !== next.conversation;
    if (changed) {
      finishReveals();
      window.closeQuotePopover?.();
      hideReferences();
      saveSelection(); capture(); cards.clear(); fileCards.clear();messages.replaceChildren();
      anchor=next.reading;followsBottom=!anchor;lastUser='';edit='';revision=next.draftRevision;mention=null;focus='';
      $('models').hidden=true;composing=false;
    }
    state=next;window.quoteEnabled=!state.archived;
    if (!canReveal()) finishReveals();
    if (changed) {
      window.updateCitationHover?.(null,null);
      window.perchMarkdown({citation:{action:'clear'}});
    }
    document.documentElement.dataset.owner=state.owner;
    document.documentElement.dataset.conversation=state.conversation;
    document.body.classList.toggle('sidebar',!state.fullPage);
    $('setup').hidden=state.ready;messages.hidden=!state.ready;
    if (window.mermaid && !window.perchMermaidReady) {
      window.perchMermaidReady=true;window.perchDiagramColors=state.colors;
      mermaid.initialize({startOnLoad:false,securityLevel:'strict',maxTextSize:32000,theme:'base',themeVariables:{
        primaryColor:state.colors.mint,secondaryColor:state.colors.sidebar,tertiaryColor:state.colors.mint,
        primaryTextColor:'#28352e',primaryBorderColor:state.colors.line,lineColor:state.colors.accent,
        actorBkg:state.colors.mint,actorBorder:state.colors.line,fontFamily:'-apple-system,sans-serif',fontSize:'13px'
      },flowchart:{htmlLabels:false}});
    }
    const user=state.messages.filter(m => m.role === 'user').at(-1)?.id || '';
    if (!changed && user !== lastUser && !state.edit) {followsBottom=true;anchor=null;}
    lastUser=user;
    const retained=new Set(state.messages.map(m => m.id));
    for (const [id,card] of cards) if (!retained.has(id)) {card.root.remove();cards.delete(id);}
    state.messages.forEach((value,index) => {
      const element=updateMessage(value,index), current=messages.children[index];
      if (current !== element) messages.insertBefore(element,current || null);
    });
    let status=$('chat-status');
    if (!status) {status=node('div');status.id='chat-status';messages.append(status);}
    text(status,state.error || (state.messages.length ? '' : '总结网页、引用选中文字，或添加文件一起提问。'));
    status.className=state.error ? 'error detail' : 'muted detail';
    if (state.edit && state.edit !== edit) {followsBottom=false;anchor={messageID:state.edit,offset:0};}
    edit=state.edit;
    if (!composing && (changed || state.draftRevision >= revision) && (changed || composer.value !== state.draft)) {
      const selection=changed ? selections.get(state.owner) || state.selection : {start:composer.selectionStart,end:composer.selectionEnd,scroll:composer.scrollTop};
      composer.value=state.draft;
      const start=Math.min(selection?.start ?? composer.value.length,composer.value.length);
      composer.setSelectionRange(start,Math.min(selection?.end ?? start,composer.value.length));composer.scrollTop=selection?.scroll || 0;
    }
    composer.readOnly=state.archived;
    $('archive').hidden=!state.archived;$('editing').hidden=!state.edit;
    text($('edit-label'),state.fork ? 'Fork · 发送后创建新对话' : '重新编辑 · 发送后替换后续对话');
    $('stop').hidden=!state.busy;$('attach').disabled=state.archived || state.loadingFiles;
    $('search-enabled').setAttribute('aria-pressed',String(state.searchEnabled));$('search-enabled').title=state.searchEnabled ? '联网已开启 · 点击关闭' : '联网已关闭 · 点击开启';
    preserve('signature',$('search-source'),signature(state.searchSources),() => {
      $('search-source').replaceChildren(...state.searchSources.map(source => {const o=node('option','',source.title);o.value=source.id;o.disabled=!source.enabled;return o;}));
    });
    $('search-source').value=state.searchSource;text($('model-button'),(state.model || '选择模型')+' ⌃');$('model-button').title=state.provider+' · 选择模型';
    draftItems();
    $('queue').hidden=!state.queue.length;$('resume-queue').hidden=state.busy || !!state.edit;
    text($('queue-label'),(state.paused ? '发送队列已暂停' : '等待发送')+` · ${state.queue.length} 条`);
    preserve('signature',$('queue-list'),signature(state.queue),() => {
      $('queue-list').replaceChildren(...state.queue.map((item,index) => {
        const row=node('div','queue-item');row.append(node('span','muted',String(index+1)),node('span','grow truncate',item.question || '附件消息'));
        if (item.files) row.append(node('span','',`附件 ${item.files}`));
        row.append(iconButton('close','移除待发送消息',() => send('removeQueue',{id:item.id})));return row;
      }));
    });
    text($('file-error'),state.fileError);text($('storage-error'),state.storageError);updateSend();renderMention();
    if (!$('models').hidden) renderModels();
    if (state.focus && state.focus !== focus) {
      focus=state.focus;composer.focus();if (!composing) composer.setSelectionRange(composer.value.length,composer.value.length);
    } else if (changed && (selections.get(state.owner) || state.selection)?.focused) composer.focus();
    restore();
    window.quoteViewport={top:0,bottom:scroll.getBoundingClientRect().bottom};
    updateQuotedText();
    window.updateQuoteSelection?.();
  };
  window.webkit.messageHandlers.perchInternal.postMessage({action:'ready'});
})();
