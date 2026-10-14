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
								{
									label: 'Concepts',
									items: [
										{
											label: 'Agents',
											items: [
												'concepts/agents',
												'concepts/turns',
												'concepts/agent-lifecycle',
												'concepts/durable-runs',
											],
										},
										{
											label: 'Policy',
											items: [
												'concepts/policy',
												'concepts/rules',
												'concepts/approvals',
												'concepts/outside-content',
												'concepts/budgets',
												'concepts/judges',
											],
										},
										'concepts/events',
										'concepts/files-and-memory',
									],
								},
								{
									label: 'Build',
									items: [
										'build/front-door',
										'build/mcp',
										'build/accounts',
										'build/vault',
										{
											label: 'Tools in your app',
											items: ['build/tool-workers', 'build/first-tool', 'build/write-tools', 'build/host-tools'],
										},
										'build/http-api',
										'build/triggers',
										'build/delegation',
										'build/notices',
										'build/tui',
									],
								},
								{ label: 'Channels', items: [{ autogenerate: { directory: 'channels' } }] },
								{ label: 'Run', items: [{ autogenerate: { directory: 'run' } }] },
							],
						},
						{
							label: 'Examples',
							link: '/examples/',
							items: [
								{ label: 'Overview', slug: 'examples' },
								// Each group fills itself from its folder, so adding an example is adding a file.
								{ label: 'For a team', items: [{ autogenerate: { directory: 'examples/team' } }] },
								{ label: 'For an enterprise', items: [{ autogenerate: { directory: 'examples/enterprise' } }] },
								{ label: 'For a business', items: [{ autogenerate: { directory: 'examples/business' } }] },
								{ label: 'For you', items: [{ autogenerate: { directory: 'examples/you' } }] },
								{ label: 'Try to break it', items: ['examples/pull-the-plug', 'examples/hijack-me'] },
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
					entryPoints: ['../sdks/typescript/src/index.ts'],
					tsconfig: '../sdks/typescript/tsconfig.json',
					output: 'sdk/typescript',
					sidebar: { label: 'TypeScript SDK', collapsed: true },
					typeDoc: {
						name: 'TypeScript SDK',
						readme: '../sdks/typescript/README.md',
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
