import { useEffect } from 'react';
import { shallowEqual, useSelector } from 'react-redux';
import type { RootState } from '../store';
import { getAuthorizablePubkys, getPubkyName } from '../store/selectors/pubkySelectors';
import {
	getAlwaysShowAuthDetails,
	getAutoAuth,
	getRequireDeviceAuth,
} from '../store/selectors/settingsSelectors';
import { buildPasskeySnapshot } from './snapshot';
import { writePasskeySnapshot } from './native';

/** Keeps the native passkey providers' non-secret snapshot in step with the store. */
export const usePasskeySnapshotSync = (): void => {
	const pubkys = useSelector(getAuthorizablePubkys);
	const autoAuth = useSelector(getAutoAuth);
	const requireDeviceAuth = useSelector(getRequireDeviceAuth);
	const alwaysShowAuthDetails = useSelector(getAlwaysShowAuthDetails);
	const displayNames = useSelector(
		(state: RootState) => Object.fromEntries(Object.keys(pubkys).map(key => [key, getPubkyName(state, key)])),
		shallowEqual,
	);

	useEffect(() => {
		writePasskeySnapshot(
			JSON.stringify(
				buildPasskeySnapshot({ pubkys, autoAuth, requireDeviceAuth, alwaysShowAuthDetails, displayNames }),
			),
		).then();
	}, [alwaysShowAuthDetails, autoAuth, displayNames, pubkys, requireDeviceAuth]);
};
