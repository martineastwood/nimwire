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
			favicon: '/favicon.ico',
			head: [
				{ tag: 'link', attrs: { rel: 'icon', href: '/favicon.ico', sizes: '48x48' } },
				{ tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '32x32', href: '/favicon-32x32.png' } },
				{ tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '16x16', href: '/favicon-16x16.png' } },
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', sizes: '180x180', href: '/apple-touch-icon.png' } },
			],
			customCss: ['./src/styles/sidebar.css', './src/styles/landing.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martineastwood/nimwire' }],
			sidebar: [
				{ label: 'Introduction', slug: 'introduction' },
				{ label: 'Quickstart', slug: 'guides/quickstart' },
				{ label: 'Server basics', slug: 'guides/server-basics' },
				{ label: 'Typed tools', slug: 'guides/tools' },
				{ label: 'Resources', slug: 'guides/resources' },
				{ label: 'Prompts', slug: 'guides/prompts' },
				{ label: 'Completion', slug: 'guides/completion' },
				{ label: 'Transports', slug: 'guides/transports' },
				{ label: 'Request context', slug: 'guides/context' },
				{ label: 'Multi-round-trip input', slug: 'guides/mrtr' },
				{ label: 'Security', slug: 'guides/security' },
				{ label: 'Production controls', slug: 'guides/production' },
				{ label: 'Composition', slug: 'guides/composition' },
				{ label: 'Tasks', slug: 'guides/tasks' },
				{ label: 'Extensions', slug: 'guides/extensions' },
				{ label: 'Subscriptions', slug: 'guides/subscriptions' },
				{ label: 'Testing', slug: 'guides/testing' },
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
						{ label: 'WebSocket server', slug: 'examples/websocket-server' },
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
