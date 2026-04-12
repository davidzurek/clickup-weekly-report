"""Renders the self-service setup HTML form."""

from __future__ import annotations

from string import Template

from config import cfg

_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ClickUp Weekly Report \u2014 Setup</title>
  <style>
    body { font-family: sans-serif; max-width: 540px; margin: 60px auto; padding: 0 20px; color: #222; }
    h1 { font-size: 1.4rem; margin-bottom: 4px; }
    p.subtitle { color: #666; margin-top: 0; margin-bottom: 32px; font-size: 0.95rem; }
    label { display: block; font-size: 0.85rem; font-weight: 600; margin-bottom: 4px; margin-top: 16px; }
    input { width: 100%; padding: 8px 10px; border: 1px solid #ccc; border-radius: 4px; font-size: 0.95rem; box-sizing: border-box; }
    input:focus { outline: none; border-color: #4f46e5; box-shadow: 0 0 0 2px rgba(79,70,229,0.15); }
    p.hint { margin: 4px 0 0; font-size: 0.78rem; }
    p.hint.required { color: #6b7280; }
    p.hint.optional { color: #9ca3af; }
    p.hint code { background: #f3f4f6; padding: 1px 4px; border-radius: 3px; font-size: 0.78rem; }
    button { margin-top: 28px; width: 100%; padding: 10px; background: #4f46e5; color: #fff; border: none; border-radius: 4px; font-size: 1rem; cursor: pointer; }
    button:disabled { background: #a5b4fc; cursor: not-allowed; }
    #status { margin-top: 20px; padding: 12px; border-radius: 4px; font-size: 0.9rem; display: none; }
    #status.success { background: #d1fae5; color: #065f46; }
    #status.error   { background: #fee2e2; color: #991b1b; }
  </style>
</head>
<body>
  <h1>ClickUp Weekly Report</h1>
  <p class="subtitle">Fill in your details and click Submit. Your report will run automatically every Thursday.</p>

  <form id="form">
    <label for="provisioning_key">Provisioning Key <span style="font-weight:400;color:#666">(provided by your admin)</span></label>
    <input type="password" id="provisioning_key" name="provisioning_key" placeholder="Paste the key your admin sent you" required>
    <p class="hint required">Required</p>

    <label for="user_email">Your Google Account Email</label>
    <input type="email" id="user_email" name="user_email" placeholder="you@example.com" required>
    <p class="hint required">Required</p>

    <label for="user_id">ClickUp User ID</label>
    <input type="text" id="user_id" name="user_id" placeholder="e.g. 81687559" required>
    <p class="hint required">Required &mdash; find it in ClickUp under Teams &rarr; hover your name &rarr; three dots &rarr; Copy Member ID</p>

    <label for="doc_id">ClickUp Doc ID</label>
    <input type="text" id="doc_id" name="doc_id" placeholder="e.g. 2gcg7-284992" required>
    <p class="hint required">Required &mdash; the ID of the ClickUp Doc where your weekly pages will be created</p>

    <label for="parent_page_id">ClickUp Parent Page ID</label>
    <input type="text" id="parent_page_id" name="parent_page_id" placeholder="e.g. 2gcg7-435652" required>
    <p class="hint required">Required &mdash; the page inside the Doc that will contain your weekly report pages</p>

    <label for="cu_api_key">ClickUp API Key</label>
    <input type="password" id="cu_api_key" name="cu_api_key" placeholder="pk_..." required>
    <p class="hint required">Required &mdash; generate one in ClickUp: avatar &rarr; Settings &rarr; ClickUp API</p>

    <label for="anthropic_api_key">Anthropic API Key</label>
    <input type="password" id="anthropic_api_key" name="anthropic_api_key" placeholder="sk-ant-..." required>
    <p class="hint required">Required &mdash; generate one at platform.anthropic.com &rarr; API Keys</p>

    <hr style="margin: 28px 0 8px; border: none; border-top: 1px solid #e5e7eb;">
    <p style="font-size:0.85rem;color:#666;margin:0 0 8px;">The fields below are optional. Leave them blank to use your admin&rsquo;s defaults.</p>

    <label for="workspace_id">ClickUp Workspace ID <span style="font-weight:400;color:#666">(optional)</span></label>
    <input type="text" id="workspace_id" name="workspace_id" placeholder="Leave blank to use admin default">
    <p class="hint optional">Optional &mdash; default: <code>$workspace_id</code></p>

    <label for="folder_id">ClickUp Folder ID <span style="font-weight:400;color:#666">(optional)</span></label>
    <input type="text" id="folder_id" name="folder_id" placeholder="Leave blank to use admin default">
    <p class="hint optional">Optional &mdash; default: <code>$folder_id</code></p>

    <label for="lookback_days">Lookback Days <span style="font-weight:400;color:#666">(optional)</span></label>
    <input type="number" id="lookback_days" name="lookback_days" placeholder="Leave blank to use admin default" min="1" max="90">
    <p class="hint optional">Optional &mdash; how many days of completed tasks to include. Default: <code>$lookback_days</code></p>

    <label for="page_prefix">Page Prefix <span style="font-weight:400;color:#666">(optional)</span></label>
    <input type="text" id="page_prefix" name="page_prefix" placeholder="Leave blank to use admin default">
    <p class="hint optional">Optional &mdash; prefix added to each weekly page title (e.g. &ldquo;CW&rdquo; produces &ldquo;CW 15&rdquo;). Default: <code>$page_prefix</code></p>

    <button type="submit" id="btn">Submit</button>
  </form>

  <div id="status"></div>

  <script>
    document.getElementById('form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const btn    = document.getElementById('btn');
      const status = document.getElementById('status');
      btn.disabled    = true;
      btn.textContent = 'Setting up your report\u2026';
      status.style.display = 'none';

      const body = {};
      new FormData(e.target).forEach((v, k) => body[k] = v.trim());

      try {
        const res  = await fetch(window.location.href, {
          method:  'POST',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify(body),
        });
        const data = await res.json();

        if (res.ok) {
          status.className = 'success';
          status.innerHTML = '\u2713 All done! Your weekly report job has been created or updated. It will run automatically every Thursday at noon.';
        } else {
          status.className   = 'error';
          status.textContent = 'Error: ' + (data.error || 'Unknown error');
          btn.disabled       = false;
          btn.textContent    = 'Submit';
        }
      } catch (err) {
        status.className   = 'error';
        status.textContent = 'Network error: ' + err.message;
        btn.disabled       = false;
        btn.textContent    = 'Submit';
      }

      status.style.display = 'block';
    });
  </script>
</body>
</html>"""


def serve_form() -> str:
    return Template(_TEMPLATE).substitute(
        workspace_id=cfg.workspace_id,
        folder_id=cfg.folder_id,
        lookback_days=cfg.lookback_days,
        page_prefix=cfg.page_prefix,
    )
