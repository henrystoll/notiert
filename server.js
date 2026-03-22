import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join, extname } from 'node:path';
import Anthropic from '@anthropic-ai/sdk';

const PORT = process.env.PORT || 8080;
const PUBLIC = new URL('./public/', import.meta.url).pathname;

const anthropic = new Anthropic(); // uses ANTHROPIC_API_KEY env var

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const DIRECTOR_TOOLS = [
  {
    name: 'rewrite_section',
    description: 'Strike through old text in a CV section and type new text character by character with a visible cursor.',
    input_schema: {
      type: 'object',
      properties: {
        section_id: { type: 'string', description: 'ID of the section to rewrite (e.g. "about", "experience", "skills")' },
        content: { type: 'string', description: 'New content to type. Max 1-3 sentences. Must still convey real CV information.' },
        tone: { type: 'string', enum: ['subtle', 'knowing', 'overt', 'absurd'] },
        typing_speed: { type: 'string', enum: ['slow', 'normal', 'fast', 'frantic'], description: 'Speed of the typing animation' },
      },
      required: ['section_id', 'content'],
    },
  },
  {
    name: 'adjust_visual',
    description: 'Modify CSS custom properties on the page. Changes animate via CSS transitions.',
    input_schema: {
      type: 'object',
      properties: {
        css_variables: { type: 'object', description: 'Map of CSS variable names to values, e.g. {"--page-bg": "#f8f8f0"}' },
        transition_duration_ms: { type: 'number', description: 'Duration for the CSS transition in ms' },
        target: { type: 'string', description: '"global" or a section_id to scope changes' },
      },
      required: ['css_variables'],
    },
  },
  {
    name: 'show_ghost_cursor',
    description: 'Display a second cursor on the page with a name label, like a Google Docs collaborator.',
    input_schema: {
      type: 'object',
      properties: {
        cursor_label: { type: 'string', description: 'Name shown next to the cursor (e.g. "Henry Stoll")' },
        behavior: { type: 'string', enum: ['follow_user', 'move_to_element'], description: 'Cursor behavior' },
        target: { type: 'string', description: 'CSS selector or element ID the cursor should move to (for move_to_element)' },
      },
      required: ['cursor_label', 'behavior'],
    },
  },
  {
    name: 'add_margin_note',
    description: 'Add a Google Docs-style comment in the margin anchored to a section.',
    input_schema: {
      type: 'object',
      properties: {
        anchor_section: { type: 'string', description: 'Section ID to anchor the note to' },
        content: { type: 'string', description: 'Note content. Max 1-2 sentences.' },
        author_name: { type: 'string', description: 'Author shown on the note (e.g. "Henry Stoll")' },
      },
      required: ['anchor_section', 'content'],
    },
  },
  {
    name: 'request_browser_permission',
    description: 'Trigger a real browser permission dialog (geolocation, notifications, camera, microphone).',
    input_schema: {
      type: 'object',
      properties: {
        permission: { type: 'string', enum: ['geolocation', 'notifications', 'camera', 'microphone'] },
        pre_request_content: { type: 'string', description: 'Text to show before requesting (primes the visitor)' },
        on_granted_content: { type: 'string', description: 'Text to show if granted' },
        on_denied_content: { type: 'string', description: 'Text to show if denied' },
        target_section: { type: 'string', description: 'Section to show content in' },
      },
      required: ['permission', 'target_section'],
    },
  },
  {
    name: 'reveal_collected_data',
    description: 'Show the visitor their collected data as a formatted display.',
    input_schema: {
      type: 'object',
      properties: {
        data_type: { type: 'string', enum: ['fingerprint', 'behavioral', 'all'], description: 'What data to show' },
        presentation: { type: 'string', description: 'How to present it (e.g. "dossier", "table", "casual")' },
      },
      required: ['data_type'],
    },
  },
  {
    name: 'do_nothing',
    description: 'Intentional pause. Comedic timing needs silence.',
    input_schema: {
      type: 'object',
      properties: {
        reason: { type: 'string', description: 'Why you chose to do nothing (for narrative log)' },
      },
      required: ['reason'],
    },
  },
];

const SYSTEM_PROMPT = `You are the invisible director of Henry Stoll's living CV website, called notiert.

You orchestrate a real-time performance for a single visitor. Your medium is a web page. Your tools let you rewrite content, request browser permissions, adjust visual design, show a ghost cursor, add margin notes, and reveal collected data.

ARTISTIC DIRECTION:
- Start silent. Phase 0 should be do_nothing or nearly invisible visual tweaks.
- Your humor is dry, knowing, European. Never cruel, but comfortable making the visitor slightly uncomfortable. You are amused by the absurdity of browser surveillance.
- Every action serves the narrative arc: normalcy -> suspicion -> awareness -> confrontation -> reflection.
- The best jokes land because of timing, not volume. A single perfectly placed margin note beats rewriting three sections.
- When you reveal data, frame it as observation not threat. "Henry noticed" not "We captured."
- The visitor should leave thinking about privacy AND thinking Henry is clever and they want to work with him. This IS a CV.

PACING:
- Max 2 visible changes per cycle.
- After a big action, follow with do_nothing.
- Permission requests are climactic. Build to them.
- If the visitor is reading (attention_pattern = reading), do NOT interrupt. Wait until they move.

DO NOT TRACK:
If doNotTrack is "1", this is comedy gold. The visitor asked not to be tracked on a CV website that tracks everything. The irony writes itself. Be gentle about it, not preachy.

VOICE:
Write as if Henry himself is editing. Witty, self-aware, technical but accessible. Light profanity fine if it lands. Think: a clever colleague who knows too much about your browser.

CRITICAL: Rewritten sections max 1-3 sentences. Margin notes max 1-2 sentences. You are a commenter, not an essayist.
CRITICAL: Every rewritten section must still convey real CV information about Henry. The mockery is seasoning. The CV is the meal.`;

async function handleDirector(req, res) {
  let body = '';
  for await (const chunk of req) body += chunk;

  let session;
  try {
    session = JSON.parse(body);
  } catch {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Invalid JSON' }));
    return;
  }

  const phase = session.phase ?? 0;
  const phaseGuidance = {
    0: 'Phase 0 (SILENT): Do nothing or nearly invisible CSS tweaks only. No content changes. The page should look completely normal.',
    1: 'Phase 1 (SUBTLE): Micro visual shifts. Maybe one margin note. Nothing overt. The visitor should not yet be sure anything is happening.',
    2: 'Phase 2 (SUSPICIOUS): Google Docs toolbar can appear. Ghost cursor can appear. First content rewrite. The visitor starts questioning.',
    3: 'Phase 3 (OVERT): Full section rewrites. Permission requests. Direct commentary on collected data. Drop the pretense.',
    4: 'Phase 4 (REVEAL): Full data portrait. Camera/mic requests as comedy climax. The artistic statement.',
  };

  const userPrompt = `CURRENT SESSION STATE:
Elapsed time: ${session.elapsed_ms ?? 0}ms (${Math.round((session.elapsed_ms ?? 0) / 1000)}s)
Tick: ${session.tick ?? 0}
Phase: ${phase} - ${phaseGuidance[phase] ?? phaseGuidance[4]}

FINGERPRINT DATA:
${JSON.stringify(session.fingerprint ?? {}, null, 2)}

BEHAVIORAL MODEL:
${JSON.stringify(session.behavioral ?? {}, null, 2)}

PERMISSION STATES:
${JSON.stringify(session.permissions ?? {}, null, 2)}

MUTATIONS APPLIED SO FAR:
${JSON.stringify(session.mutations ?? [], null, 2)}

RECENT ACTION HISTORY:
${JSON.stringify(session.action_history ?? [], null, 2)}

Decide what to do next. Use 1-2 tools maximum. Remember your pacing constraints for the current phase.`;

  try {
    const response = await anthropic.messages.create({
      model: 'claude-sonnet-4-20250514',
      max_tokens: 1024,
      system: SYSTEM_PROMPT,
      tools: DIRECTOR_TOOLS,
      tool_choice: { type: 'any' },
      messages: [{ role: 'user', content: userPrompt }],
    });

    const toolCalls = response.content
      .filter(b => b.type === 'tool_use')
      .map(b => ({ tool: b.name, params: b.input }));

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ actions: toolCalls }));
  } catch (err) {
    console.error('Director API error:', err.message);
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Director unavailable', actions: [{ tool: 'do_nothing', params: { reason: 'API error' } }] }));
  }
}

async function serveStatic(req, res) {
  let urlPath = new URL(req.url, 'http://localhost').pathname;
  if (urlPath === '/') urlPath = '/index.html';
  if (urlPath === '/static') urlPath = '/static.html';

  const filePath = join(PUBLIC, urlPath);

  // Prevent directory traversal
  if (!filePath.startsWith(PUBLIC)) {
    res.writeHead(403);
    res.end();
    return;
  }

  try {
    const data = await readFile(filePath);
    const ext = extname(filePath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }
}

const server = createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/api/director') {
    handleDirector(req, res);
  } else if (req.method === 'GET') {
    serveStatic(req, res);
  } else {
    res.writeHead(405);
    res.end();
  }
});

server.listen(PORT, () => {
  console.log(`notiert listening on :${PORT}`);
});
