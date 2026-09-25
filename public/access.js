// Capture and erase the one-use fragment before any private request or app startup.
let handoff = new URLSearchParams(location.hash.slice(1)).get('handoff');
if (location.hash) history.replaceState(null, '', location.pathname + location.search);

async function signIn(value) {
  const response = await fetch('/api/session', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-Circuit-Request': '1' },
    body: JSON.stringify({ handoff: value }),
  });
  return response.ok;
}

// A launcher can open its link in an existing localhost tab. A fragment-only
// navigation does not reload ES modules, so consume that handoff explicitly too.
window.addEventListener('hashchange', async () => {
  const value = new URLSearchParams(location.hash.slice(1)).get('handoff');
  history.replaceState(null, '', location.pathname + location.search);
  if (!value) return;
  try { if (await signIn(value)) location.reload(); } catch { /* existing form remains available */ }
});

async function authenticate() {
  if (handoff) {
    const value = handoff;
    handoff = null;
    try { if (await signIn(value)) return; } catch { /* show retry form */ }
  }
  try { if ((await fetch('/api/session', { credentials: 'same-origin' })).ok) return; } catch { /* show retry form */ }
  const panel = document.createElement('div');
  panel.className = 'access-screen';
  panel.innerHTML = `<form class="access-form"><h1>Sign in to Circuit</h1>
    <p>Open Circuit and choose your repository again for a fresh sign-in link. If you started Circuit from the command line, restart that server.</p>
    <p>Open the new link, or paste it here within one minute. Your session lasts one hour.</p>
    <label>One-use sign-in link <input name="handoff" type="password" autocomplete="off" required></label>
    <button type="submit">Sign in</button><p role="status"></p></form>`;
  document.body.append(panel);
  await new Promise(resolve => {
    panel.querySelector('form').addEventListener('submit', async event => {
      event.preventDefault();
      const input = panel.querySelector('input');
      const value = input.value.trim();
      input.value = '';
      let key = value;
      try { key = new URLSearchParams(new URL(value).hash.slice(1)).get('handoff'); } catch { /* raw capability */ }
      try {
        if (await signIn(key)) { panel.remove(); resolve(); return; }
        panel.querySelector('[role=status]').textContent = 'That link expired or was already used. Open Circuit again for a fresh link.';
      } catch { panel.querySelector('[role=status]').textContent = 'Circuit is unavailable. Restart Circuit and use the new link.'; }
    });
  });
}

await authenticate();
const logout = document.createElement('button');
logout.className = 'access-logout';
logout.textContent = 'Sign out';
logout.onclick = async () => {
  const response = await apiFetch('/api/logout', { method: 'POST' });
  if (response.ok) location.reload();
};
document.body.append(logout);

export async function apiFetch(url, options = {}) {
  if (options.method === 'POST') {
    options = { ...options, headers: { ...options.headers, 'Content-Type': 'application/json', 'X-Circuit-Request': '1' }, body: options.body ?? '{}' };
  }
  const response = await fetch(url, { ...options, credentials: 'same-origin' });
  if (response.status === 401) location.reload();
  return response;
}
