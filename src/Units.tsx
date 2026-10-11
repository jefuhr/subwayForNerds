import { useSyncExternalStore } from 'react';
import type { UnitSettings } from '../shared/settings';
import { getDeviceSettings, subscribeSettings, updateSettings } from './settings-store';

export const useUnits = () => useSyncExternalStore(subscribeSettings, getDeviceSettings).settings.units;

export function UnitSettingsPanel() {
	const units = useUnits();
	return <section><h3>Units and time</h3>
		<label className="settings-choice">Distance units<select aria-label="Distance units" value={units.distance} onChange={e => updateSettings(s => ({ ...s, units: { ...s.units, distance: e.target.value as UnitSettings['distance'] } }))}>
			<option value="auto">Automatic</option><option value="mi">Miles (mi)</option><option value="ft">Feet (ft)</option><option value="m">Meters (m)</option><option value="km">Kilometers (km)</option>
		</select></label>
		<label className="settings-choice">Time format<select aria-label="Time format" value={units.time} onChange={e => updateSettings(s => ({ ...s, units: { ...s.units, time: e.target.value as UnitSettings['time'] } }))}>
			<option value="12h">12-hour</option><option value="24h">24-hour</option>
		</select></label>
		<p className="fine-print">Automatic uses meters or kilometers nearby and feet for the favorite radius. Times stay in New York time. These choices also apply to your iPhone widgets.</p>
	</section>;
}
