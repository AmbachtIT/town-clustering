-- Registers the clustering game script. Game scripts are the one place our code
-- reliably runs: mod content is loaded when a game session initialises, which
-- is also when the towns exist as entities.
function data()
	return {
		updateScript = {
			fileName = "town_clustering_1::/town_clustering.script@update",
		},
	}
end
