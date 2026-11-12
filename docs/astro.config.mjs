// @ts-check
import { readFileSync } from 'node:fs';
import starlight from '@astrojs/starlight';
import { ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import { defineConfig } from 'astro/config';
import starlightSidebarTopics from 'starlight-sidebar-topics';
import starlightTypeDoc, { typeDocSidebarGroup } from 'starlight-typedoc';

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
			description: 'A self-hosted runtime for persistent AI agents, with tool permissions, approvals, and crash recovery.',
			components: {
				SiteTitle: './src/components/SiteTitle.astro',
				Hero: './src/components/HomeHero.astro',
			},
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
					// Line markers in the brand's state colours: Ember for a call that
					// waits on a person, green for done, red for stopped.
					textMarkers: {
						markBackground: '#fb8a4b24',
						markBorderColor: '#fb8a4b',
						insBackground: '#6ccb8e1f',
						insBorderColor: '#6ccb8e',
						delBackground: '#f38b821f',
						delBorderColor: '#f38b82',
					},
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
			editLink: { baseUrl: 'https://github.com/wardrik-dev/wardrik_docs/edit/main/' },
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
								{
									label: 'Concepts',
									items: [
										'concepts/agents',
										'concepts/policy',
										'concepts/approvals',
										'concepts/outside-content',
										'concepts/budgets',
										'concepts/events',
										'concepts/files-and-memory',
									],
								},
								{
									label: 'Build',
									items: [
										'build/assistant',
										'build/mcp',
										'build/harnesses',
										'build/accounts',
										'build/vault',
										'build/slack',
										{
											label: 'Tools in your app',
											items: ['build/tool-workers', 'build/first-tool', 'build/write-tools', 'build/host-tools'],
										},
										'build/http-api',
										'build/listen',
										'build/triggers',
										'build/skills',
										'build/delegation',
										'build/notices',
									],
								},
								{ label: 'Run', items: [{ autogenerate: { directory: 'run' } }] },
							],
						},
						{
							label: 'Examples',
							link: '/examples/',
							items: [
								{ label: 'Overview', slug: 'examples' },
								// Each group fills itself from its folder, so adding an example is adding a file.
								{ label: 'Incident response', items: [{ autogenerate: { directory: 'examples/team' } }] },
								{ label: 'Team administration', items: [{ autogenerate: { directory: 'examples/enterprise' } }] },
								{ label: 'Support and bookkeeping', items: [{ autogenerate: { directory: 'examples/business' } }] },
								{ label: 'Personal automation', items: [{ autogenerate: { directory: 'examples/you' } }] },
								{ label: 'Test the guarantees', items: ['examples/pull-the-plug', 'examples/hijack-me'] },
							],
						},
						{
							id: 'reference',
							label: 'Reference',
							link: '/reference/cli/',
							items: [{ autogenerate: { directory: 'reference' } }, typeDocSidebarGroup],
						},
					],
					// The SDK reference's index pages are in no sidebar, but in this topic.
					{ exclude: ['/'], topics: { reference: ['/sdk/**'] } },
				),
				// The TypeScript SDK's reference, written from its doc comments on each
				// build. Its dependencies are not installed here, so types it imports
				// show by name, and TypeDoc does not check the program. Constructors the
				// client calls are @internal.
				starlightTypeDoc({
					entryPoints: ['../wardrik_typescript/src/index.ts'],
					tsconfig: '../wardrik_typescript/tsconfig.json',
					output: 'sdk/typescript',
					sidebar: { label: 'TypeScript SDK', collapsed: true },
					typeDoc: {
						name: 'TypeScript SDK',
						readme: '../wardrik_typescript/README.md',
						plugin: ['./typedoc-readme.mjs'],
						useCodeBlocks: true,
						parametersFormat: 'table',
						interfacePropertiesFormat: 'table',
						sort: ['source-order'],
						disableSources: true,
						skipErrorChecking: true,
						excludeExternals: true,
						excludeInternal: true,
					},
				}),
			],
		}),
	],
});
