// @ts-check
import { readFileSync } from 'node:fs';
import starlight from '@astrojs/starlight';
import { ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import { defineConfig } from 'astro/config';

// Code reads as the terminal does, on its dark ground, in light and dark alike.
const terminal = ExpressiveCodeTheme.fromJSONString(
	readFileSync(new URL('./src/styles/terminal-theme.json', import.meta.url), 'utf-8'),
);

export default defineConfig({
	site: 'https://docs.wardrik.dev',
	// Flags such as --node stay two hyphens, not a dash.
	markdown: { smartypants: false },
	integrations: [
		starlight({
			title: 'Wardrik',
			description: 'An agent runtime built on OTP.',
			logo: { light: './src/assets/mark-light.svg', dark: './src/assets/mark-dark.svg' },
			customCss: ['./src/styles/brand.css'],
			expressiveCode: {
				themes: [terminal],
				useStarlightUiThemeColors: false,
				// A command is code like any other: no terminal window around it.
				defaultProps: { frame: 'code' },
				styleOverrides: {
					borderRadius: '4px',
					borderColor: '#1d2a31',
					codeFontFamily: "'IBM Plex Mono', ui-monospace, monospace",
					uiFontFamily: "'IBM Plex Sans', system-ui, sans-serif",
					frames: {
						shadowColor: 'transparent',
						frameBoxShadowCssValue: 'none',
						editorTabBarBackground: '#151d21',
						editorActiveTabBackground: '#10181d',
						editorTabBarBorderBottomColor: '#1d2a31',
					},
				},
			},
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
				{ label: 'Recipes', items: [{ autogenerate: { directory: 'recipes' } }] },
				{ label: 'Concepts', items: [{ autogenerate: { directory: 'concepts' } }] },
				{ label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] },
				{ label: 'Operate', items: [{ autogenerate: { directory: 'operate' } }] },
				{ label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
			],
		}),
	],
});
