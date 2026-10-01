-- Teal type-check config. Requires the `tl` compiler on PATH (not installed
-- yet on this machine); until then the game itself is the type checker, since
-- it compiles .tl at load time and reports failures to the log.
return {
	include_dir = {
		"C:/Program Files (x86)/Steam/steamapps/common/Transport Fever 3/api/tealdef",
		"C:/Program Files (x86)/Steam/steamapps/common/Transport Fever 3/base/tealdef",
		"mod/town_clustering_1/content",
	},
	global_env_def = "all_def"
}
