import React, { ReactElement } from 'react';
import { Provider } from 'react-redux';
import { PersistGate } from 'redux-persist/integration/react';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { ThemeProvider } from 'styled-components/native';
import { store, persistor } from '../store';
import { darkTheme } from '../theme';
import PasskeyConsent from '../screens/PasskeyConsent.tsx';
import type { PasskeyRequestProps } from './request';
import '../i18n';
import '../theme/toast';

/** Name of the React Native surface the Android PasskeyConsentActivity hosts. */
export const PASSKEY_CONSENT_COMPONENT = 'PubkyPasskeyConsent';

const rootStyle = { flex: 1 } as const;

// Ring's sheets are dark only, whatever the system or theme setting says.
const PasskeyConsentRoot = (props: PasskeyRequestProps): ReactElement => (
	<Provider store={store}>
		<PersistGate loading={null} persistor={persistor}>
			<GestureHandlerRootView style={rootStyle}>
				<ThemeProvider theme={darkTheme}>
					<SafeAreaProvider>
						<PasskeyConsent {...props} />
					</SafeAreaProvider>
				</ThemeProvider>
			</GestureHandlerRootView>
		</PersistGate>
	</Provider>
);

export default PasskeyConsentRoot;
