(() => {
  const box = document.getElementById('companion-lineup');
  if (!box) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const duration = CompanionArt.states.find(state => state.id === 'energetic').duration * 1000;
  const resetters = [];

  for (const preset of CompanionArt.presets) {
    const figure = document.createElement('figure');
    const button = document.createElement('button');
    const canvas = document.createElement('canvas');
    const caption = document.createElement('figcaption');
    button.type = 'button';
    button.className = 'companion-greeting';
    button.setAttribute('aria-label', `${preset.name}，播放精神好动画`);
    canvas.width = 200;
    canvas.height = 160;
    canvas.setAttribute('aria-hidden', 'true');
    caption.textContent = preset.name;
    button.append(canvas);
    figure.append(button, caption);
    box.append(figure);

    let playing = false, frame = 0, timer = 0;
    function draw(mode, time = 0, still = true) {
      CompanionArt.draw(canvas, preset.id, CompanionArt.poseAt(preset.id, mode, time, still),
        time, { x: 0, y: 0 }, 0, still);
    }
    function reset() {
      cancelAnimationFrame(frame);
      clearTimeout(timer);
      playing = false;
      draw('idle');
    }
    function greet() {
      if (playing || document.hidden) return;
      playing = true;
      if (reduced.matches) {
        draw('energetic');
        timer = setTimeout(reset, 600);
        return;
      }
      let start;
      function tick(now) {
        start ??= now;
        const elapsed = now - start;
        if (elapsed >= duration) { reset(); return; }
        draw('energetic', elapsed / 1000, false);
        frame = requestAnimationFrame(tick);
      }
      frame = requestAnimationFrame(tick);
    }
    button.addEventListener('pointerenter', event => {
      if (event.pointerType === 'mouse') greet();
    });
    button.addEventListener('pointerdown', event => {
      if (event.pointerType === 'touch' || event.pointerType === 'pen') greet();
    }, { passive: true });
    button.addEventListener('click', greet);
    resetters.push(reset);
    reset();
  }
  reduced.addEventListener('change', () => resetters.forEach(reset => reset()));
})();
