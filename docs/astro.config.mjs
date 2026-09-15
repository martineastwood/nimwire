// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeNext from 'starlight-theme-next';

export default defineConfig({
	site: 'https://nimwire.niminal.dev',
	integrations: [
		starlight({
			title: 'nimwire',
			description: 'Build MCP servers and backends in Nim.',
			customCss: ['./src/styles/sidebar.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martineastwood/nimwire' }],
			sidebar: [
				{ label: 'Introduction', slug: 'index' },
				{
					label: 'API reference',
					collapsed: true,
					items: [{ autogenerate: { directory: 'reference/api' } }],
				},
			],
			plugins: [starlightThemeNext()],
		}),
	],
});
