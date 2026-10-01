// @ts-check
import starlight from '@astrojs/starlight';
import starlightCatppuccin from '@catppuccin/starlight';
import { defineConfig } from 'astro/config';

export default defineConfig({
	site: 'https://docs.wardrik.dev',
	// Flags such as --node stay two hyphens, not a dash.
	markdown: { smartypants: false },
	integrations: [
		starlight({
			title: 'Wardrik',
			description: 'An agent runtime built on OTP.',
			plugins: [starlightCatppuccin()],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/wardrik-dev/wardrik' }],
			editLink: { baseUrl: 'https://github.com/wardrik-dev/wardrik/edit/main/docs/' },
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ label: 'Install', slug: 'getting-started/install' },
						{ label: 'Quickstart', slug: 'getting-started/quickstart' },
					],
				},
				{
					label: 'Reference',
					items: [{ autogenerate: { directory: 'reference' } }],
				},
			],
		}),
	],
});
