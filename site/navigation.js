(() => {
  const header = document.querySelector('body > header');
  if (!header) return;

  const position = () => Math.max(0, Math.min(scrollY,
    Math.max(0, document.documentElement.scrollHeight - innerHeight)));
  let previous = position(), direction = 0, distance = 0, frame = 0;

  function update() {
    frame = 0;
    const current = position(), delta = current - previous;
    previous = current;
    header.classList.toggle('is-scrolled', current > 20);
    if (current <= header.offsetHeight) {
      header.classList.remove('is-hidden');
      distance = 0;
    } else if (delta !== 0) {
      const nextDirection = Math.sign(delta);
      distance = nextDirection === direction ? distance + Math.abs(delta) : Math.abs(delta);
      direction = nextDirection;
      // Ignore tiny trackpad movements so the navigation does not flicker.
      if (distance >= 10) {
        header.classList.toggle('is-hidden', direction > 0);
        distance = 0;
      }
    }
  }

  function queue() {
    if (!frame) frame = requestAnimationFrame(update);
  }
  addEventListener('scroll', queue, { passive: true });
  addEventListener('resize', queue);
  addEventListener('pageshow', queue);
  header.addEventListener('focusin', () => header.classList.remove('is-hidden'));
  update();
})();
