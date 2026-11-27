(() => {
  if (location.href !== 'perch-home://new-tab/') return;
  let owner = null, revision = null, composing = false, editing = false, queryID = 0, selected = -1, suggestions = [];
  let order = [], drag = null, suppressClick = false, rememberedFocus = false, anchored = null;
  const input = document.getElementById('search'), list = document.getElementById('suggestions'), grid = document.getElementById('shortcuts');
  const cards = new Map();
  const artwork = {
    search:'<circle cx="10" cy="10" r="7"/><path d="m15 15 6 6"/>',
    code:'<path d="m7 5-5 7 5 7m10-14 5 7-5 7m-3-16-4 20"/>',
    chat:'<path d="M3 3h18v14H9l-6 4z"/>',
    globe:'<circle cx="12" cy="12" r="10"/><ellipse cx="12" cy="12" rx="4" ry="10"/><path d="M2 12h20"/>'
  };
  const send = (action, values = {}) => window.webkit.messageHandlers.perchInternal.postMessage({action,owner,...values});
  function status() {
    send('state',{pristine: !input.value && !composing && !drag && !rememberedFocus && scrollY === 0});
  }
  function dismiss() {
    editing = false; selected = -1; suggestions = []; list.replaceChildren(); list.hidden = true;
    input.setAttribute('aria-expanded','false'); input.removeAttribute('aria-activedescendant'); ++queryID;
  }
  function query() {
    selected = -1;
    if (!editing || composing || !input.value.trim()) { dismiss(); return; }
    send('query',{text:input.value,request:++queryID});
  }
  function publish() {
    if (composing) return;
    send('draft',{text:input.value}); status(); editing = true; query();
  }
  window.perchSuggestions = state => {
    if (state.request !== queryID || state.text !== input.value || composing || !editing || document.activeElement !== input) return;
    suggestions = state.items; selected = -1; list.replaceChildren();
    suggestions.forEach((item,index) => {
      const button = document.createElement('button'); button.type='button'; button.id='suggestion-'+index;
      button.setAttribute('role','option'); button.setAttribute('aria-selected','false');
      const icon = document.createElement('span'); icon.textContent = item.bookmark ? '☆' : '◷'; icon.setAttribute('aria-hidden','true');
      const info = document.createElement('span'); info.className='suggestion-info';
      const title = document.createElement('span'); title.textContent=item.title || item.address;
      const address = document.createElement('small'); address.textContent=item.address;
      info.append(title,address); button.append(icon,info);
      button.addEventListener('mousedown', event => event.preventDefault());
      button.addEventListener('click', () => submit(item.address)); list.append(button);
    });
    list.hidden = !suggestions.length; input.setAttribute('aria-expanded',String(!!suggestions.length));
  };
  function select(index) {
    selected=index;
    Array.from(list.children).forEach((button,i) => button.setAttribute('aria-selected',String(i===selected)));
    if (selected>=0) input.setAttribute('aria-activedescendant','suggestion-'+selected);
    else input.removeAttribute('aria-activedescendant');
  }
  function submit(text) {
    if (composing) return;
    send('draft',{text:input.value}); dismiss(); input.blur(); rememberedFocus=false;
    send('navigate',{text});
  }
  input.addEventListener('compositionstart',()=>{composing=true;dismiss();status();});
  input.addEventListener('compositionend',()=>{composing=false;publish();});
  input.addEventListener('input',event=>{if (!event.isComposing) publish();});
  input.addEventListener('focus',()=>{rememberedFocus=true;status();});
  input.addEventListener('blur',event=>{if (event.relatedTarget) rememberedFocus=false;dismiss();status();});
  document.addEventListener('pointerdown',event=>{
    if(event.target!==input && !list.contains(event.target)){rememberedFocus=false;status();}
  });
  input.addEventListener('keydown',event=>{
    if (composing || event.isComposing || event.keyCode===229) return;
    if (event.key==='ArrowDown' && suggestions.length) {event.preventDefault();select(Math.min(selected+1,suggestions.length-1));}
    else if (event.key==='ArrowUp' && suggestions.length) {event.preventDefault();select(Math.max(selected-1,-1));}
    else if (event.key==='Escape') {event.preventDefault();dismiss();}
    else if (event.key==='Enter') {event.preventDefault();submit(selected>=0 ? suggestions[selected].address : input.value);}
  });
  window.perchRestoreFocus = () => {
    if (rememberedFocus) {const start=input.selectionStart,end=input.selectionEnd;input.focus({preventScroll:true});input.setSelectionRange(start,end);}
  };
  function arrange(ids) {
    if(ids.length===grid.children.length && ids.every((id,index)=>grid.children[index].dataset.id===id))return;
    const positions=new Map(Array.from(grid.children).map(card=>[card,card.getBoundingClientRect()]));
    for(const card of grid.children)cards.get(card.dataset.id)?.animation?.cancel();
    ids.forEach((id,index)=>{const card=cards.get(id)?.card;if(card && grid.children[index]!==card)grid.insertBefore(card,grid.children[index]||null);});
    if(!matchMedia('(prefers-reduced-motion: reduce)').matches) {
      for(const card of grid.children) {
        const before=positions.get(card);if(!before)continue;
        const after=card.getBoundingClientRect(),x=before.x-after.x,y=before.y-after.y;
        if(x || y){const animation=card.animate([{transform:`translate(${x}px,${y}px)`},{transform:'none'}],{duration:180,easing:'ease-out'});cards.get(card.dataset.id).animation=animation;}
      }
    }
    if(drag)drag.card.setPointerCapture(drag.pointer);
  }
  function finishDrag(ids) {
    if (!drag) return;
    const previous=drag;drag=null;
    arrange(ids); previous.card.classList.remove('drag-source'); previous.ghost?.remove();
    if (previous.card.hasPointerCapture(previous.pointer)) previous.card.releasePointerCapture(previous.pointer);
    status();
  }
  function cancelDrag() {finishDrag(order);}
  window.perchSuspend = () => {cancelDrag();dismiss();};
  function startDrag(event,card) {
    if (event.button!==0 || event.ctrlKey || !owner) return;
    suppressClick=false;
    drag={card,id:card.dataset.id,pointer:event.pointerId,x:event.clientX,y:event.clientY,original:order.slice(),preview:order.slice(),active:false};
    card.setPointerCapture(event.pointerId);
  }
  grid.addEventListener('pointerdown',event=>{const card=event.target.closest('.shortcut');if(card)startDrag(event,card);});
  grid.addEventListener('pointermove',event=>{
    if (!drag || event.pointerId!==drag.pointer) return;
    if (!drag.active && Math.hypot(event.clientX-drag.x,event.clientY-drag.y)<5) return;
    event.preventDefault();
    if (!drag.active) {
      drag.active=true;suppressClick=true;
      const rect=drag.card.getBoundingClientRect();drag.offsetX=drag.x-rect.x;drag.offsetY=drag.y-rect.y;
      drag.ghost=drag.card.cloneNode(true);drag.ghost.className='shortcut drag-ghost';drag.ghost.removeAttribute('id');
      drag.ghost.setAttribute('aria-hidden','true');drag.ghost.tabIndex=-1;
      drag.ghost.style.width=rect.width+'px';document.body.append(drag.ghost);drag.card.classList.add('drag-source');status();
    }
    drag.ghost.style.left=(event.clientX-drag.offsetX)+'px';drag.ghost.style.top=(event.clientY-drag.offsetY)+'px';
    const rect=grid.getBoundingClientRect();
    if (event.clientX<rect.left || event.clientX>rect.right || event.clientY<rect.top || event.clientY>rect.bottom) {drag.preview=drag.original.slice();arrange(drag.preview);return;}
    // Layout offsets stay fixed while animation transforms move the visible cards.
    const slots=Array.from(grid.children).map(card=>({x:rect.left+card.offsetLeft+card.offsetWidth/2,y:rect.top+card.offsetTop+card.offsetHeight/2}));
    let target=0,distance=Infinity;
    slots.forEach((slot,i)=>{const value=Math.hypot(slot.x-event.clientX,slot.y-event.clientY);if(value<distance){distance=value;target=i;}});
    const next=drag.preview.slice();next.splice(next.indexOf(drag.id),1);next.splice(target,0,drag.id);drag.preview=next;arrange(next);
  });
  grid.addEventListener('pointerup',event=>{
    if (!drag || event.pointerId!==drag.pointer) return;
    const rect=grid.getBoundingClientRect(),accepted=drag.active && event.clientX>=rect.left && event.clientX<=rect.right && event.clientY>=rect.top && event.clientY<=rect.bottom;
    const ids=drag.preview.slice();finishDrag(accepted ? ids : order);if(accepted)send('reorder',{ids});
    if(suppressClick)setTimeout(()=>{suppressClick=false;},0);
  });
  grid.addEventListener('pointercancel',cancelDrag);
  grid.addEventListener('lostpointercapture',()=>{if(drag)cancelDrag();});
  window.addEventListener('keydown',event=>{if(event.key==='Escape' && drag){event.preventDefault();cancelDrag();}});
  window.addEventListener('blur',cancelDrag);
  window.addEventListener('pointerup',()=>{if(suppressClick)setTimeout(()=>{suppressClick=false;},0);});
  document.addEventListener('click',event=>{
    const card=event.target.closest('.shortcut');
    if(card){if(!suppressClick)send('open',{id:card.dataset.id,background:event.metaKey});return;}
    const button=event.target.closest('[data-action]');if(button)send(button.dataset.action);
  });
  grid.addEventListener('contextmenu',event=>{
    const card=event.target.closest('.shortcut');if(!card)return;
    event.preventDefault();cancelDrag();const rect=card.getBoundingClientRect();
    anchored=card.dataset.id;
    send('menu',{id:anchored,x:event.clientX,y:event.clientY,rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});
  });
  function positionAnchor() {
    const card=cards.get(anchored)?.card;if(!card)return;
    const rect=card.getBoundingClientRect();
    send('anchor',{id:anchored,x:rect.x,y:rect.y,rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});
  }
  window.addEventListener('scroll',()=>{status();positionAnchor();},{passive:true});
  new ResizeObserver(positionAnchor).observe(grid);
  window.perchUpdate = state => {
    document.querySelector('.chat-icon').style.webkitMaskImage = `url("${state.chatIcon}")`;
    if (owner!==state.owner) {
      cancelDrag();dismiss();owner=state.owner;input.value=state.draft;rememberedFocus=false;anchored=null;window.scrollTo(0,0);
      document.documentElement.dataset.owner=owner;
    }
    const incoming=state.sites.map(site=>site.id);
    if(drag && JSON.stringify(incoming)!==JSON.stringify(drag.original))cancelDrag();
    for(const [id,entry] of cards)if(!incoming.includes(id)){entry.card.remove();cards.delete(id);}
    state.sites.forEach(site=>{
      let entry=cards.get(site.id);
      if(!entry){
        const card=document.createElement('button');card.type='button';card.className='shortcut';card.dataset.id=site.id;
        const icon=document.createElement('img');icon.alt='';icon.draggable=false;
        const fallback=document.createElement('span');fallback.className='site-symbol';fallback.setAttribute('aria-hidden','true');
        icon.addEventListener('error',()=>{icon.hidden=true;fallback.hidden=false;});
        const info=document.createElement('span');info.className='site-info';
        const title=document.createElement('span'),host=document.createElement('small');info.append(title,host);card.append(icon,fallback,info);
        entry={card,icon,fallback,title,host};cards.set(site.id,entry);
      }
      entry.title.textContent=site.title;entry.host.textContent=site.host;entry.card.setAttribute('aria-label',site.title);
      if(entry.fallback.dataset.symbol!==site.symbol){
        const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 24 24');
        svg.innerHTML=artwork[site.symbol] || artwork.globe;entry.fallback.replaceChildren(svg);entry.fallback.dataset.symbol=site.symbol;
      }
      if(entry.icon.getAttribute('src')!==(site.icon||null)){
        if(site.icon)entry.icon.src=site.icon;
        else entry.icon.removeAttribute('src');
      }
      const hasIcon=!!site.icon && (!entry.icon.complete || entry.icon.naturalWidth>0);
      entry.icon.hidden=!hasIcon;entry.fallback.hidden=hasIcon;
    });
    order=incoming;if(!drag)arrange(order);
    document.getElementById('date').textContent=state.date;
    if(revision!==state.revision){revision=state.revision;if(editing && document.activeElement===input)query();}
    status();positionAnchor();
  };
  send('ready');
})();
