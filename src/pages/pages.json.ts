// Every page as Markdown, with its title, description and URL, for the assistant's docs tool.
// The TypeScript SDK reference is left out: it's generated, and the SDK's package documents it.
import { getCollection } from 'astro:content';
import type { APIRoute } from 'astro';

export const GET: APIRoute = async ({ site }) => {
	const docs = await getCollection('docs', (doc) => !doc.id.startsWith('sdk/') && !doc.data.draft);

	const pages = docs
		.sort((a, b) => a.id.localeCompare(b.id))
		.map((doc) => ({
			title: doc.data.title,
			description: doc.data.description ?? null,
			url: new URL(doc.id === 'index' ? '/' : `/${doc.id}/`, site).href,
			markdown: doc.body ?? '',
		}));

	return new Response(JSON.stringify({ pages }), {
		headers: { 'Content-Type': 'application/json; charset=utf-8' },
	});
};
