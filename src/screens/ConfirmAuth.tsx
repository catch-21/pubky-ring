import React, { memo, ReactElement, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackHandler, StyleSheet, View } from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { showToast } from '@synonymdev/react-native-toast';
import { useDispatch, useSelector } from 'react-redux';
import { useTranslation } from 'react-i18next';
import { hideSheet } from '../sheets/sheetNavigation.tsx';
import { performAuth, truncatePubky } from '../utils/pubky';
import { DeviceAuthError } from '../utils/deviceAuth';
import { sleep } from '../utils/helpers.ts';
import { TextBaseB, TextSmM } from '../theme/typography';
import type { RootState } from '../store';
import { getPubkyName } from '../store/selectors/pubkySelectors.ts';
import { getAlwaysShowAuthDetails } from '../store/selectors/settingsSelectors.ts';
import { openXSuccess, openXError, openXCancel } from '../utils/xCallback.ts';
import { SheetScreen } from '../components/Sheet.tsx';
import SafeAreaInset from '../components/SafeAreaInset.tsx';
import CircularProgressBar from '../components/CircularProgressBar.tsx';
import AuthRequestContent, { AUTH_SUCCESS_FADE_DURATION } from '../components/AuthRequestContent.tsx';
import type { AuthStackParamList } from '../sheets/types.ts';
import { syncAuthorizedGrantsAfterAuth } from '../utils/authorizedGrants.ts';
import { getAuthorizedGrantCount } from '../store/selectors/authorizedGrantsSelectors.ts';
import { buildApprovedCapabilities, hasEncryptionCapabilities } from '../utils/authCapabilities.ts';

const CONFIRM_AUTH_TIMEOUT_MS = 60000;

type Props = NativeStackScreenProps<AuthStackParamList, 'ConfirmAuth'>;

const ConfirmAuthRequest = ({ route, navigation }: Props): ReactElement => {
	const { t } = useTranslation();
	const { pubky, authUrl, authDetails, xCallback, expectedSigner } = route.params;
	const dispatch = useDispatch();
	const alwaysShowDetails = useSelector(getAlwaysShowAuthDetails);
	const [showDetails, setShowDetails] = useState(alwaysShowDetails);
	const [authorizing, setAuthorizing] = useState(false);
	const [isAuthorized, setIsAuthorized] = useState(false);
	const [encryptionApproved, setEncryptionApproved] = useState(true);
	const request = useRef({ authorizing: false, finished: false });
	const activeAuth = useRef<AbortController | null>(null);
	useEffect(
		() => () => {
			activeAuth.current?.abort();
			request.current.finished = true;
		},
		[],
	);
	const pubkyName = useSelector((state: RootState) => getPubkyName(state, pubky));
	const authorizedGrantCount = useSelector((state: RootState) => getAuthorizedGrantCount(state, pubky));
	const capabilities = useMemo(() => authDetails.capabilities ?? [], [authDetails.capabilities]);
	const hasEncryption = hasEncryptionCapabilities(capabilities);
	const approvedCapabilities = useMemo(
		() => buildApprovedCapabilities(capabilities, encryptionApproved),
		[capabilities, encryptionApproved],
	);
	const requestingClient = authDetails.client_id || xCallback?.xSource;

	useFocusEffect(
		useCallback(() => {
			if (!showDetails || isAuthorized || authorizing) return;
			const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
				setShowDetails(false);
				return true;
			});
			return () => subscription.remove();
		}, [showDetails, isAuthorized, authorizing]),
	);

	const handleClose = useCallback(() => {
		activeAuth.current?.abort();
		hideSheet('auth');
	}, []);
	const handleDeny = useCallback(() => {
		if (!request.current.finished) {
			request.current.finished = true;
			openXCancel(xCallback);
		}
		handleClose();
	}, [request, xCallback, handleClose]);

	useEffect(
		() =>
			navigation.getParent()?.addListener('beforeRemove', () => {
				if (!request.current.finished) {
					activeAuth.current?.abort();
					request.current.finished = true;
					openXCancel(xCallback);
				}
			}),
		[navigation, xCallback],
	);

	useEffect(() => {
		if (isAuthorized) return;
		const timeout = setTimeout(handleDeny, CONFIRM_AUTH_TIMEOUT_MS);
		return () => clearTimeout(timeout);
	}, [handleDeny, isAuthorized]);

	const handleAuth = useCallback(async () => {
		if (request.current.authorizing || request.current.finished) return;
		request.current.authorizing = true;
		const controller = new AbortController();
		activeAuth.current = controller;
		setAuthorizing(true);
		try {
			const approval = hasEncryption
				? approvedCapabilities.map(({ path, permission }) => `${path}:${permission}`).join(',')
				: undefined;
			const res = await performAuth({
				pubky,
				authUrl,
				dispatch,
				approvedCapabilities: approval,
				signal: controller.signal,
			});
			if (controller.signal.aborted || request.current.finished) return;
			if (res.isErr()) {
				if (res.error instanceof DeviceAuthError && res.error.code === 'cancelled') return;
				showToast({
					type: 'error',
					title: t('common.error'),
					description: res.error.message,
				});
				if (!(res.error instanceof DeviceAuthError))
					await openXError(xCallback, 'AUTH_FAILED', res.error.message);
				return;
			}
			request.current.finished = true;
			setIsAuthorized(true);
			syncAuthorizedGrantsAfterAuth({
				pubky,
				dispatch,
				currentCount: authorizedGrantCount,
				isGrantAuth: authDetails.kind === 'signin_grant' || authDetails.kind === 'signup_grant',
			}).then();
			if (xCallback?.xSuccess) {
				await sleep(AUTH_SUCCESS_FADE_DURATION + 300);
				handleClose();
				await openXSuccess(xCallback);
			}
		} catch (e: unknown) {
			if (controller.signal.aborted || request.current.finished) return;
			const error = e as Error;
			const errorMsg =
				error.message === 'Authentication request timed out'
					? t('auth.timeoutError')
					: error.message || t('confirmAuth.errorOccurred');
			showToast({
				type: 'error',
				title: t('common.error'),
				description: errorMsg,
				autoHide: true,
				durationMs: 20000,
			});
			console.error('Auth error:', error);
			await openXError(xCallback, 'AUTH_ERROR', errorMsg);
		} finally {
			request.current.authorizing = false;
			if (activeAuth.current === controller) activeAuth.current = null;
			if (!request.current.finished) setAuthorizing(false);
		}
	}, [
		approvedCapabilities,
		authDetails.kind,
		authUrl,
		authorizedGrantCount,
		hasEncryption,
		xCallback,
		dispatch,
		handleClose,
		pubky,
		t,
		request,
	]);

	return (
		<SheetScreen
			id="auth"
			title={t(isAuthorized ? 'auth.authorizedTitle' : 'auth.authorize')}
			titleTestID="confirm-auth-title"
			showBottomSafeAreaInset={false}
			showBackButton={!isAuthorized && !authorizing}
			onBackPress={showDetails ? () => setShowDetails(false) : undefined}
			headerRight={
				!isAuthorized ? <CircularProgressBar duration={CONFIRM_AUTH_TIMEOUT_MS} size={24} drain /> : undefined
			}
		>
			<AuthRequestContent
				view={isAuthorized ? 'success' : showDetails ? 'details' : 'basic'}
				pubky={pubky}
				name={pubkyName}
				capabilities={capabilities}
				encryptionApproved={encryptionApproved}
				onEncryptionApprovedChange={setEncryptionApproved}
				relay={authDetails.relay}
				authorizing={authorizing}
				notice={
					expectedSigner && (
						<View style={styles.expectedIdentity} testID="ConfirmAuthExpectedIdentity">
							<TextBaseB color="#061a2f">
								{pubkyName
									? t('auth.expectedIdentityTitle', {
											appName: requestingClient || t('auth.thisApp'),
											name: pubkyName,
											pubky: truncatePubky(pubky),
										})
									: t('auth.expectedIdentityTitleNoName', {
											appName: requestingClient || t('auth.thisApp'),
											pubky: truncatePubky(pubky),
										})}
							</TextBaseB>
							<TextSmM color="#061a2f">{t('auth.expectedIdentityDescription')}</TextSmM>
						</View>
					)
				}
				onShowDetails={() => setShowDetails(true)}
				onConfirm={handleAuth}
				onDone={handleClose}
				onEscape={handleDeny}
			/>
			<SafeAreaInset edge="bottom" />
		</SheetScreen>
	);
};

const styles = StyleSheet.create({
	expectedIdentity: {
		gap: 4,
		marginBottom: 16,
		paddingHorizontal: 16,
		paddingVertical: 12,
		borderRadius: 12,
		backgroundColor: '#0085FF',
	},
});

// Reset consent state when the request or selected identity changes.
const ConfirmAuth = (props: Props): ReactElement => (
	<ConfirmAuthRequest key={`${props.route.params.pubky}:${props.route.params.authUrl}`} {...props} />
);

export default memo(ConfirmAuth);
