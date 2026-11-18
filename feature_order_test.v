module vtext

import vtext.shape

// Feature order as data (Phase 11 E2): one plan per script carries the
// before-ccmp slot beside the defaults, so the pipeline fetches data
// instead of branching per script. Every list below was read off the
// shaper each script landed with; agreement with the landing pins is
// the evidence. Order is load-bearing: each assert compares the whole
// list, so a reordered implementation fails here first (break-fix:
// sorting any list alphabetically fails its test).
fn test_feature_plan_khmer() {
	plan := shape.feature_plan_for('khmr', [])
	assert plan.pre_ccmp == []
	assert plan.defaults == ['pref', 'blwf', 'pstf', 'pres', 'abvs', 'blws', 'psts', 'abvf']
}

fn test_feature_plan_myanmar() {
	plan := shape.feature_plan_for('mymr', [])
	assert plan.pre_ccmp == []
	assert plan.defaults == ['abvs', 'blws']
}

fn test_feature_plan_myanmar_asked_blwf_runs_pre_ccmp() {
	plan := shape.feature_plan_for('mymr', ['blwf'])
	assert plan.pre_ccmp == ['blwf']
	assert plan.defaults == ['abvs', 'blws']
	plus := shape.feature_plan_for('mymr', ['+blwf'])
	assert plus.pre_ccmp == ['blwf']
	neg := shape.feature_plan_for('mymr', ['-blwf'])
	assert neg.pre_ccmp == []
}

fn test_feature_plan_indic() {
	plan := shape.feature_plan_for('deva', [])
	assert plan.pre_ccmp == []
	assert plan.defaults == ['nukt', 'akhn', 'rphf', 'half', 'blwf', 'pstf', 'vatu', 'cjct', 'pres',
		'abvs', 'blws', 'psts']
	beng := shape.feature_plan_for('bng2', [])
	assert beng.pre_ccmp == []
	assert beng.defaults == plan.defaults
}

fn test_feature_plan_unregistered_is_empty() {
	plan := shape.feature_plan_for('latn', ['blwf'])
	assert plan.pre_ccmp == []
	assert plan.defaults == []
}
