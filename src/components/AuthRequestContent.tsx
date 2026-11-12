import React, { memo, ReactElement, ReactNode, useContext, useEffect, useMemo } from 'react';
import { Image, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { ScrollView as GestureScrollView } from 'react-native-gesture-handler';
import { useTranslation } from 'react-i18next';
import Animated, {
	useAnimatedStyle,
	useSharedValue,
	withSequence,
	withTiming,
} from 'react-native-reanimated';
import { useTheme } from 'styled-components/native';
import type { Theme } from '../theme';
import { TextSmM, TextXsM } from '../theme/typography';
import { CheckCircle, Eye, Folder, Globe, List, Lock, Pencil, UserCheck } from '../icons/index.ts';
import {
	buildApprovedCapabilities,
	hasEncryptionCapabilities,
	type AuthCapability,
} from '../utils/authCapabilities.ts';
import Button from './Button.tsx';
import PermissionCard from './PermissionCard.tsx';
import AuthIdentity from './AuthIdentity.tsx';
import AuthSummary from './AuthSummary.tsx';
import SwipeToConfirm from './SwipeToConfirm.tsx';
import { SheetDragContext } from './Sheet.tsx';

export const AUTH_SUCCESS_FADE_DURATION = 100;

export type AuthRequestView = 'basic' | 'details' | 'success';

const Permission = memo(
	({
		capability,
		encryptionApproved,
	}: {
		capability: AuthCapability;
		encryptionApproved: boolean;
	}): ReactElement => {
		const { t } = useTranslation();
		const read = capability.permission.includes('r');
		const write = capability.permission.includes('w');
		const encrypt = capability.permission.includes('e') && encryptionApproved;
		const label = [read && t('common.read'), write && t('common.write'), encrypt && t('auth.encryptedData')]
			.filter(Boolean)
			.join(', ');
		return (
			<View
				style={styles.permissionRow}
				accessible
				accessibilityLabel={`${capability.path}: ${label || t('activeSession.noPermissions')}`}
			>
				<Folder size={16} />
				<TextSmM style={styles.path} colorName="foreground">
					{capability.path}
				</TextSmM>
				<View style={styles.permissions}>
					<Eye size={16} colorName={read ? 'foreground' : 'border'} />
					<Pencil size={16} colorName={write ? 'foreground' : 'border'} />
					<Lock size={16} colorName={encrypt ? 'foreground' : 'border'} />
				</View>
			</View>
		);
	},
);

interface AuthRequestContentProps {
	view: AuthRequestView;
	pubky: string;
	name?: string;
	/** Capabilities as requested, before the user's encryption choice. */
	capabilities: AuthCapability[];
	encryptionApproved: boolean;
	onEncryptionApprovedChange: (approved: boolean) => void;
	relay?: string;
	authorizing: boolean;
	testIDPrefix?: string;
	/** Shown above the basic and details views. */
	notice?: ReactNode;
	/** First cards of the details view. */
	detailsHeader?: ReactNode;
	onShowDetails: () => void;
	onConfirm: () => Promise<void>;
	/** Closes the success view. */
	onDone?: () => void;
	onEscape?: () => void;
}

/** The Authorize sheet body shared by deep-link and passkey sign-in. */
const AuthRequestContent = ({
	view,
	pubky,
	name,
	capabilities,
	encryptionApproved,
	onEncryptionApprovedChange,
	relay,
	authorizing,
	testIDPrefix = 'ConfirmAuth',
	notice,
	detailsHeader,
	onShowDetails,
	onConfirm,
	onDone,
	onEscape,
}: AuthRequestContentProps): ReactElement => {
	const { t } = useTranslation();
	const theme = useTheme() as Theme;
	const isAuthorized = view === 'success';
	const hasEncryption = hasEncryptionCapabilities(capabilities);
	const approvedCapabilities = useMemo(
		() => buildApprovedCapabilities(capabilities, encryptionApproved),
		[capabilities, encryptionApproved],
	);
	const identityOnly = !capabilities.some(capability => capability.permission.length > 0);
	const sheetDrag = useContext(SheetDragContext);
	const checkOpacity = useSharedValue(0);
	const checkScale = useSharedValue(0.5);
	const checkStyle = useAnimatedStyle(() => ({
		opacity: checkOpacity.get(),
		transform: [{ scale: checkScale.get() }],
	}));

	useEffect(() => {
		if (isAuthorized) {
			checkOpacity.set(withTiming(1, { duration: AUTH_SUCCESS_FADE_DURATION }));
			checkScale.set(withSequence(withTiming(0.5, { duration: 0 }), withTiming(1, { duration: 300 })));
		}
	}, [checkOpacity, checkScale, isAuthorized]);

	useEffect(() => {
		sheetDrag?.scrollOffset.set(0);
	}, [sheetDrag, view]);

	const bodyProps = { testID: `${testIDPrefix}DetailsScrollView`, onAccessibilityEscape: onEscape };
	// In a draggable sheet the basic view does not scroll, so a drag anywhere on it closes the
	// sheet; the details scroll alongside the drag, which only moves the sheet from the top.
	const renderBody = (children: ReactNode): ReactElement =>
		!sheetDrag ? (
			<ScrollView
				key={view}
				{...bodyProps}
				style={styles.scroll}
				contentContainerStyle={styles.scrollContent}
			>
				{children}
			</ScrollView>
		) : view === 'details' ? (
			<GestureScrollView
				key={view}
				{...bodyProps}
				style={styles.scroll}
				contentContainerStyle={styles.scrollContent}
				simultaneousWith={sheetDrag.gesture}
				overScrollMode="never"
				bounces={false}
				scrollEventThrottle={16}
				onScroll={event => sheetDrag.scrollOffset.set(event.nativeEvent.contentOffset.y)}
			>
				{children}
			</GestureScrollView>
		) : (
			<View key={view} {...bodyProps} style={[styles.scroll, styles.scrollContent]}>
				{children}
			</View>
		);

	return (
		<>
			{renderBody(
				<>
					{!isAuthorized && notice}
					{isAuthorized ? (
						<>
							<AuthSummary capabilities={approvedCapabilities} authorized />
							<View style={styles.hero}>
								<Animated.View style={checkStyle}>
									<CheckCircle colorName="pubkyApp" size={96} strokeWidth={1} />
								</Animated.View>
								<AuthIdentity name={name} pubky={pubky} />
							</View>
						</>
					) : view === 'details' ? (
						<>
							<View style={styles.cards}>
								{detailsHeader}
								<PermissionCard
									testID={
										identityOnly
											? `${testIDPrefix}IdentityVerification`
											: `${testIDPrefix}RequestedPermissions`
									}
								>
									{identityOnly ? (
										<>
											<TextXsM style={styles.sectionTitle}>{t('auth.identityVerification')}</TextXsM>
											<View style={styles.permissionRow}>
												<UserCheck size={16} />
												<TextSmM colorName="foreground" style={styles.path}>
													{t('auth.provePubkyControl')}
												</TextSmM>
											</View>
										</>
									) : (
										<>
											<View style={styles.permissionHeader}>
												<TextXsM>{t('auth.folder')}</TextXsM>
												<TextXsM>{t('auth.permissions')}</TextXsM>
											</View>
											<View style={styles.permissionList}>
												{capabilities.map((capability, index) => (
													<Permission
														key={`${capability.path}:${index}`}
														capability={capability}
														encryptionApproved={encryptionApproved}
													/>
												))}
											</View>
										</>
									)}
								</PermissionCard>
								{hasEncryption && (
									<PermissionCard>
										<TextXsM style={styles.sectionTitle}>{t('auth.encryptedData')}</TextXsM>
										<View style={styles.permissionRow}>
											<Lock size={16} />
											<TextSmM style={styles.path} colorName="foreground">
												{t('auth.allowEncryptedData')}
											</TextSmM>
											<Pressable
												testID="AuthEncryptionToggle"
												accessibilityRole="switch"
												accessibilityLabel={t('auth.allowEncryptedData')}
												accessibilityState={{ checked: encryptionApproved, disabled: authorizing }}
												disabled={authorizing}
												hitSlop={12}
												style={[
													styles.encryptionSwitch,
													{ backgroundColor: encryptionApproved ? theme.colors.blue : theme.colors.input },
												]}
												onPress={() => onEncryptionApprovedChange(!encryptionApproved)}
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
								{!!relay && (
									<PermissionCard testID={`${testIDPrefix}Relay`}>
										<TextXsM style={styles.sectionTitle}>{t('auth.relay')}</TextXsM>
										<View style={styles.permissionRow}>
											<Globe size={16} />
											<TextSmM colorName="foreground" style={styles.path} selectable>
												{relay}
											</TextSmM>
										</View>
									</PermissionCard>
								)}
							</View>
							<View style={styles.spacer} />
							<TextSmM>
								{t(
									identityOnly
										? 'auth.identityVerificationWarning'
										: hasEncryption
											? 'auth.encryptionTrustWarning'
											: 'auth.trustWarning',
								)}
							</TextSmM>
						</>
					) : (
						<>
							<AuthSummary capabilities={approvedCapabilities} authorized={false} />
							<View style={styles.hero}>
								<View style={styles.shieldContainer}>
									<Image
										source={require('../images/shield.png')}
										style={styles.shield}
										resizeMode="contain"
										accessibilityIgnoresInvertColors
									/>
									<View style={styles.shieldIdentity}>
										<AuthIdentity name={name} pubky={pubky} />
									</View>
								</View>
							</View>
						</>
					)}
				</>,
			)}

			<View style={styles.footer}>
				{!isAuthorized &&
					(view === 'details' ? (
						<AuthIdentity name={name} pubky={pubky} fullWidth />
					) : (
						<Button
							text={t('auth.showDetails')}
							size="large"
							style={styles.fullWidthButton}
							icon={<List size={16} />}
							testID={`${testIDPrefix}ShowDetailsButton`}
							disabled={authorizing}
							onPress={onShowDetails}
						/>
					))}
				{isAuthorized ? (
					<Button
						text={t('common.ok')}
						size="large"
						style={styles.fullWidthButton}
						variant="secondary"
						testID={`${testIDPrefix}SuccessButton`}
						onPress={onDone}
					/>
				) : (
					<SwipeToConfirm
						text={t(authorizing ? 'auth.authorizing' : 'auth.swipeToAuthorize')}
						loading={authorizing}
						testID={`${testIDPrefix}AuthorizeButton`}
						onConfirm={onConfirm}
					/>
				)}
			</View>
		</>
	);
};

export const authRequestStyles = StyleSheet.create({
	sectionTitle: { marginBottom: 8 },
	permissionRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
	path: { flex: 1, minWidth: 0 },
	fullWidthButton: { flex: 0, width: '100%' },
});

const styles = StyleSheet.create({
	...authRequestStyles,
	scroll: { flex: 1 },
	scrollContent: { flexGrow: 1, paddingBottom: 24 },
	cards: { gap: 24 },
	permissionHeader: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 8 },
	permissionList: { gap: 8 },
	permissions: { flexDirection: 'row', gap: 12 },
	encryptionSwitch: { width: 36, height: 20, padding: 2, borderRadius: 10 },
	switchThumb: { width: 16, height: 16, borderRadius: 8 },
	spacer: { flex: 1, minHeight: 24 },
	hero: { flex: 1, minHeight: 200, justifyContent: 'center', alignItems: 'center', gap: 24 },
	shieldContainer: { width: '100%', maxWidth: 327, aspectRatio: 1 },
	shield: { width: '100%', height: '100%' },
	shieldIdentity: { ...StyleSheet.absoluteFill, alignItems: 'center', justifyContent: 'center' },
	footer: { gap: 24, paddingBottom: 12 },
});

export default memo(AuthRequestContent);
