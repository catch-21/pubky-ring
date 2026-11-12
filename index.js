import { AppRegistry } from 'react-native';
import Root from './Root';
import PasskeyConsentRoot, { PASSKEY_CONSENT_COMPONENT } from './src/passkey/PasskeyConsentRoot';
import { name as appName } from './app.json';

AppRegistry.registerComponent(appName, () => Root);
AppRegistry.registerComponent(PASSKEY_CONSENT_COMPONENT, () => PasskeyConsentRoot);
