import React, { ReactElement, useMemo } from 'react';
import { useColorScheme } from 'react-native';
import { Provider, useSelector } from 'react-redux';
import { PersistGate } from 'redux-persist/integration/react';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { ThemeProvider } from 'styled-components/native';
import { store, persistor } from '../store';
import { darkTheme, lightTheme } from '../theme';
import { ETheme } from '../types/settings.ts';
import { getTheme } from '../store/selectors/settingsSelectors.ts';
import SafeAreaView from '../components/SafeAreaView.tsx';
import PasskeyConsent from '../screens/PasskeyConsent.tsx';
import type { PasskeyRequestProps } from './request';
import '../i18n';
import '../theme/toast';

/** Name of the React Native surface the Android PasskeyConsentActivity hosts. */
export const PASSKEY_CONSENT_COMPONENT = 'PubkyPasskeyConsent';

const rootStyle = { flex: 1 } as const;

const ThemedConsent = (props: PasskeyRequestProps): ReactElement => {
	const colorScheme = useColorScheme();
	const currentTheme = useSelector(getTheme);
	const theme = useMemo(() => {
		if (currentTheme === ETheme.light) return lightTheme;
		if (currentTheme === ETheme.system && colorScheme !== 'dark') return lightTheme;
		return darkTheme;
	}, [colorScheme, currentTheme]);

	return (
		<ThemeProvider theme={theme}>
			<SafeAreaProvider>
				<SafeAreaView edges={['top', 'bottom', 'left', 'right']}>
					<PasskeyConsent {...props} />
				</SafeAreaView>
			</SafeAreaProvider>
		</ThemeProvider>
	);
};

const PasskeyConsentRoot = (props: PasskeyRequestProps): ReactElement => (
	<Provider store={store}>
		<PersistGate loading={null} persistor={persistor}>
			<GestureHandlerRootView style={rootStyle}>
				<ThemedConsent {...props} />
			</GestureHandlerRootView>
		</PersistGate>
	</Provider>
);

export default PasskeyConsentRoot;
