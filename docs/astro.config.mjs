// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeBlack from 'starlight-theme-black';

export default defineConfig({
	site: 'https://nimwire.niminal.dev',
	integrations: [
		starlight({
			title: 'nimwire',
			description: 'Build MCP servers and backends in Nim.',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martineastwood/nimwire' }],
			plugins: [
				starlightThemeBlack({
					navLinks: [{ label: 'Niminal', link: 'https://niminal.dev' }],
					docs: { showMarkdownActions: false },
				}),
			],
		}),
	],
});
