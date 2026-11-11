import { useEffect } from 'react';
import { useSelector } from 'react-redux';
import { getAuthorizablePubkys } from '../store/selectors/pubkySelectors';
import { getAutoAuth, getRequireDeviceAuth } from '../store/selectors/settingsSelectors';
import { buildPasskeySnapshot } from './snapshot';
import { writePasskeySnapshot } from './native';

/** Keeps the native passkey providers' non-secret snapshot in step with the store. */
export const usePasskeySnapshotSync = (): void => {
	const pubkys = useSelector(getAuthorizablePubkys);
	const autoAuth = useSelector(getAutoAuth);
	const requireDeviceAuth = useSelector(getRequireDeviceAuth);

	useEffect(() => {
		writePasskeySnapshot(JSON.stringify(buildPasskeySnapshot({ pubkys, autoAuth, requireDeviceAuth }))).then();
	}, [autoAuth, pubkys, requireDeviceAuth]);
};
