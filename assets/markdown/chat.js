// CommonMark treats 。**中文 as a new opener; accept this CJK prose boundary.
marked.use({extensions:[{
  name:'cjkStrong', level:'inline',
  start(src) { return src.indexOf('**'); },
  tokenizer(src) {
    const match=/^\*\*([^\s*`\\\n](?:[^*`\\\n]*?[^\s*`\\\n])?)\*\*(?!\*)/u.exec(src);
    if (!match || !/\p{Script=Han}|\p{Script=Hiragana}|\p{Script=Katakana}|\p{Script=Hangul}/u.test(match[1])) return;
    const next=src.slice(match[0].length);
    if (!/\p{P}$/u.test(match[1]) || !/^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(next)) return;
    return {type:'strong',raw:match[0],text:match[1],tokens:this.lexer.inlineTokens(match[1])};
  }
}]});

const quoteStyle=document.createElement('style');
quoteStyle.textContent=`
#quote-selection{display:inline-flex;align-items:center;gap:6px;opacity:1;visibility:visible;transition:opacity .16s ease-in-out,visibility 0s}
#quote-selection[hidden]{display:inline-flex!important;opacity:0;visibility:hidden;pointer-events:none;transition:opacity .16s ease-in-out,visibility 0s .16s}
#quote-selection:not([hidden]):disabled{opacity:.4}
#quote-selection svg{width:14px;height:14px;fill:currentColor;flex:none}
#quote-selection svg,#quote-selection span{pointer-events:none}
.quoted-text{text-decoration-line:underline;text-decoration-style:dashed;text-decoration-color:var(--perch-accent,#54836b);text-underline-offset:4px;cursor:default}
.quoted-text.quoted-active{background:var(--perch-mint,#dfeae3);border-radius:2px;-webkit-box-decoration-break:clone;box-decoration-break:clone}
@media(prefers-reduced-motion:reduce){#quote-selection,#quote-selection[hidden]{transition:none!important}}
`;
document.head.append(quoteStyle);
const quoteButton=document.createElement('button');
quoteButton.id='quote-selection'; quoteButton.type='button';
quoteButton.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 13V9a5 5 0 0 1 5-5v3a2 2 0 0 0-2 2h4v10H3ZM14 13V9a5 5 0 0 1 5-5v3a2 2 0 0 0-2 2h4v10h-7Z"/></svg><span>引用到对话</span>';
quoteButton.hidden=true; document.body.append(quoteButton);
let selectedQuote='', selectedRange=null, removal=null, markedRoot=null, markedQuote=null, markers=[];
let quoteHighlighted=false;
const trustedMarkers=new WeakSet();
// UTF-16 offsets use only answer text; changing copy/diagram controls cannot move a quote.
function answerText(root) {
  const nodes=[], walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{
    acceptNode:n=>n.parentElement.closest('button,select,textarea,script,style,[aria-hidden="true"],.code-tools,.diagram-toolbar,.diagram-source,.mermaid-diagram')
      ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
  });
  let value='', n;
  while ((n=walker.nextNode())) {nodes.push({node:n,start:value.length,end:value.length+n.length});value+=n.data;}
  return {nodes,value};
}
function textOffset(root, entries, container, offset) {
  const prefix=document.createRange();prefix.selectNodeContents(root);prefix.setEnd(container,offset);
  let result=0;
  for (const {node} of entries) {
    if (prefix.comparePoint(node,node.length)<=0) result+=node.length;
    else if (node===container) result+=offset;
  }
  return result;
}
function selectionOffsets(root, index, selection) {
  if (!selection?.rangeCount || !root.contains(selection.anchorNode) || !root.contains(selection.focusNode)) return null;
  return {anchor:textOffset(root,index.nodes,selection.anchorNode,selection.anchorOffset),
    focus:textOffset(root,index.nodes,selection.focusNode,selection.focusOffset)};
}
function restoreTextSelection(root, offsets) {
  if (!offsets) return;
  const {nodes}=answerText(root);
  const point=offset=>{
    const entry=nodes.find(n=>n.end>=offset);
    return entry ? [entry.node,Math.max(0,offset-entry.start)] : [root,root.childNodes.length];
  };
  getSelection().setBaseAndExtent(...point(offsets.anchor),...point(offsets.focus));
}
window.closeQuotePopover=()=>{removal=null;quoteButton.hidden=true;};
window.clearQuotedTextHighlight=()=>{
  quoteHighlighted=false;markers.forEach(marker=>marker.classList.remove('quoted-active'));
};
window.highlightQuotedText=(reveal=false)=>{
  if (!markers.length || markers.some(marker=>!marker.isConnected)) return false;
  quoteHighlighted=true;markers.forEach(marker=>marker.classList.add('quoted-active'));
  if (reveal) {
    window.closeQuotePopover();
    markers[0].scrollIntoView({block:'center',inline:'nearest',behavior:'auto'});
  }
  return true;
};
window.updateQuotedText=(roots,quote)=>{
  const root=quote?.messageID ? roots.find(item=>item.id.toLowerCase()===quote.messageID.toLowerCase())?.root : null;
  const key=JSON.stringify(quote && {messageID:quote.messageID,text:quote.text,
    sourceRange:quote.sourceRange && {start:quote.sourceRange.start,end:quote.sourceRange.end}});
  if (root===markedRoot && key===markedQuote && markers.every(m=>m.isConnected)) return;
  const keepHighlight=root===markedRoot && key===markedQuote && quoteHighlighted;
  window.closeQuotePopover();
  window.clearQuotedTextHighlight();
  const saved=new Map();
  for (const r of new Set([markedRoot,root].filter(Boolean))) saved.set(r,selectionOffsets(r,answerText(r),getSelection()));
  for (const marker of markers) marker.replaceWith(...marker.childNodes);
  markers=[];markedRoot=root;markedQuote=key;
  if (root && quote.text) {
    const index=answerText(root), range=quote.sourceRange;
    let start=range?.start, end=range?.end;
    if (!range) {
      start=index.value.indexOf(quote.text);end=start+quote.text.length;
      if (start<0 || index.value.indexOf(quote.text,start+1)>=0) start=-1;
    }
    if (Number.isInteger(start) && Number.isInteger(end) && start>=0 && end>start &&
        index.value.slice(start,end)===quote.text) {
      for (const entry of index.nodes) {
        const from=Math.max(start,entry.start)-entry.start, to=Math.min(end,entry.end)-entry.start;
        if (to<=from) continue;
        let text=entry.node;
        if (to<text.length) text.splitText(to);
        if (from>0) text=text.splitText(from);
        const marker=document.createElement('span');marker.className='quoted-text';
        text.replaceWith(marker);marker.append(text);markers.push(marker);trustedMarkers.add(marker);
      }
      if (markers[0]) {markers[0].tabIndex=0;markers[0].setAttribute('role','button');markers[0].setAttribute('aria-label','取消引用');}
    }
  }
  for (const [r,offsets] of saved) restoreTextSelection(r,offsets);
  if (keepHighlight) window.highlightQuotedText();
};
function positionQuote(rect) {
  const viewport=window.quoteViewport || {top:0,bottom:innerHeight};
  quoteButton.style.left=Math.max(4,Math.min(rect.left,innerWidth-quoteButton.offsetWidth-4))+'px';
  quoteButton.style.top=Math.max(viewport.top+4,Math.min(rect.top-quoteButton.offsetHeight-6,viewport.bottom-quoteButton.offsetHeight-4))+'px';
}
function showRemoval(marker) {
  if (!window.quoteEnabled || !trustedMarkers.has(marker) || !markers.includes(marker)) return false;
  window.highlightQuotedText();
  removal=JSON.parse(markedQuote);
  selectedQuote='';selectedRange=null;
  quoteButton.querySelector('span').textContent='取消引用';quoteButton.title='取消本次提问的引用';
  quoteButton.disabled=false;quoteButton.hidden=false;positionQuote(marker.getBoundingClientRect());
  return true;
}
document.addEventListener('click',event=>{
  const marker=event.target.closest?.('.quoted-text');
  if (getSelection()?.isCollapsed && showRemoval(marker)) {event.preventDefault();event.stopPropagation();}
},true);
document.addEventListener('mousedown',event=>{
  if (!quoteButton.contains(event.target) && !markers.some(m=>m.contains(event.target)) &&
      !event.target.closest?.('#draft-quote')) {
    if (removal) window.closeQuotePopover();
    window.clearQuotedTextHighlight();
  }
});
document.addEventListener('keydown',event=>{
  if (['Enter',' '].includes(event.key) && showRemoval(event.target)) event.preventDefault();
});
document.addEventListener('scroll',()=>{if (removal) window.closeQuotePopover();},true);
window.answerSelection=()=>{
  const selection=window.getSelection(), root=window.answerRootForSelection?.(selection) || document.getElementById('content');
  if (!window.quoteEnabled || !selection || selection.isCollapsed || !selection.rangeCount ||
      !root?.contains(selection.anchorNode) || !root.contains(selection.focusNode)) return null;
  const rect=selection.getRangeAt(0).getBoundingClientRect();
  return rect.width>0 && rect.height>0 ? selection : null;
};
window.updateQuoteSelection=()=>{
  const selection=window.answerSelection();
  if (removal && !selection) return;
  removal=null;selectedRange=null;
  selectedQuote=selection ? selection.toString().trim() : '';
  if (selection) {
    const root=window.answerRootForSelection?.(selection) || document.getElementById('content');
    const index=answerText(root), offsets=selectionOffsets(root,index,selection);
    const start=Math.min(offsets.anchor,offsets.focus), end=Math.max(offsets.anchor,offsets.focus);
    const raw=index.value.slice(start,end), trimmed=raw.trim();
    if (trimmed) {
      const leading=raw.length-raw.trimStart().length;
      selectedQuote=trimmed;selectedRange={start:start+leading,end:start+leading+trimmed.length};
    }
  }
  quoteButton.querySelector('span').textContent='引用到对话';
  quoteButton.hidden=!selectedQuote;
  if (!selectedQuote) {
    if (window.pendingMarkdown != null) {
      const text=window.pendingMarkdown;window.pendingMarkdown=null;window.renderMarkdown(text);
    }
    return;
  }
  const rect=selection.getRangeAt(0).getBoundingClientRect();
  quoteButton.disabled=Array.from(selectedQuote).length>12000;
  quoteButton.title=quoteButton.disabled ? '请选择不超过 12,000 字的片段' : '将选中文字作为本次提问的引用';
  positionQuote(rect);
};
quoteButton.addEventListener('mousedown',event=>event.preventDefault());
quoteButton.addEventListener('click',()=>{
  if (removal) {
    window.webkit.messageHandlers.markdown.postMessage({removeQuote:true,messageID:removal.messageID,text:removal.text});
    window.closeQuotePopover();return;
  }
  if (!selectedQuote || quoteButton.disabled) return;
  window.webkit.messageHandlers.markdown.postMessage({quote:selectedQuote,range:selectedRange});
  window.getSelection().removeAllRanges();quoteButton.hidden=true;
});
document.addEventListener('selectionchange',()=>requestAnimationFrame(window.updateQuoteSelection));
window.addEventListener('resize',window.updateQuoteSelection);
document.addEventListener('keydown',event=>{
  if (event.key==='Escape' && (!quoteButton.hidden || quoteHighlighted)) {
    if (!quoteButton.hidden) window.getSelection().removeAllRanges();
    window.closeQuotePopover();window.clearQuotedTextHighlight();
  }
});
