import React from 'react';
import { BackHandler } from 'react-native';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react-native';
import { GestureHandlerRootView, State } from 'react-native-gesture-handler';
import { fireGestureHandler, getByGestureTestId } from 'react-native-gesture-handler/jest-utils';
import { err, ok } from '@synonymdev/result';
import PasskeyConsent from '../src/screens/PasskeyConsent';
import { approvePasskeyRequest, preparePasskeyRequest } from '../src/passkey/request';
import { cancelPasskeyRequest } from '../src/passkey/native';
import { getAutoAuthFromStore } from '../src/utils/store-helpers';
import { DeviceAuthError } from '../src/utils/deviceAuth';
import type { AuthCapability } from '../src/utils/authCapabilities';

const mockDispatch = jest.fn();
let mockAlwaysShowDetails = false;

jest.mock('immer', () => jest.requireActual('../node_modules/immer/dist/cjs/index.js'));
jest.mock('../src/passkey/request', () => ({
	preparePasskeyRequest: jest.fn(),
	approvePasskeyRequest: jest.fn(),
	PasskeyRequestRejection: class MockPasskeyRequestRejection extends Error {
		code: string;
		constructor(reason: string) {
			super(reason);
			this.code = reason;
		}
	},
}));
jest.mock('../src/passkey/native', () => ({ cancelPasskeyRequest: jest.fn(async () => true) }));
jest.mock('../src/utils/store-helpers.ts', () => ({ getAutoAuthFromStore: jest.fn(() => false) }));
jest.mock('../src/utils/deviceAuth', () => ({
	DeviceAuthError: class MockDeviceAuthError extends Error {
		code: string;
		constructor(errorCode: string) {
			super(errorCode);
			this.code = errorCode;
		}
	},
}));
jest.mock('react-redux', () => ({
	useDispatch: () => mockDispatch,
	useSelector: (selector: (state: unknown) => unknown) =>
		selector({ settings: { alwaysShowAuthDetails: mockAlwaysShowDetails } }),
}));
jest.mock('../src/store/selectors/pubkySelectors.ts', () => ({ getPubkyName: () => 'Test Pubky' }));
const mockT = (key: string, options?: Record<string, string>): string =>
	options ? `${key} ${JSON.stringify(options)}` : key;
jest.mock('react-i18next', () => ({ useTranslation: () => ({ t: mockT }) }));
jest.mock('styled-components/native', () => ({
	useTheme: () => ({ colors: { input: '#525252', blue: '#0085FF', background: '#000000' } }),
}));
jest.mock('react-native-reanimated', () => ({
	__esModule: true,
	default: { View: require('react-native').View, createAnimatedComponent: (component: unknown) => component },
	useSharedValue: (initialValue: unknown) =>
		require('react').useState(() => ({
			value: initialValue,
			get() {
				return this.value;
			},
			set(value: unknown) {
				this.value = value;
			},
		}))[0],
	useAnimatedStyle: () => ({}),
	withSpring: (value: number) => value,
	withTiming: (value: number, _config?: unknown, callback?: (finished: boolean) => void) => {
		callback?.(true);
		return value;
	},
	withSequence: (...values: number[]) => values.at(-1),
	isSharedValue: () => false,
	isWorkletFunction: () => false,
	useHandler: () => ({ context: {} }),
	useEvent: () => jest.fn(),
	useComposedEventHandler: () => undefined,
}));
jest.mock('react-native-worklets', () => ({
	scheduleOnRN: (callback: () => void) => callback(),
	scheduleOnUI: jest.fn(),
}));
jest.mock('@react-navigation/native', () => ({}));
jest.mock('react-native-safe-area-context', () => ({ useSafeAreaInsets: () => ({ top: 0, bottom: 0 }) }));
jest.mock('../src/sheets/sheetNavigation.tsx', () => ({ hideActiveSheet: jest.fn() }));
jest.mock('../src/components/AppHeader.tsx', () => ({ HEADER_HEIGHT: 56 }));
jest.mock('../src/components/LinearGradient.tsx', () => ({
	LinearGradient: require('react-native').View,
	RadialGradient: require('react-native').View,
}));
jest.mock('../src/theme/components.ts', () => ({
	ThemedView: require('react-native').View,
	ActivityIndicator: require('react-native').View,
}));
jest.mock('../src/components/Button.tsx', () => {
	const ReactMock = require('react');
	const { Pressable, Text } = require('react-native');
	return {
		__esModule: true,
		default: ({ text, ...props }: { text: string }) =>
			ReactMock.createElement(Pressable, props, ReactMock.createElement(Text, null, text)),
	};
});
jest.mock('../src/components/PermissionCard.tsx', () => ({
	__esModule: true,
	default: require('react-native').View,
}));
jest.mock('../src/components/AuthIdentity.tsx', () => ({
	__esModule: true,
	default: ({ fullWidth }: { fullWidth?: boolean }) =>
		require('react').createElement(require('react-native').View, {
			testID: fullWidth ? 'mock-auth-identity-full' : 'mock-auth-identity',
		}),
}));
jest.mock('../src/components/SafeAreaInset.tsx', () => ({ __esModule: true, default: () => null }));
jest.mock('../src/components/CircularProgressBar.tsx', () => ({
	__esModule: true,
	default: () => require('react').createElement(require('react-native').View, { testID: 'PasskeyTimer' }),
}));
jest.mock('../src/theme/typography', () => {
	const { Text } = require('react-native');
	return { TextBaseB: Text, TextBaseM: Text, TextSmM: Text, TextXsM: Text, TextLgSb: Text };
});
jest.mock('../src/icons/index.ts', () => ({
	ArrowLeft: () => null,
	CheckCircle: () => null,
	Folder: () => null,
	UserCheck: () => null,
	Eye: () => null,
	Pencil: () => null,
	Lock: () => null,
	Globe: () => null,
	List: () => null,
	Shield: () => null,
}));
jest.mock('../src/components/AuthSummary.tsx', () => ({
	__esModule: true,
	default: (props: unknown) =>
		require('react').createElement(require('react-native').View, {
			...(props as object),
			testID: 'mock-auth-summary',
		}),
}));
jest.mock('../src/components/SwipeToConfirm.tsx', () => ({
	__esModule: true,
	default: ({ onConfirm, loading, ...props }: { onConfirm: () => Promise<void>; loading: boolean }) =>
		require('react').createElement(require('react-native').Pressable, {
			...props,
			disabled: loading,
			onPress: onConfirm,
		}),
}));

const RELAY = 'https://httprelay.example.com/inbox';
const props = { requestId: 'request-1', rpId: 'pubky.app', envelope: 'E', pubky: 'z32-pubky' };

const prepared = (capabilities: AuthCapability[]) => ({
	requestId: 'request-1',
	rpId: 'pubky.app',
	pubky: 'z32-pubky',
	storeKey: 'pk:z32-pubky',
	envelope: { nonce: new Uint8Array(16), exp: 0, url: 'pubkyauth://signin_grant' },
	payload: {
		pubky: 'pk:z32-pubky',
		authUrl: 'pubkyauth://signin_grant',
		authDetails: { kind: 'signin_grant', client_id: 'pubky.app', relay: RELAY, capabilities },
	},
});

const renderConsent = async (
	capabilities: AuthCapability[] = [{ path: '/pub/pubky.app/', permission: 'rw' }],
) => {
	jest.mocked(preparePasskeyRequest).mockResolvedValue(ok(prepared(capabilities)) as never);
	render(
		<GestureHandlerRootView>
			<PasskeyConsent {...props} />
		</GestureHandlerRootView>,
	);
	await act(async () => {});
};

const drag = (translationY: number, velocityY = 0): void => {
	act(() => {
		fireGestureHandler(getByGestureTestId('SheetDragPan'), [
			{ state: State.BEGAN, translationY: 0 },
			{ state: State.ACTIVE, translationY: 12 },
			{ state: State.ACTIVE, translationY },
			{ state: State.END, translationY, velocityY },
		]);
	});
};

const swipe = async (): Promise<void> => {
	await act(async () => {
		fireEvent.press(screen.getByTestId('PasskeyConsentAuthorizeButton'));
	});
};

const hardwareBack = (): void => {
	const calls = jest.mocked(BackHandler.addEventListener).mock.calls;
	act(() => {
		calls[calls.length - 1][1]({ type: 'hardwareBackPress', timeStamp: 0 } as never);
	});
};

describe('PasskeyConsent', () => {
	beforeEach(() => {
		jest.useFakeTimers();
		jest.clearAllMocks();
		mockAlwaysShowDetails = false;
		jest.mocked(getAutoAuthFromStore).mockReturnValue(false);
		jest.spyOn(BackHandler, 'addEventListener').mockReturnValue({ remove: jest.fn() });
		jest.mocked(approvePasskeyRequest).mockResolvedValue(ok('success') as never);
	});

	afterEach(() => {
		cleanup();
		jest.clearAllTimers();
		jest.useRealTimers();
		jest.restoreAllMocks();
	});

	it('shows only the summary and identity in basics, like ConfirmAuth', async () => {
		await renderConsent();
		expect(screen.getByText('auth.authorize')).toBeTruthy();
		expect(screen.getByTestId('mock-auth-summary').props).toMatchObject({
			authorized: false,
			capabilities: [{ path: '/pub/pubky.app/', permission: 'rw' }],
		});
		expect(screen.getByTestId('mock-auth-identity')).toBeTruthy();
		expect(screen.getByTestId('PasskeyConsentShowDetailsButton')).toBeTruthy();
		expect(screen.getByTestId('PasskeyTimer')).toBeTruthy();
		expect(screen.queryByTestId('PasskeyConsentVerifiedSite')).toBeNull();
		expect(screen.queryByText('pubky.app')).toBeNull();
		expect(screen.queryByText('/pub/pubky.app/')).toBeNull();
		expect(screen.queryByText(RELAY)).toBeNull();
		expect(screen.queryByTestId('passkey-back-button')).toBeNull();
	});

	it('puts the verified site, folders and relay behind Show Details', async () => {
		await renderConsent();
		fireEvent.press(screen.getByTestId('PasskeyConsentShowDetailsButton'));
		const details = screen.getByTestId('PasskeyConsentDetailsScrollView');
		const site = within(details).getByTestId('PasskeyConsentVerifiedSite');
		expect(within(site).getByText('passkey.requestingSite')).toBeTruthy();
		expect(within(site).getByText('pubky.app')).toBeTruthy();
		expect(within(site).getByText('passkey.verifiedByBrowser')).toBeTruthy();
		expect(within(details).getByText('/pub/pubky.app/')).toBeTruthy();
		expect(within(within(details).getByTestId('PasskeyConsentRelay')).getByText(RELAY)).toBeTruthy();
		expect(within(details).getByText('auth.trustWarning')).toBeTruthy();
		expect(screen.getByTestId('mock-auth-identity-full')).toBeTruthy();
		expect(screen.queryByTestId('PasskeyConsentShowDetailsButton')).toBeNull();
		fireEvent.press(screen.getByTestId('passkey-back-button'));
		expect(screen.getByTestId('PasskeyConsentShowDetailsButton')).toBeTruthy();
		expect(cancelPasskeyRequest).not.toHaveBeenCalled();
	});

	it('opens details first when the Show Details preference is on', async () => {
		mockAlwaysShowDetails = true;
		await renderConsent();
		expect(screen.getByTestId('PasskeyConsentVerifiedSite')).toBeTruthy();
		expect(screen.queryByTestId('PasskeyConsentShowDetailsButton')).toBeNull();
	});

	it('returns from details on hardware back, then cancels from basics', async () => {
		await renderConsent();
		fireEvent.press(screen.getByTestId('PasskeyConsentShowDetailsButton'));
		hardwareBack();
		expect(screen.getByTestId('PasskeyConsentShowDetailsButton')).toBeTruthy();
		expect(cancelPasskeyRequest).not.toHaveBeenCalled();
		hardwareBack();
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'User cancelled');
	});

	it('has no Deny: dragging the sheet down cancels instead', async () => {
		await renderConsent();
		expect(screen.queryByText('auth.deny')).toBeNull();
		expect(screen.getByTestId('PasskeyConsentDetailsScrollView').type).toBe('View');
		drag(100);
		expect(cancelPasskeyRequest).not.toHaveBeenCalled();
		drag(400);
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'User cancelled');
	});

	it('cancels on a quick downward fling', async () => {
		await renderConsent();
		drag(60, 1500);
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'User cancelled');
	});

	it('scrolls the details first and closes only from the top', async () => {
		await renderConsent();
		fireEvent.press(screen.getByTestId('PasskeyConsentShowDetailsButton'));
		const details = screen.getByTestId('PasskeyConsentDetailsScrollView');
		expect(details.type).toBe('RCTScrollView');
		fireEvent.scroll(details, { nativeEvent: { contentOffset: { x: 0, y: 120 } } });
		drag(400);
		expect(cancelPasskeyRequest).not.toHaveBeenCalled();
		fireEvent.scroll(details, { nativeEvent: { contentOffset: { x: 0, y: 0 } } });
		drag(400);
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'User cancelled');
	});

	it('cancels when the backdrop is tapped', async () => {
		await renderConsent();
		fireEvent.press(screen.getByTestId('SheetBackdrop'));
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'User cancelled');
	});

	it('times out after 60 seconds without restarting when details open', async () => {
		await renderConsent();
		act(() => {
			jest.advanceTimersByTime(30000);
		});
		fireEvent.press(screen.getByTestId('PasskeyConsentShowDetailsButton'));
		act(() => {
			jest.advanceTimersByTime(30000);
		});
		expect(cancelPasskeyRequest).toHaveBeenCalledTimes(1);
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'Consent timed out');
	});

	it('hands the assertion back straight after the swipe, with no success state', async () => {
		let release!: () => void;
		jest.mocked(approvePasskeyRequest).mockImplementationOnce(
			() =>
				new Promise(resolve => {
					release = () => resolve(ok('success'));
				}),
		);
		await renderConsent();
		await swipe();
		expect(approvePasskeyRequest).toHaveBeenCalledWith(
			expect.objectContaining({ approvedCapabilities: undefined, dispatch: mockDispatch }),
		);
		expect(screen.getByTestId('PasskeyConsentAuthorizeButton')).toBeDisabled();
		expect(screen.queryByTestId('PasskeyTimer')).toBeNull();
		await act(async () => {
			release();
		});
		expect(screen.queryByText('auth.authorizedTitle')).toBeNull();
		expect(screen.queryByTestId('PasskeyConsentSuccessButton')).toBeNull();
		hardwareBack();
		expect(cancelPasskeyRequest).not.toHaveBeenCalled();
	});

	it('approves with the encryption choice from details', async () => {
		mockAlwaysShowDetails = true;
		await renderConsent([
			{ path: '/priv/chat/', permission: 'rwe' },
			{ path: '/pub/keys/', permission: 'e' },
		]);
		fireEvent.press(screen.getByTestId('AuthEncryptionToggle'));
		await swipe();
		expect(approvePasskeyRequest).toHaveBeenCalledWith(
			expect.objectContaining({ approvedCapabilities: '/priv/chat/:rw' }),
		);
	});

	it('returns to consent when device authentication is cancelled', async () => {
		jest.mocked(approvePasskeyRequest).mockResolvedValueOnce(err(new DeviceAuthError('cancelled')));
		await renderConsent();
		await swipe();
		expect(screen.getByTestId('PasskeyConsentAuthorizeButton')).not.toBeDisabled();
		expect(screen.getByTestId('PasskeyTimer')).toBeTruthy();
		expect(cancelPasskeyRequest).not.toHaveBeenCalled();
	});

	it('shows a refusal with Close for a rejected request', async () => {
		const { PasskeyRequestRejection } = jest.requireMock('../src/passkey/request');
		jest
			.mocked(preparePasskeyRequest)
			.mockResolvedValue(err(new PasskeyRequestRejection('client_id_mismatch')));
		render(
			<GestureHandlerRootView>
				<PasskeyConsent {...props} />
			</GestureHandlerRootView>,
		);
		await act(async () => {});
		expect(screen.getByText('passkey.errorTitle')).toBeTruthy();
		expect(
			within(screen.getByTestId('PasskeyConsentError')).getByText('passkey.errors.client_id_mismatch'),
		).toBeTruthy();
		fireEvent.press(screen.getByTestId('PasskeyConsentClose'));
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'passkey.errors.client_id_mismatch');
	});

	it('skips consent with Auto Auth, as scanning does', async () => {
		jest.mocked(getAutoAuthFromStore).mockReturnValue(true);
		await renderConsent();
		expect(approvePasskeyRequest).toHaveBeenCalledTimes(1);
		expect(screen.getByTestId('PasskeyConsentAuthorizeButton')).toBeDisabled();
		expect(cancelPasskeyRequest).not.toHaveBeenCalled();
	});
});
