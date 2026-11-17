module main

import vtext.providers

fn test_discovery_order_env_first() {
	got := providers.discovery_order(providers.DiscoveryInput{
		env_font:     '/e/a.ttf'
		user_fonts:   ['/u/b.ttf']
		system_fonts: ['/s/c.ttf']
		bundled:      ['/b/d.ttf']
	})
	assert got == ['/e/a.ttf', '/u/b.ttf', '/s/c.ttf', '/b/d.ttf']
}

fn test_pick_first_skips_unreadable() {
	got := providers.pick_first(['/no/a.ttf', '/yes/b.ttf'], fn (p string) bool {
		return p == '/yes/b.ttf'
	})
	assert got == '/yes/b.ttf'
	assert providers.pick_first([]string{}, fn (p string) bool {
		return true
	}) == ''
}

fn test_variant_path_rules() {
	assert providers.variant_path('/f/Noto-Regular.ttf', .bold) == '/f/Noto-Bold.ttf'
	assert providers.variant_path('/f/Noto-Regular.ttf', .italic) == '/f/Noto-Italic.ttf'
	assert providers.variant_path('/f/Noto-Regular.ttf', .mono) == '/f/NotoMono-Regular.ttf'
	assert providers.variant_path('/f/a.ttf', .normal) == '/f/a.ttf'
	assert providers.is_power_of_two(2048)
	assert !providers.is_power_of_two(1000)
}
