// @ts-check
import { readFileSync } from 'node:fs';
import starlight from '@astrojs/starlight';
import { ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import { defineConfig } from 'astro/config';

// Code sits on one dark ground, in light and dark alike.
const terminal = ExpressiveCodeTheme.fromJSONString(
	readFileSync(new URL('./src/styles/terminal-theme.json', import.meta.url), 'utf-8'),
);

export default defineConfig({
	site: 'https://docs.wardrik.dev',
	// Flags such as --node stay two hyphens, not a dash.
	markdown: { smartypants: false },
	// Pages that moved, from where links to them may still point.
	redirects: { '/guides/slack/': '/channels/slack/', '/guides/schedules/': '/guides/triggers/' },
	integrations: [
		starlight({
			title: 'Wardrik',
			description: 'An agent runtime built on OTP.',
			components: { SiteTitle: './src/components/SiteTitle.astro' },
			customCss: ['./src/styles/brand.css'],
			expressiveCode: {
				themes: [terminal],
				useStarlightUiThemeColors: false,
				// A command is code like any other: no terminal window around it.
				defaultProps: { frame: 'code' },
				styleOverrides: {
					borderRadius: '8px',
					borderColor: '#23272e',
					codeFontFamily: "'Geist Mono', ui-monospace, monospace",
					codeFontSize: '0.84375rem',
					uiFontFamily: "'Geist Sans', system-ui, sans-serif",
					frames: {
						shadowColor: 'transparent',
						frameBoxShadowCssValue: 'none',
						editorTabBarBackground: '#0f1115',
						editorActiveTabBackground: '#0f1115',
						editorActiveTabForeground: '#9aa3ae',
						editorActiveTabIndicatorBottomColor: 'transparent',
						editorTabBarBorderBottomColor: '#22262d',
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
				{ label: 'Channels', items: [{ autogenerate: { directory: 'channels' } }] },
				{ label: 'Recipes', items: [{ autogenerate: { directory: 'recipes' } }] },
				{ label: 'Concepts', items: [{ autogenerate: { directory: 'concepts' } }] },
				{ label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] },
				{ label: 'Operate', items: [{ autogenerate: { directory: 'operate' } }] },
				{ label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
			],
		}),
	],
});
