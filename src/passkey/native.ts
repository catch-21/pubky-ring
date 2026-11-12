import { NativeModules, Platform } from 'react-native';
import {
	ANDROID_PASSKEY_PROVIDER_MIN_API,
	IOS_PASSKEY_PRF_MIN_VERSION,
	IOS_PASSKEY_PROVIDER_MIN_VERSION,
} from './config';

export interface PasskeyProviderStatus {
	/** The OS can load Ring as a passkey provider. */
	supported: boolean;
	/** Whether the user has turned Ring on as a passkey provider. Null when the OS cannot say. */
	enabled: boolean | null;
	/** iOS only: whether the OS passes PRF inputs to providers (needed for the mailbox route). */
	prfSupported: boolean;
}

interface PubkyPasskeyNativeModule {
	writeSnapshot: (json: string) => Promise<boolean>;
	getProviderStatus: () => Promise<PasskeyProviderStatus>;
	openProviderSettings: () => Promise<boolean>;
	completeRequest: (requestId: string, pubky: string, userVerified: boolean) => Promise<boolean>;
	cancelRequest: (requestId: string, message: string, refused: boolean) => Promise<boolean>;
}

const nativeModule = NativeModules.PubkyPasskey as PubkyPasskeyNativeModule | undefined;

const osMajorVersion = (): number => {
	const version = Platform.Version;
	return typeof version === 'number' ? version : parseInt(String(version), 10) || 0;
};

/** Only the passkey feature is gated; the rest of Ring keeps its own deployment targets (decision 1). */
export const isPasskeyProviderPlatformSupported = (): boolean => {
	if (!nativeModule) return false;
	if (Platform.OS === 'ios') return osMajorVersion() >= IOS_PASSKEY_PROVIDER_MIN_VERSION;
	if (Platform.OS === 'android') return osMajorVersion() >= ANDROID_PASSKEY_PROVIDER_MIN_API;
	return false;
};

export const isPasskeyPrfPlatformSupported = (): boolean =>
	Platform.OS === 'ios' ? osMajorVersion() >= IOS_PASSKEY_PRF_MIN_VERSION : isPasskeyProviderPlatformSupported();

export const writePasskeySnapshot = async (json: string): Promise<boolean> => {
	if (!nativeModule || !isPasskeyProviderPlatformSupported()) return false;
	try {
		return await nativeModule.writeSnapshot(json);
	} catch (e) {
		console.warn('Failed to write passkey snapshot', e);
		return false;
	}
};

export const getPasskeyProviderStatus = async (): Promise<PasskeyProviderStatus> => {
	if (!nativeModule || !isPasskeyProviderPlatformSupported()) {
		return { supported: false, enabled: null, prfSupported: false };
	}
	try {
		return await nativeModule.getProviderStatus();
	} catch {
		return { supported: false, enabled: null, prfSupported: false };
	}
};

export const openPasskeyProviderSettings = async (): Promise<boolean> => {
	if (!nativeModule) return false;
	try {
		return await nativeModule.openProviderSettings();
	} catch {
		return false;
	}
};

export const completePasskeyRequest = async ({
	requestId,
	pubky,
	userVerified,
}: {
	requestId: string;
	pubky: string;
	userVerified: boolean;
}): Promise<boolean> => (nativeModule ? nativeModule.completeRequest(requestId, pubky, userVerified) : false);

/** A refusal ends the request as a failure (NotReadableError in Chrome), otherwise as a cancellation (NotAllowedError). */
export const cancelPasskeyRequest = async (
	requestId: string,
	message: string,
	{ refused = false }: { refused?: boolean } = {},
): Promise<boolean> => {
	if (!nativeModule) return false;
	try {
		return await nativeModule.cancelRequest(requestId, message, refused);
	} catch {
		return false;
	}
};
