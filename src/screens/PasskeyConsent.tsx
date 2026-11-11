import React, { memo, ReactElement, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackHandler, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { useDispatch, useSelector } from 'react-redux';
import { useTranslation } from 'react-i18next';
import { useTheme } from 'styled-components/native';
import type { RootState } from '../store';
import type { Theme } from '../theme';
import { ThemedView } from '../theme/components.ts';
import { TextBaseM, TextSmM, TextXlB, TextXsM } from '../theme/typography';
import { getPubkyName } from '../store/selectors/pubkySelectors.ts';
import { getAutoAuthFromStore } from '../utils/store-helpers.ts';
import { DeviceAuthError } from '../utils/deviceAuth';
import { buildApprovedCapabilities, hasEncryptionCapabilities } from '../utils/authCapabilities.ts';
import Button from '../components/Button.tsx';
import SwipeToConfirm from '../components/SwipeToConfirm.tsx';
import PermissionCard from '../components/PermissionCard.tsx';
import AuthIdentity from '../components/AuthIdentity.tsx';
import AuthSummary from '../components/AuthSummary.tsx';
import CircularProgressBar from '../components/CircularProgressBar.tsx';
import { Folder, Globe, Lock, Shield } from '../icons/index.ts';
import { cancelPasskeyRequest } from '../passkey/native';
import {
	approvePasskeyRequest,
	PasskeyRequestProps,
	PasskeyRequestRejection,
	PreparedPasskeyRequest,
	preparePasskeyRequest,
} from '../passkey/request';

const PASSKEY_CONSENT_TIMEOUT_MS = 60000;

type State =
	| { status: 'loading' }
	| { status: 'error'; message: string }
	| { status: 'consent'; request: PreparedPasskeyRequest }
	| { status: 'authorizing'; request: PreparedPasskeyRequest };

const PasskeyConsent = (props: PasskeyRequestProps): ReactElement => {
	const { t } = useTranslation();
	const theme = useTheme() as Theme;
	const dispatch = useDispatch();
	const [state, setState] = useState<State>({ status: 'loading' });
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

	const authorize = useCallback(
		async (request: PreparedPasskeyRequest, approvedCapabilities?: string) => {
			if (finished.current) return;
			const controller = new AbortController();
			activeAuth.current = controller;
			setState({ status: 'authorizing', request });
			const res = await approvePasskeyRequest({ request, dispatch, approvedCapabilities, signal: controller.signal });
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

	useEffect(() => {
		const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
			cancel('User cancelled');
			return true;
		});
		return () => subscription.remove();
	}, [cancel]);

	useEffect(() => {
		if (state.status !== 'consent') return;
		const timeout = setTimeout(() => cancel('Consent timed out'), PASSKEY_CONSENT_TIMEOUT_MS);
		return () => clearTimeout(timeout);
	}, [cancel, state.status]);

	const request = state.status === 'consent' || state.status === 'authorizing' ? state.request : undefined;
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
		return <ThemedView style={styles.container} testID="PasskeyConsentLoading" />;
	}

	if (state.status === 'error') {
		return (
			<ThemedView style={styles.container} testID="PasskeyConsentError">
				<View style={styles.content}>
					<TextXlB>{t('passkey.errorTitle')}</TextXlB>
					<TextBaseM accessibilityRole="alert">{state.message}</TextBaseM>
				</View>
				<Button text={t('common.close')} size="large" onPress={() => cancel(state.message)} />
			</ThemedView>
		);
	}

	const authorizing = state.status === 'authorizing';
	return (
		<ThemedView style={styles.container} testID="PasskeyConsent">
			<View style={styles.header}>
				<TextXlB style={styles.title}>{t('passkey.consentTitle')}</TextXlB>
				{!authorizing && <CircularProgressBar duration={PASSKEY_CONSENT_TIMEOUT_MS} size={24} drain />}
			</View>
			<ScrollView style={styles.scroll} contentContainerStyle={styles.content}>
				<PermissionCard testID="PasskeyConsentVerifiedSite">
					<TextXsM style={styles.sectionTitle}>{t('passkey.requestingSite')}</TextXsM>
					<View style={styles.row}>
						<Globe size={16} />
						<TextBaseM colorName="foreground" style={styles.flex} selectable>
							{state.request.rpId}
						</TextBaseM>
						<Shield size={16} colorName="pubkyApp" />
					</View>
					<TextSmM style={styles.note}>{t('passkey.verifiedByBrowser')}</TextSmM>
				</PermissionCard>
				<AuthSummary capabilities={approvedCapabilities} authorized={false} />
				<PermissionCard>
					<TextXsM style={styles.sectionTitle}>{t('auth.permissions')}</TextXsM>
					{capabilities.length === 0 && <TextSmM>{t('auth.provePubkyControl')}</TextSmM>}
					{capabilities.map((capability, index) => (
						<View key={`${capability.path}:${index}`} style={styles.row}>
							<Folder size={16} />
							<TextSmM colorName="foreground" style={styles.flex}>
								{capability.path}
							</TextSmM>
							<TextSmM>{capability.permission}</TextSmM>
						</View>
					))}
				</PermissionCard>
				{hasEncryption && (
					<PermissionCard>
						<View style={styles.row}>
							<Lock size={16} />
							<TextSmM style={styles.flex} colorName="foreground">
								{t('auth.allowEncryptedData')}
							</TextSmM>
							<Pressable
								testID="PasskeyEncryptionToggle"
								accessibilityRole="switch"
								accessibilityLabel={t('auth.allowEncryptedData')}
								accessibilityState={{ checked: encryptionApproved, disabled: authorizing }}
								disabled={authorizing}
								hitSlop={12}
								style={[
									styles.switch,
									{ backgroundColor: encryptionApproved ? theme.colors.blue : theme.colors.input },
								]}
								onPress={() => setEncryptionApproved(current => !current)}
							>
								<View
									style={[
										styles.switchThumb,
										{
											backgroundColor: theme.colors.background,
											transform: [{ translateX: encryptionApproved ? 16 : 0 }],
										},
									]}
								/>
							</Pressable>
						</View>
					</PermissionCard>
				)}
				<AuthIdentity name={pubkyName} pubky={state.request.storeKey} fullWidth />
			</ScrollView>
			<View style={styles.footer}>
				<SwipeToConfirm
					text={t(authorizing ? 'auth.authorizing' : 'auth.swipeToAuthorize')}
					loading={authorizing}
					testID="PasskeyConsentApprove"
					onConfirm={handleApprove}
				/>
				<Button
					text={t('auth.deny')}
					size="large"
					variant="secondary"
					disabled={authorizing}
					testID="PasskeyConsentDeny"
					onPress={() => cancel('User denied')}
				/>
			</View>
		</ThemedView>
	);
};

const styles = StyleSheet.create({
	container: { flex: 1, padding: 24, gap: 16 },
	header: { flexDirection: 'row', alignItems: 'center', gap: 12 },
	title: { flex: 1 },
	scroll: { flex: 1 },
	content: { flexGrow: 1, gap: 16, paddingBottom: 16 },
	sectionTitle: { marginBottom: 8 },
	row: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 2 },
	flex: { flex: 1, minWidth: 0 },
	note: { marginTop: 8 },
	switch: { width: 36, height: 20, padding: 2, borderRadius: 10 },
	switchThumb: { width: 16, height: 16, borderRadius: 8 },
	footer: { gap: 12 },
});

export default memo(PasskeyConsent);
