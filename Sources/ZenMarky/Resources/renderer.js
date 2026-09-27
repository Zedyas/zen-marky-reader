/* Runs only in JavaScriptCore. Document web views have JavaScript disabled. */
function renderMarkdown(source) {
  const md = markdownit({ html: false, linkify: true, typographer: false });
  const front = frontMatter(source, md.utils.escapeHtml);
  // Keep table layout intact while allowing wide tables to scroll independently.
  md.renderer.rules.table_open = () => '<div class="table-scroll" role="region" aria-label="Table" tabindex="0"><table>\n';
  md.renderer.rules.table_close = () => '</table></div>\n';
  const headings = new Map();
  md.renderer.rules.heading_open = (tokens, index, options, env, renderer) => {
    const text = tokens[index + 1].content;
    const base = text.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').trim().replace(/\s+/g, '-') || 'section';
    const count = headings.get(base) || 0;
    headings.set(base, count + 1);
    tokens[index].attrSet('id', count ? `${base}-${count}` : base);
    return renderer.renderToken(tokens, index, options);
  };
  // Mermaid blocks are left as source for the app to draw. Other code blocks get a
  // copy link carrying the block's position; the app reads the text from the page.
  let codeBlocks = 0;
  const withCopyLink = rule => (tokens, index, options, env, renderer) => {
    const token = tokens[index];
    if (token.type === 'fence' && token.info.trim().split(/\s+/)[0].toLowerCase() === 'mermaid') {
      return `<pre class="mermaid">${md.utils.escapeHtml(token.content)}</pre>\n`;
    }
    return `<div class="code-block"><a class="code-copy" href="marky-copy:${codeBlocks++}" title="Copy" aria-label="Copy code"></a>${rule(tokens, index, options, env, renderer)}</div>\n`;
  };
  md.renderer.rules.fence = withCopyLink(md.renderer.rules.fence);
  md.renderer.rules.code_block = withCopyLink(md.renderer.rules.code_block);
  md.core.ruler.after('inline', 'task_lists', state => {
    const tokens = state.tokens;
    for (let i = 2; i < tokens.length; i++) {
      const token = tokens[i];
      if (token.type !== 'inline' || tokens[i - 1].type !== 'paragraph_open' || tokens[i - 2].type !== 'list_item_open') continue;
      const first = token.children && token.children[0];
      if (!first || first.type !== 'text' || !/^\[[ xX]\]\s/.test(first.content)) continue;
      const checked = first.content[1].toLowerCase() === 'x';
      first.content = first.content.slice(4);
      // The link carries the item's source line so the app can flip the marker in the file.
      const line = tokens[i - 2].map[0];
      const checkbox = new state.Token('html_inline', '', 0);
      checkbox.content = `<a class="task-toggle" href="marky-task:${line}" role="checkbox" aria-checked="${checked}" aria-label="Task"></a>`;
      token.children.unshift(checkbox);
      tokens[i - 2].attrJoin('class', 'task-item');
    }
  });
  return front.html + md.render(front.body);
}

// A YAML block between --- lines at the very top becomes one line of key and value
// pairs. Only top-level keys with a value or a list are shown. The block is replaced
// by the same number of empty lines so task line numbers still match the file.
function frontMatter(source, escape) {
  const match = source.match(/^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/);
  if (!match) return { html: '', body: source };
  const pairs = [];
  const unquote = value => value.trim().replace(/^(['"])(.*)\1$/, '$2');
  const clean = value => {
    const list = value.trim().match(/^\[(.*)\]$/);
    return list ? list[1].split(',').map(unquote).filter(Boolean).join(', ') : unquote(value);
  };
  for (const line of match[1].split(/\r?\n/)) {
    const pair = line.match(/^([\w-]+):[ \t]*(.*)$/);
    const item = line.match(/^\s+-\s+(.*)$/);
    if (pair) pairs.push([pair[1], pair[2].trim() ? [clean(pair[2])] : []]);
    else if (item && pairs.length) pairs[pairs.length - 1][1].push(clean(item[1]));
  }
  // A file that opens with a divider and has another later is ordinary Markdown.
  if (!pairs.length) return { html: '', body: source };
  const shown = pairs.filter(([, values]) => values.length && values.join(''));
  const html = shown.length
    ? `<dl class="front-matter">${shown.map(([key, values]) => `<div><dt>${escape(key)}</dt><dd>${escape(values.join(', '))}</dd></div>`).join('')}</dl>\n`
    : '';
  return { html, body: '\n'.repeat(match[0].split('\n').length - 1) + source.slice(match[0].length) };
}
