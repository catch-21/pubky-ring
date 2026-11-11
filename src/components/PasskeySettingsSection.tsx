import React, { memo, ReactElement, useCallback, useEffect, useState } from 'react';
import { AppState, Platform, StyleSheet, View } from 'react-native';
import { useTranslation } from 'react-i18next';
import { TextBaseM, TextSmM, TextXsM } from '../theme/typography';
import Button from './Button.tsx';
import {
	getPasskeyProviderStatus,
	isPasskeyProviderPlatformSupported,
	openPasskeyProviderSettings,
	PasskeyProviderStatus,
} from '../passkey/native';

const PasskeySettingsSection = (): ReactElement | null => {
	const { t } = useTranslation();
	const [status, setStatus] = useState<PasskeyProviderStatus | null>(null);

	const refresh = useCallback(() => {
		getPasskeyProviderStatus().then(setStatus);
	}, []);

	useEffect(() => {
		refresh();
		const subscription = AppState.addEventListener('change', state => {
			if (state === 'active') refresh();
		});
		return () => subscription.remove();
	}, [refresh]);

	if (!isPasskeyProviderPlatformSupported() || !status?.supported) return null;

	const statusText =
		status.enabled === true
			? t('passkey.settings.enabled')
			: status.enabled === false
				? t('passkey.settings.disabled')
				: t(Platform.OS === 'android' ? 'passkey.settings.androidHint' : 'passkey.settings.iosHint');

	return (
		<View testID="PasskeySettingsSection">
			<View style={styles.textSection}>
				<TextXsM>{t('passkey.settings.title')}</TextXsM>
				<TextBaseM style={styles.description}>{t('passkey.settings.description')}</TextBaseM>
				<TextSmM style={styles.description}>{statusText}</TextSmM>
				{Platform.OS === 'ios' && !status.prfSupported && (
					<TextSmM style={styles.description}>{t('passkey.settings.iosPrfMissing')}</TextSmM>
				)}
			</View>
			<Button
				text={t('passkey.settings.open')}
				variant="dark"
				testID="PasskeyProviderSettingsButton"
				onPress={() => openPasskeyProviderSettings().then(refresh)}
			/>
		</View>
	);
};

const styles = StyleSheet.create({
	textSection: { marginBottom: 24 },
	description: { marginTop: 10 },
});

export default memo(PasskeySettingsSection);
