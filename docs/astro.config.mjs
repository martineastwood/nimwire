// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeNext from 'starlight-theme-next';

export default defineConfig({
	site: 'https://nimwire.niminal.dev',
	integrations: [
		starlight({
			title: 'nimwire',
			description: 'Build Model Context Protocol servers in Nim with typed tools, resources, prompts, transports, and production controls.',
			customCss: ['./src/styles/sidebar.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martineastwood/nimwire' }],
			sidebar: [
				{ label: 'Introduction', slug: 'introduction' },
				{ label: 'Quickstart', slug: 'guides/quickstart' },
				{
					label: 'Guides',
					collapsed: false,
					items: [
						{ label: 'Server basics', slug: 'guides/server-basics' },
						{ label: 'Typed tools', slug: 'guides/tools' },
						{ label: 'Resources', slug: 'guides/resources' },
						{ label: 'Prompts', slug: 'guides/prompts' },
						{ label: 'Transports', slug: 'guides/transports' },
						{ label: 'Request context', slug: 'guides/context' },
						{ label: 'Security', slug: 'guides/security' },
						{ label: 'Production controls', slug: 'guides/production' },
						{ label: 'Composition', slug: 'guides/composition' },
						{ label: 'Tasks', slug: 'guides/tasks' },
						{ label: 'Extensions', slug: 'guides/extensions' },
						{ label: 'Subscriptions', slug: 'guides/subscriptions' },
						{ label: 'Testing', slug: 'guides/testing' },
					],
				},
				{
					label: 'API reference',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'reference/core-api' },
						{ autogenerate: { directory: 'reference/api' } },
					],
				},
				{
					label: 'Examples',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'examples' },
						{ label: 'Echo server', slug: 'examples/echo-server' },
						{ label: 'HTTP server', slug: 'examples/http-server' },
						{ label: 'Prompts server', slug: 'examples/prompts-server' },
						{ label: 'Resources server', slug: 'examples/resources-server' },
						{ label: 'Auth server', slug: 'examples/auth-server' },
					],
				},
			],
			plugins: [starlightThemeNext()],
		}),
	],
});
