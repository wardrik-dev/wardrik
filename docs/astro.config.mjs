// @ts-check
import { readFileSync } from 'node:fs';
import starlight from '@astrojs/starlight';
import { ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import { defineConfig } from 'astro/config';
import starlightSidebarTopics from 'starlight-sidebar-topics';

// Code sits on one dark ground, in light and dark alike.
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
			// Three topics, each with a sidebar of its own; the header shows them as tabs.
			plugins: [
				starlightSidebarTopics(
					[
						{
							label: 'Docs',
							link: '/getting-started/install/',
							items: [
								{
									label: 'Get started',
									items: [
										{ label: 'Install', slug: 'getting-started/install' },
										{ label: 'Quickstart', slug: 'getting-started/quickstart' },
									],
								},
								{ label: 'Concepts', items: [{ autogenerate: { directory: 'concepts' } }] },
								{ label: 'Build', items: [{ autogenerate: { directory: 'build' } }] },
								{ label: 'Channels', items: [{ autogenerate: { directory: 'channels' } }] },
								{ label: 'Run', items: [{ autogenerate: { directory: 'run' } }] },
							],
						},
						{
							label: 'Examples',
							link: '/examples/',
							items: [
								{ label: 'Overview', slug: 'examples' },
								{
									label: 'Everyday agents',
									items: [
										'examples/morning-brief',
										'examples/telegram-assistant',
										'examples/skills',
										'examples/browser-errands',
									],
								},
								{
									label: 'For a team',
									items: ['examples/on-call-triage', 'examples/competitor-watch', 'examples/act-on-signals'],
								},
								{ label: 'Try to break it', items: ['examples/pull-the-plug', 'examples/hijack-me'] },
							],
						},
						{
							label: 'Reference',
							link: '/reference/cli/',
							items: [{ autogenerate: { directory: 'reference' } }],
						},
					],
					{ exclude: ['/'] },
				),
			],
		}),
	],
});
