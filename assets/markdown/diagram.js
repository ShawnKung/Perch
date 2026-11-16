window.mapDiagramColors = (svg, replace) => {
  svg.querySelectorAll('style').forEach(style => style.textContent = replace(style.textContent));
  for (const element of [svg, ...svg.querySelectorAll('*')]) {
    for (const attribute of ['style', 'fill', 'stroke', 'stop-color']) {
      if (element.hasAttribute(attribute)) element.setAttribute(attribute, replace(element.getAttribute(attribute)));
    }
  }
};
window.diagramPNG = async svgText => {
  const svg = new DOMParser().parseFromString(svgText, 'image/svg+xml').documentElement;
  mapDiagramColors(svg, value => value.replace(/var\(--perch-(accent|mint|sidebar|line)\)/g,
    (_, name) => getComputedStyle(document.documentElement).getPropertyValue('--perch-' + name).trim()));
  const box = svg.viewBox.baseVal;
  const width = box.width || parseFloat(svg.getAttribute('width')) || 800;
  const height = box.height || parseFloat(svg.getAttribute('height')) || 600;
  if (![width, height].every(n => Number.isFinite(n) && n > 0)) throw new Error('无效图表尺寸');
  svg.setAttribute('width', width); svg.setAttribute('height', height);
  svg.style.maxWidth = 'none';
  const image = new Image();
  image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(svg));
  await image.decode();
  const scale = Math.min(2, 4096 / width, 4096 / height);
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(width * scale)); canvas.height = Math.max(1, Math.round(height * scale));
  const context = canvas.getContext('2d');
  context.fillStyle = '#ffffff'; context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL('image/png');
};

window.makeDiagram = (svgText, source, viewer = false) => {
  const card = document.createElement('section'); card.className = 'mermaid-diagram' + (viewer ? ' diagram-viewer' : '');
  const toolbar = document.createElement('div'); toolbar.className = 'diagram-toolbar';
  const image = document.createElement('div'); image.className = 'diagram-image';
  image.innerHTML = DOMPurify.sanitize(svgText, {USE_PROFILES:{svg:true,svgFilters:true}, FORBID_TAGS:['foreignObject']});
  const svg = image.querySelector('svg');
  if (!svg) throw new Error('图表未生成');
  // Theme only SVG colors; preserve labels, geometry and the current viewport.
  mapDiagramColors(svg, value => {
    for (const [name, color] of Object.entries(window.perchDiagramColors || {})) {
      value = value.replace(new RegExp(color, 'gi'), 'var(--perch-' + name + ')');
    }
    return value;
  });
  const cleanSVG = svg.outerHTML;
  const sourcePane = document.createElement('div'); sourcePane.className = 'diagram-source'; sourcePane.hidden = true;
  const sourceToolbar = document.createElement('div'); sourceToolbar.className = 'diagram-source-toolbar';
  const pre = document.createElement('pre');
  const code = document.createElement('code'); code.textContent = source; pre.append(code);
  sourcePane.append(sourceToolbar, pre);
  const send = body => window.webkit.messageHandlers.markdown.postMessage(body);
  const button = (action, label, click, container = toolbar) => {
    const element = document.createElement('button'); element.type = 'button';
    element.dataset.action = action; element.textContent = label; element.onclick = click;
    container.append(element); return element;
  };
  const modeControl = document.createElement('div'); modeControl.className = 'diagram-mode'; toolbar.append(modeControl);
  const toggle = button('mode', '', () => mode(sourcePane.hidden), modeControl);
  toggle.className = 'diagram-switch'; toggle.setAttribute('role', 'switch'); toggle.setAttribute('aria-label', '显示源码');
  const modeLabel = document.createElement('span'); modeLabel.className = 'diagram-mode-label'; modeControl.append(modeLabel);
  const copy = button('copy', '复制源码', () => {send({copy:source}); copy.textContent = '已复制';}, sourceToolbar);
  image.oncontextmenu = event => {
    event.preventDefault();
    send({diagramMenu:cleanSVG, x:event.clientX, y:event.clientY});
  };
  let fit = () => {};
  const zoomButtons = [];
  function mode(isSource) {
    image.hidden = isSource; sourcePane.hidden = !isSource;
    toggle.setAttribute('aria-checked', String(isSource)); modeLabel.textContent = isSource ? '源码' : '图片';
    zoomButtons.forEach(b => b.disabled = isSource);
    if (!isSource && viewer) requestAnimationFrame(fit);
  }
  {
    let scale = 1, x = 0, y = 0, drag = null, dragged = false, baseline = null, fittedWidth = 0;
    const box = svg.viewBox.baseVal;
    const width = box.width || parseFloat(svg.getAttribute('width')) || 800;
    const height = box.height || parseFloat(svg.getAttribute('height')) || 600;
    svg.style.width = width + 'px'; svg.style.height = height + 'px'; svg.style.maxWidth = 'none';
    let reset;
    const apply = () => {
      svg.style.transform = `translate(${x}px,${y}px) scale(${scale})`; card.dataset.scale = scale;
      if (!viewer && reset) reset.hidden = !baseline ||
        (Math.abs(scale - baseline.scale) < 0.00001 && Math.abs(x - baseline.x) < 0.01 && Math.abs(y - baseline.y) < 0.01);
    };
    const zoom = (factor, px = image.clientWidth / 2, py = image.clientHeight / 2) => {
      const next = Math.max(0.05, Math.min(8, scale * factor));
      x = px - (px - x) * next / scale; y = py - (py - y) * next / scale; scale = next; apply();
    };
    fit = () => {
      if (image.hidden) return;
      if (viewer) {
        scale = Math.max(0.05, Math.min(2, (image.clientWidth - 48) / width, (image.clientHeight - 48) / height));
        y = (image.clientHeight - height * scale) / 2;
      } else {
        scale = Math.min(1, Math.max(1, image.clientWidth - 20) / width);
        image.style.height = (height * scale + 20) + 'px'; y = 10;
      }
      x = (image.clientWidth - width * scale) / 2;
      baseline = {scale, x, y}; fittedWidth = image.clientWidth; apply();
    };
    if (viewer) {
      zoomButtons.push(button('zoom-out', '−', () => zoom(1 / 1.25)), button('zoom-in', '＋', () => zoom(1.25)),
        button('reset', '还原', fit));
      zoomButtons[0].setAttribute('aria-label', '缩小图表'); zoomButtons[1].setAttribute('aria-label', '放大图表');
      button('fullscreen', '全屏', () => send({fullscreen:true}));
    } else {
      reset = button('reset', '还原', event => {event.stopPropagation(); fit();}, image);
      reset.className = 'diagram-reset'; reset.hidden = true;
      image.onclick = event => {
        if (dragged) {dragged = false; return;}
        if (!event.ctrlKey) send({diagram:cleanSVG, source});
      };
      image.title = '滚轮缩放，拖动平移，点击放大';
    }
    image.addEventListener('wheel', event => {
      event.preventDefault(); const rect = image.getBoundingClientRect();
      zoom(Math.exp(-event.deltaY * 0.008), event.clientX - rect.left, event.clientY - rect.top);
    }, {passive:false});
    let gestureScale = 1;
    image.addEventListener('gesturestart', event => {event.preventDefault(); gestureScale = 1;});
    image.addEventListener('gesturechange', event => {
      event.preventDefault(); zoom(event.scale / gestureScale); gestureScale = event.scale;
    });
    image.addEventListener('gestureend', () => {gestureScale = 1;});
    image.onpointerdown = event => {
      if (event.button !== 0 || event.ctrlKey || event.target.closest('button')) return;
      dragged = false;
      drag = {id:event.pointerId, px:event.clientX, py:event.clientY, x, y};
      image.setPointerCapture(event.pointerId); image.classList.add('dragging'); event.preventDefault();
    };
    image.onpointermove = event => {
      if (!drag || event.pointerId !== drag.id) return;
      if (!dragged && Math.hypot(event.clientX - drag.px, event.clientY - drag.py) < 3) return;
      dragged = true;
      x = drag.x + event.clientX - drag.px; y = drag.y + event.clientY - drag.py; apply();
    };
    const release = () => {drag = null; image.classList.remove('dragging');};
    image.onpointerup = release; image.onpointercancel = release; image.onlostpointercapture = release;
    new ResizeObserver(() => {
      if (viewer || !baseline || image.clientWidth !== fittedWidth) fit();
      if (!viewer) window.updateDiagramBounds?.();
    }).observe(image);
  }
  card.append(toolbar, image, sourcePane); mode(false); return card;
};
