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

const quoteButton=document.createElement('button');
quoteButton.id='quote-selection'; quoteButton.type='button'; quoteButton.textContent='引用到对话';
quoteButton.hidden=true; document.body.append(quoteButton);
let selectedQuote='';
window.answerSelection=()=>{
  const selection=window.getSelection(), root=document.getElementById('content');
  if (!window.quoteEnabled || !selection || selection.isCollapsed || !selection.rangeCount ||
      !root.contains(selection.anchorNode) || !root.contains(selection.focusNode)) return null;
  const rect=selection.getRangeAt(0).getBoundingClientRect();
  return rect.width>0 && rect.height>0 ? selection : null;
};
window.updateQuoteSelection=()=>{
  const selection=window.answerSelection();
  selectedQuote=selection ? selection.toString().trim() : '';
  quoteButton.hidden=!selectedQuote;
  if (!selectedQuote) {
    if (window.pendingMarkdown != null) {
      const text=window.pendingMarkdown;window.pendingMarkdown=null;window.renderMarkdown(text);
    }
    return;
  }
  const rect=selection.getRangeAt(0).getBoundingClientRect(), viewport=window.quoteViewport || {top:0,bottom:innerHeight};
  quoteButton.disabled=Array.from(selectedQuote).length>12000;
  quoteButton.title=quoteButton.disabled ? '请选择不超过 12,000 字的片段' : '将选中文字作为本次提问的引用';
  quoteButton.style.left=Math.max(4,Math.min(rect.left,innerWidth-quoteButton.offsetWidth-4))+'px';
  quoteButton.style.top=Math.max(viewport.top+4,Math.min(rect.top-quoteButton.offsetHeight-6,viewport.bottom-quoteButton.offsetHeight-4))+'px';
};
quoteButton.addEventListener('mousedown',event=>event.preventDefault());
quoteButton.addEventListener('click',()=>{
  if (!selectedQuote || quoteButton.disabled) return;
  window.webkit.messageHandlers.markdown.postMessage({quote:selectedQuote});
  window.getSelection().removeAllRanges();quoteButton.hidden=true;
});
document.addEventListener('selectionchange',()=>requestAnimationFrame(window.updateQuoteSelection));
window.addEventListener('resize',window.updateQuoteSelection);
document.addEventListener('keydown',event=>{
  if (event.key==='Escape' && !quoteButton.hidden) {window.getSelection().removeAllRanges();quoteButton.hidden=true;}
});
