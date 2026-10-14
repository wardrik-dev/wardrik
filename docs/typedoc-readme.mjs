// Drops the SDK README's own heading on its page, where the page title stands in for it.
import { MarkdownPageEvent } from 'typedoc-plugin-markdown';

export function load(app) {
	app.renderer.on(MarkdownPageEvent.END, (page) => {
		if (page.url.endsWith('README.md')) page.contents = page.contents?.replace(/^# .*\n+/m, '');
	});
}
