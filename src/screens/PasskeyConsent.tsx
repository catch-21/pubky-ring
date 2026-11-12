import React, { memo, ReactElement, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackHandler, StyleSheet, View } from 'react-native';
import { useDispatch, useSelector } from 'react-redux';
import { useTranslation } from 'react-i18next';
import type { RootState } from '../store';
import { ActivityIndicator } from '../theme/components.ts';
import { TextBaseM, TextSmM, TextXsM } from '../theme/typography';
import { getPubkyName } from '../store/selectors/pubkySelectors.ts';
import { getAlwaysShowAuthDetails } from '../store/selectors/settingsSelectors.ts';
import { getAutoAuthFromStore } from '../utils/store-helpers.ts';
import { DeviceAuthError } from '../utils/deviceAuth';
import { buildApprovedCapabilities, hasEncryptionCapabilities } from '../utils/authCapabilities.ts';
import Button from '../components/Button.tsx';
import PermissionCard from '../components/PermissionCard.tsx';
import CircularProgressBar from '../components/CircularProgressBar.tsx';
import SafeAreaInset from '../components/SafeAreaInset.tsx';
import { SheetCard, SheetLayout } from '../components/Sheet.tsx';
import AuthRequestContent, {
	AUTH_SUCCESS_FADE_DURATION,
	authRequestStyles,
} from '../components/AuthRequestContent.tsx';
import { Globe, Shield } from '../icons/index.ts';
import { cancelPasskeyRequest } from '../passkey/native';
import {
	approvePasskeyRequest,
	PasskeyRequestProps,
	PasskeyRequestRejection,
	PreparedPasskeyRequest,
	preparePasskeyRequest,
} from '../passkey/request';

const PASSKEY_CONSENT_TIMEOUT_MS = 60000;
// ConfirmAuth shows its success state for this long before returning to the calling app.
const PASSKEY_SUCCESS_MS = AUTH_SUCCESS_FADE_DURATION + 300;

type State =
	| { status: 'loading' }
	| { status: 'error'; message: string }
	| { status: 'consent'; request: PreparedPasskeyRequest }
	| { status: 'authorizing'; request: PreparedPasskeyRequest }
	| { status: 'authorized'; request: PreparedPasskeyRequest };

/**
 * The Authorize sheet (ConfirmAuth) for a passkey request, hosted by the Android
 * PasskeyConsentActivity. The activity is not a draggable sheet, so Deny stays.
 */
const PasskeyConsent = (props: PasskeyRequestProps): ReactElement => {
	const { t } = useTranslation();
	const dispatch = useDispatch();
	const alwaysShowDetails = useSelector(getAlwaysShowAuthDetails);
	const [state, setState] = useState<State>({ status: 'loading' });
	const [showDetails, setShowDetails] = useState(alwaysShowDetails);
	const [encryptionApproved, setEncryptionApproved] = useState(true);
	const finished = useRef(false);
	const activeAuth = useRef<AbortController | null>(null);
	const endSuccess = useRef<(() => void) | null>(null);

	const cancel = useCallback(
		(message: string) => {
			if (finished.current) return;
			finished.current = true;
			activeAuth.current?.abort();
			cancelPasskeyRequest(props.requestId, message).then();
		},
		[props.requestId],
	);

	const finishSuccess = useCallback(() => endSuccess.current?.(), []);

	const authorize = useCallback(
		async (request: PreparedPasskeyRequest, approvedCapabilities?: string) => {
			if (finished.current) return;
			const controller = new AbortController();
			activeAuth.current = controller;
			setState({ status: 'authorizing', request });
			const res = await approvePasskeyRequest({
				request,
				dispatch,
				approvedCapabilities,
				signal: controller.signal,
				onApproved: async () => {
					if (controller.signal.aborted || finished.current) return;
					setState({ status: 'authorized', request });
					await new Promise<void>(resolve => {
						const done = (): void => {
							clearTimeout(timer);
							endSuccess.current = null;
							resolve();
						};
						const timer = setTimeout(done, PASSKEY_SUCCESS_MS);
						endSuccess.current = done;
					});
				},
			});
			if (controller.signal.aborted || finished.current) return;
			if (res.isOk()) {
				finished.current = true;
				return;
			}
			if (res.error instanceof DeviceAuthError && res.error.code === 'cancelled') {
				setState({ status: 'consent', request });
				return;
			}
			setState({ status: 'error', message: res.error.message || t('passkey.errors.generic') });
		},
		[dispatch, t],
	);

	useEffect(() => {
		let active = true;
		preparePasskeyRequest(props).then(res => {
			if (!active) return;
			if (res.isErr()) {
				setState({
					status: 'error',
					message:
						res.error instanceof PasskeyRequestRejection
							? t(`passkey.errors.${res.error.code}`)
							: res.error.message || t('passkey.errors.generic'),
				});
				return;
			}
			// Auto Auth is a developer option; scanning skips consent when it is on, and so does this path.
			if (getAutoAuthFromStore()) {
				authorize(res.value);
				return;
			}
			setState({ status: 'consent', request: res.value });
		});
		return () => {
			active = false;
		};
	}, [authorize, props, t]);

	const dismiss = useCallback(() => {
		if (state.status === 'authorized') {
			finishSuccess();
			return;
		}
		cancel('User cancelled');
	}, [cancel, finishSuccess, state.status]);

	useEffect(() => {
		const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
			if (showDetails && state.status === 'consent') {
				setShowDetails(false);
			} else {
				dismiss();
			}
			return true;
		});
		return () => subscription.remove();
	}, [dismiss, showDetails, state.status]);

	useEffect(() => {
		if (state.status !== 'consent') return;
		const timeout = setTimeout(() => cancel('Consent timed out'), PASSKEY_CONSENT_TIMEOUT_MS);
		return () => clearTimeout(timeout);
	}, [cancel, state.status]);

	const request = 'request' in state ? state.request : undefined;
	const capabilities = useMemo(() => request?.payload.authDetails.capabilities ?? [], [request]);
	const hasEncryption = hasEncryptionCapabilities(capabilities);
	const approvedCapabilities = useMemo(
		() => buildApprovedCapabilities(capabilities, encryptionApproved),
		[capabilities, encryptionApproved],
	);
	const pubkyName = useSelector((rootState: RootState) =>
		request ? getPubkyName(rootState, request.storeKey) : undefined,
	);

	const handleApprove = useCallback(async () => {
		if (!request) return;
		const approval = hasEncryption
			? approvedCapabilities.map(({ path, permission }) => `${path}:${permission}`).join(',')
			: undefined;
		await authorize(request, approval);
	}, [approvedCapabilities, authorize, hasEncryption, request]);

	const deny = useCallback(() => cancel('User denied'), [cancel]);

	if (state.status === 'loading' || state.status === 'error') {
		const failed = state.status === 'error';
		return (
			<SheetCard onBackdropPress={dismiss}>
				<SheetLayout
					id="passkey"
					title={t(failed ? 'passkey.errorTitle' : 'auth.authorize')}
					titleTestID="PasskeyConsentTitle"
					showBottomSafeAreaInset={false}
				>
					<View style={styles.message} testID={failed ? 'PasskeyConsentError' : 'PasskeyConsentLoading'}>
						{failed ? (
							<TextBaseM accessibilityRole="alert">{state.message}</TextBaseM>
						) : (
							<ActivityIndicator style={styles.loading} />
						)}
					</View>
					{failed && (
						<View style={styles.footer}>
							<Button
								text={t('common.close')}
								size="large"
								style={authRequestStyles.fullWidthButton}
								testID="PasskeyConsentClose"
								onPress={() => cancel(state.message)}
							/>
						</View>
					)}
					<SafeAreaInset edge="bottom" />
				</SheetLayout>
			</SheetCard>
		);
	}

	const authorizing = state.status === 'authorizing';
	const isAuthorized = state.status === 'authorized';
	return (
		<SheetCard onBackdropPress={dismiss}>
			<SheetLayout
				id="passkey"
				title={t(isAuthorized ? 'auth.authorizedTitle' : 'auth.authorize')}
				titleTestID="PasskeyConsentTitle"
				showBottomSafeAreaInset={false}
				onBackPress={showDetails && state.status === 'consent' ? () => setShowDetails(false) : undefined}
				headerRight={
					state.status === 'consent' ? (
						<CircularProgressBar duration={PASSKEY_CONSENT_TIMEOUT_MS} size={24} drain />
					) : undefined
				}
			>
				<AuthRequestContent
					view={isAuthorized ? 'success' : showDetails ? 'details' : 'basic'}
					pubky={state.request.storeKey}
					name={pubkyName}
					capabilities={capabilities}
					encryptionApproved={encryptionApproved}
					onEncryptionApprovedChange={setEncryptionApproved}
					relay={state.request.payload.authDetails.relay}
					authorizing={authorizing}
					testIDPrefix="PasskeyConsent"
					detailsHeader={
						<PermissionCard testID="PasskeyConsentVerifiedSite">
							<TextXsM style={authRequestStyles.sectionTitle}>{t('passkey.requestingSite')}</TextXsM>
							<View style={authRequestStyles.permissionRow}>
								<Globe size={16} />
								<TextSmM colorName="foreground" style={authRequestStyles.path} selectable>
									{state.request.rpId}
								</TextSmM>
								<Shield size={16} colorName="pubkyApp" />
							</View>
							<TextSmM style={styles.note}>{t('passkey.verifiedByBrowser')}</TextSmM>
						</PermissionCard>
					}
					footerExtra={
						<Button
							text={t('auth.deny')}
							size="large"
							style={authRequestStyles.fullWidthButton}
							variant="secondary"
							disabled={authorizing}
							testID="PasskeyConsentDeny"
							onPress={deny}
						/>
					}
					onShowDetails={() => setShowDetails(true)}
					onConfirm={handleApprove}
					onDone={finishSuccess}
					onEscape={deny}
				/>
				<SafeAreaInset edge="bottom" />
			</SheetLayout>
		</SheetCard>
	);
};

const styles = StyleSheet.create({
	message: { flex: 1 },
	loading: { flex: 1 },
	note: { marginTop: 8 },
	footer: { paddingBottom: 12 },
});

export default memo(PasskeyConsent);
