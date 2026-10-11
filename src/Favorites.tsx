import { useEffect, useState, useSyncExternalStore } from 'react';
import { Star } from 'lucide-react';
import { consistKey } from '../shared/favorites';
import { validFleetCarID, type StationSelection, type TrainFavorites } from '../shared/settings';
import { getDeviceSettings, subscribeSettings, updateSettings } from './settings-store';

export const carLabel = (id: string) => { const [system, type, number] = id.split(':'); return `${type} ${number}${system === 'sir' ? ' · SIR' : ''}`; };
export const useTrainFavorites = () => useSyncExternalStore(subscribeSettings, getDeviceSettings).settings.trainFavorites;
export function FavoriteCarButton({ id }: { id: string }) {
	const saved = useTrainFavorites().cars.includes(id);
	if (!validFleetCarID(id)) return null;
	return <button className="favorite-train-button" aria-label={`Favorite car ${carLabel(id)}`} aria-pressed={saved} onClick={() => updateSettings(s => ({ ...s, trainFavorites: { ...s.trainFavorites, cars: s.trainFavorites.cars.includes(id) ? s.trainFavorites.cars.filter(car => car !== id) : [...s.trainFavorites.cars, id] } }))}>
		<Star size={18} fill={saved ? 'currentColor' : 'none'} aria-hidden="true" />
	</button>;
}
export function FavoriteConsistButton({ ids, compact = false }: { ids: string[]; compact?: boolean }) {
	const favorites = useTrainFavorites();
	const key = consistKey(ids), saved = favorites.consists.some(group => consistKey(group) === key);
	if (!ids.length || ids.length > 20 || new Set(ids).size !== ids.length || !ids.every(validFleetCarID)) return null;
	return <button className="favorite-train-button" aria-label={`Favorite consist, ${ids.length} cars`} aria-pressed={saved} onClick={() => updateSettings(s => ({ ...s, trainFavorites: { ...s.trainFavorites, consists: s.trainFavorites.consists.some(group => consistKey(group) === key) ? s.trainFavorites.consists.filter(group => consistKey(group) !== key) : [...s.trainFavorites.consists, [...ids].sort()] } }))}>
		<Star size={18} fill={saved ? 'currentColor' : 'none'} aria-hidden="true" />{!compact && <span>Favorite consist</span>}
	</button>;
}

function StationChoice({ selection, change, prefix }: { selection: StationSelection; change: (value: StationSelection) => void; prefix: 'App' | 'Widget' }) {
	const [radius, setRadius] = useState(String(selection.radiusFeet));
	useEffect(() => setRadius(String(selection.radiusFeet)), [selection.radiusFeet]);
	const valid = /^\d+$/.test(radius) && Number(radius) >= 1 && Number(radius) <= 26400;
	const commitRadius = () => {
		if (valid && Number(radius) !== selection.radiusFeet) change({ ...selection, radiusFeet: Number(radius) });
		else if (!valid) setRadius(String(selection.radiusFeet));
	};
	return <div className="station-choice">
		<label>{prefix} station selection<select aria-label={`${prefix} station selection`} value={selection.mode} onChange={e => change({ ...selection, mode: e.target.value as StationSelection['mode'] })}>
			<option value="favorite">Closest favorite</option><option value="closest">Closest station</option><option value="nearbyFavorite">Favorite within radius</option>
		</select></label>
		{selection.mode === 'nearbyFavorite' && <>
			<label>Radius (ft)<input type="number" min={1} max={26400} step={1} inputMode="numeric" aria-label={`${prefix} radius in feet`} aria-invalid={!valid} value={radius} onBlur={commitRadius} onKeyDown={e => { if (e.key === 'Enter') commitRadius(); }} onChange={e => setRadius(e.target.value)} /></label>
			<input type="range" min={1} max={26400} step={1} aria-label={`${prefix} favorite radius`} aria-valuetext={`${valid ? radius : selection.radiusFeet} feet`} value={valid ? Number(radius) : selection.radiusFeet} onChange={e => setRadius(e.target.value)} onPointerUp={commitRadius} onKeyUp={commitRadius} onBlur={commitRadius} />
			<p className="fine-print">{Number(valid ? radius : selection.radiusFeet).toLocaleString()} ft · {Number((Number(valid ? radius : selection.radiusFeet) / 5280).toFixed(4))} mi</p>
			{!valid && <p className="notice">Enter a whole number from 1 to 26,400 feet.</p>}
			<p className="fine-print">Choose the closest favorite only inside this radius. At or beyond it, show the closest station. Distance is straight-line distance, not walking distance.</p>
		</>}
	</div>;
}
export function FavoriteSettings({ openFleet }: { openFleet: (id: string) => void }) {
	const settings = useSyncExternalStore(subscribeSettings, getDeviceSettings).settings;
	const favorites = settings.trainFavorites;
	const [removed, setRemoved] = useState<{ car?: string; consist?: string[] }>();
	const remove = (item: { car?: string; consist?: string[] }) => {
		updateSettings(s => ({ ...s, trainFavorites: { ...s.trainFavorites,
			cars: item.car ? s.trainFavorites.cars.filter(id => id !== item.car) : s.trainFavorites.cars,
			consists: item.consist ? s.trainFavorites.consists.filter(ids => consistKey(ids) !== consistKey(item.consist!)) : s.trainFavorites.consists,
		} })); if (!getDeviceSettings().error) setRemoved(item);
	};
	const undo = () => {
		if (!removed) return;
		updateSettings(s => ({ ...s, trainFavorites: { ...s.trainFavorites,
			cars: removed.car && !s.trainFavorites.cars.includes(removed.car) ? [...s.trainFavorites.cars, removed.car] : s.trainFavorites.cars,
			consists: removed.consist && !s.trainFavorites.consists.some(ids => consistKey(ids) === consistKey(removed.consist!)) ? [...s.trainFavorites.consists, removed.consist] : s.trainFavorites.consists,
		} })); if (!getDeviceSettings().error) setRemoved(undefined);
	};
	return <>
		<section><h3>Station selection</h3><StationChoice selection={settings.stationSelection} prefix="App" change={stationSelection => updateSettings(s => ({ ...s, stationSelection }))} />
			<p className="fine-print">Uses your location on a fresh visit. Choosing a station yourself always takes priority. If location is unavailable, your saved station stays open.</p>
		</section>
		<section><h3>iPhone widget station</h3><p className="fine-print">These choices transfer to the iOS app through your settings file or account.</p>
			<label className="settings-toggle"><input type="checkbox" checked={settings.widgets.stationSelection.followApp} onChange={e => updateSettings(s => ({ ...s, widgets: { ...s.widgets, stationSelection: { ...s.widgets.stationSelection, followApp: e.target.checked } } }))} />Follow app station selection</label>
			{settings.widgets.stationSelection.followApp ? <p className="fine-print">Home and Lock Screen widgets use the app’s station selection. Your separate widget choice is kept.</p> : <StationChoice prefix="Widget" selection={settings.widgets.stationSelection.selection} change={selection => updateSettings(s => ({ ...s, widgets: { ...s.widgets, stationSelection: { ...s.widgets.stationSelection, selection } } }))} />}
		</section>
		<section><h3>Favorite trains</h3>{removed && <div className="settings-undo" role="status">Favorite removed <button className="text-button" aria-label="Undo removal" onClick={undo}>Undo</button></div>}
			<label className="settings-choice">Match saved consists<select value={favorites.match} onChange={e => updateSettings(s => ({ ...s, trainFavorites: { ...s.trainFavorites, match: e.target.value as TrainFavorites['match'] } }))}>
				<option value="exact">Exact consist</option><option value="anyCar">Any member car</option>
			</select></label>
			<p className="fine-print">Exact consist requires every saved car, in any order. Any member car matches a train containing at least one car from a saved consist. Individually saved cars always match. Changing this keeps all your favorites.</p>
			<h4>Cars</h4>{favorites.cars.length ? <ul className="saved-trains">{favorites.cars.map(id => <li key={id}><button className="text-button" onClick={() => openFleet(id)}>{carLabel(id)}</button><button className="favorite-train-button" aria-label={`Remove favorite car ${carLabel(id)}`} onClick={() => remove({ car: id })}><Star size={18} fill="currentColor" aria-hidden="true" /></button></li>)}</ul> : <p className="fine-print">Star a car in train or fleet details.</p>}
			<h4>Consists</h4>{favorites.consists.length ? <ul className="saved-trains">{favorites.consists.map(ids => <li key={consistKey(ids)}><span><strong>{ids.length} cars</strong><small>{ids.map(carLabel).join(' · ')}</small></span><button className="favorite-train-button" aria-label={`Remove favorite consist, ${ids.length} cars`} onClick={() => remove({ consist: ids })}><Star size={18} fill="currentColor" aria-hidden="true" /></button></li>)}</ul> : <p className="fine-print">Star a whole consist in train or fleet details.</p>}
		</section>
	</>;
}
