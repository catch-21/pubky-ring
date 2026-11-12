import React, { memo, ReactElement, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackHandler, StyleSheet, View } from 'react-native';
import { useDispatch, useSelector } from 'react-redux';
import { useTranslation } from 'react-i18next';
import type { RootState } from '../store';
import { ActivityIndicator } from '../theme/components.ts';
import { TextSmM, TextXsM } from '../theme/typography';
import { getPubkyName } from '../store/selectors/pubkySelectors.ts';
import { getAlwaysShowAuthDetails } from '../store/selectors/settingsSelectors.ts';
import { getAutoAuthFromStore } from '../utils/store-helpers.ts';
import { DeviceAuthError } from '../utils/deviceAuth';
import { buildApprovedCapabilities, hasEncryptionCapabilities } from '../utils/authCapabilities.ts';
import PermissionCard from '../components/PermissionCard.tsx';
import CircularProgressBar from '../components/CircularProgressBar.tsx';
import SafeAreaInset from '../components/SafeAreaInset.tsx';
import { SheetCard, SheetLayout } from '../components/Sheet.tsx';
import AuthRequestContent, { authRequestStyles } from '../components/AuthRequestContent.tsx';
import { Globe, Shield } from '../icons/index.ts';
import { cancelPasskeyRequest } from '../passkey/native';
import {
	approvePasskeyRequest,
	PasskeyRequestProps,
	PasskeyRequestRejection,
	PreparedPasskeyRequest,
	preparePasskeyRequest,
} from '../passkey/request';
import { PasskeyRefusalReason, refusePasskeyRequest } from '../passkey/report';

const PASSKEY_CONSENT_TIMEOUT_MS = 60000;

type State =
	| { status: 'loading' }
	| { status: 'consent'; request: PreparedPasskeyRequest }
	| { status: 'authorizing'; request: PreparedPasskeyRequest };

/**
 * The Authorize sheet (ConfirmAuth) for a passkey request, hosted by the Android
 * PasskeyConsentActivity. Dragging the sheet down, back and a tap outside it all
 * cancel the request, so there is no Deny button. A request Ring will not sign
 * ends at once as a failure, after its reason is reported to the relay.
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

	const cancel = useCallback(
		(message: string) => {
			if (finished.current) return;
			finished.current = true;
			activeAuth.current?.abort();
			cancelPasskeyRequest(props.requestId, message).then();
		},
		[props.requestId],
	);

	const refuse = useCallback(
		(reason: PasskeyRefusalReason) => {
			if (finished.current) return;
			finished.current = true;
			activeAuth.current?.abort();
			setState({ status: 'loading' });
			refusePasskeyRequest({ requestId: props.requestId, envelope: props.envelope, reason }).then();
		},
		[props.envelope, props.requestId],
	);

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
			refuse(res.error.message === 'replayed' ? 'replayed' : 'approval_failed');
		},
		[dispatch, refuse],
	);

	useEffect(() => {
		let active = true;
		preparePasskeyRequest(props).then(res => {
			if (!active) return;
			if (res.isErr()) {
				refuse(res.error instanceof PasskeyRequestRejection ? res.error.code : 'invalid_link');
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
	}, [authorize, props, refuse]);

	const dismiss = useCallback(() => cancel('User cancelled'), [cancel]);

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

	if (state.status === 'loading') {
		return (
			<SheetCard onBackdropPress={dismiss} onDragDismiss={dismiss}>
				<SheetLayout
					id="passkey"
					title={t('auth.authorize')}
					titleTestID="PasskeyConsentTitle"
					showBottomSafeAreaInset={false}
				>
					<View style={styles.message} testID="PasskeyConsentLoading">
						<ActivityIndicator style={styles.loading} />
					</View>
					<SafeAreaInset edge="bottom" />
				</SheetLayout>
			</SheetCard>
		);
	}

	const authorizing = state.status === 'authorizing';
	return (
		<SheetCard onBackdropPress={dismiss} onDragDismiss={dismiss}>
			<SheetLayout
				id="passkey"
				title={t('auth.authorize')}
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
					view={showDetails ? 'details' : 'basic'}
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
					onShowDetails={() => setShowDetails(true)}
					onConfirm={handleApprove}
					onEscape={dismiss}
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
});

export default memo(PasskeyConsent);
