// Weights approximate each stage's share of build time on production data, where
// the movement history scan dominates. Counts reported inside a stage are exact.
const stages = [
	['starting', 'Starting the pack builder', 0.01],
	['opening', 'Opening the fleet database', 0.02],
	['selecting', 'Selecting matching and linked cars', 0.07],
	['cars', 'Writing car records', 0.04],
	['assertions', 'Writing source records', 0.04],
	['history', 'Scanning movement history', 0.72],
	['consists', 'Writing train formations', 0.07],
	['finishing', 'Compressing and checksumming the pack', 0.03],
];

export function packProgress(stage, done = 0, total = 0) {
	const index = stages.findIndex(([id]) => id === stage);
	if (index < 0) throw new Error(`Unknown fleet pack stage: ${stage}`);
	const before = stages.slice(0, index).reduce((sum, [, , weight]) => sum + weight, 0);
	const part = total > 0 ? Math.min(1, done / total) : 0;
	const fraction = Math.min(1, before + stages[index][2] * part);
	return { stage, label: stages[index][1], step: index + 1, steps: stages.length, done, total, fraction: Math.floor(fraction * 10_000) / 10_000 };
}
