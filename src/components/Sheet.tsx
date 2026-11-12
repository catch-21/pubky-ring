import React, { createContext, memo, ReactElement, ReactNode, useMemo } from 'react';
import {
	Platform,
	Pressable,
	ScrollView,
	StyleProp,
	StyleSheet,
	useWindowDimensions,
	View,
	ViewStyle,
} from 'react-native';
import { useIsFocused, useNavigation, useNavigationState } from '@react-navigation/native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { GestureDetector, type PanGesture, usePanGesture } from 'react-native-gesture-handler';
import Animated, {
	type SharedValue,
	useAnimatedStyle,
	useSharedValue,
	withSpring,
	withTiming,
} from 'react-native-reanimated';
import { scheduleOnRN } from 'react-native-worklets';
import SafeAreaInset from './SafeAreaInset.tsx';
import { LinearGradient, RadialGradient } from './LinearGradient.tsx';
import { TextLgSb } from '../theme/typography.ts';
import HeaderNavButton from './HeaderNavButton.tsx';
import { ArrowLeft } from '../icons/index.ts';
import { HEADER_HEIGHT } from './AppHeader.tsx';
import type { SheetId } from '../sheets/types.ts';
import { hideActiveSheet } from '../sheets/sheetNavigation.tsx';
import { shouldUseAndroidSheetFallback } from '../sheets/sheetPlatform.ts';
import { ThemedView } from '../theme/components.ts';

export type GradientType = 'none' | 'brand' | 'danger';

interface SheetFrameProps {
	children: ReactNode;
}

interface SheetScreenProps {
	id: SheetId;
	title: string;
	children: ReactNode;
	titleTestID?: string;
	gradientType?: GradientType;
	contentStyle?: StyleProp<ViewStyle>;
	scrollable?: boolean;
	showBottomSafeAreaInset?: boolean;
	headerRight?: ReactNode;
	showBackButton?: boolean;
	onBackPress?: () => void;
}

interface SheetProps extends SheetFrameProps, SheetScreenProps {}

interface SheetCardProps extends SheetFrameProps {
	onBackdropPress: () => void;
	/** Lets a downward drag anywhere on the card close it, like a native sheet. */
	onDragDismiss?: () => void;
}

/**
 * Set inside a draggable SheetCard. A scroll view in the card runs alongside the
 * drag and reports its offset, so a drag only moves the card from the top of the scroll.
 */
export const SheetDragContext = createContext<{
	gesture: PanGesture;
	scrollOffset: SharedValue<number>;
} | null>(null);

const DRAG_ACTIVE_OFFSET = 10;
const DRAG_DISMISS_FRACTION = 0.25;
const DRAG_DISMISS_VELOCITY = 1000;
const DRAG_CLOSE_MS = 200;

type SheetLayoutProps = Omit<SheetScreenProps, 'id' | 'showBackButton'> & {
	/** Prefix for the back button and title test IDs. */
	id: string;
};

const gradientColors: Record<Exclude<GradientType, 'none'>, string[]> = {
	brand: ['#0085FF', '#000000'],
	danger: ['#E95164', '#000000'],
};

const useCardHeight = (): number => {
	const { height: windowHeight } = useWindowDimensions();
	const insets = useSafeAreaInsets();
	return windowHeight - insets.top - HEADER_HEIGHT;
};

const DraggableSheetCard = ({
	children,
	onBackdropPress,
	onDragDismiss,
}: SheetCardProps & { onDragDismiss: () => void }): ReactElement => {
	const cardHeight = useCardHeight();
	const offset = useSharedValue(0);
	const tracking = useSharedValue(false);
	const closing = useSharedValue(false);
	const scrollOffset = useSharedValue(0);

	const gesture = usePanGesture({
		testID: 'SheetDragPan',
		activeOffsetY: DRAG_ACTIVE_OFFSET,
		failOffsetX: [-DRAG_ACTIVE_OFFSET, DRAG_ACTIVE_OFFSET],
		onActivate: () => {
			tracking.set(!closing.get() && scrollOffset.get() <= 0);
		},
		onUpdate: event => {
			if (tracking.get()) offset.set(Math.max(0, event.translationY));
		},
		onDeactivate: event => {
			if (!tracking.get()) return;
			tracking.set(false);
			const flung = event.velocityY > DRAG_DISMISS_VELOCITY && event.translationY > 0;
			if (!event.canceled && (flung || event.translationY > cardHeight * DRAG_DISMISS_FRACTION)) {
				closing.set(true);
				offset.set(
					withTiming(cardHeight, { duration: DRAG_CLOSE_MS }, finished => {
						if (finished) scheduleOnRN(onDragDismiss);
					}),
				);
			} else {
				offset.set(withSpring(0));
			}
		},
		onFinalize: () => {
			if (!closing.get() && !tracking.get()) offset.set(withSpring(0));
		},
	});

	const cardStyle = useAnimatedStyle(() => ({ transform: [{ translateY: offset.get() }] }));
	const backdropStyle = useAnimatedStyle(() => ({
		opacity: cardHeight > 0 ? Math.max(0, 1 - offset.get() / cardHeight) : 1,
	}));
	const context = useMemo(() => ({ gesture, scrollOffset }), [gesture, scrollOffset]);

	return (
		<View style={styles.androidRoot}>
			<Animated.View style={[StyleSheet.absoluteFill, backdropStyle]}>
				<Pressable style={styles.backdrop} testID="SheetBackdrop" onPress={onBackdropPress} />
			</Animated.View>
			<GestureDetector gesture={gesture}>
				<Animated.View
					style={[styles.androidCard, { height: cardHeight }, cardStyle]}
					testID="SheetDraggableCard"
				>
					<SheetDragContext.Provider value={context}>{children}</SheetDragContext.Provider>
				</Animated.View>
			</GestureDetector>
		</View>
	);
};

/** The bottom card Android uses when it cannot present a native form sheet. */
export const SheetCard = ({ children, onBackdropPress, onDragDismiss }: SheetCardProps): ReactElement => {
	const cardHeight = useCardHeight();

	if (onDragDismiss) {
		return (
			<DraggableSheetCard onBackdropPress={onBackdropPress} onDragDismiss={onDragDismiss}>
				{children}
			</DraggableSheetCard>
		);
	}

	return (
		<View style={styles.androidRoot}>
			<Pressable style={styles.backdrop} testID="SheetBackdrop" onPress={onBackdropPress} />
			<View style={[styles.androidCard, { height: cardHeight }]}>{children}</View>
		</View>
	);
};

export const SheetFrame = ({ children }: SheetFrameProps): ReactElement => {
	if (shouldUseAndroidSheetFallback()) {
		return <SheetCard onBackdropPress={hideActiveSheet}>{children}</SheetCard>;
	}

	return <View style={styles.frame}>{children}</View>;
};

export const SheetScreen = ({
	showBackButton = true,
	onBackPress,
	...props
}: SheetScreenProps): ReactElement => {
	const navigation = useNavigation();
	const isFocused = useIsFocused();
	const hasStackScreenToGoBackTo = useNavigationState(state => {
		const isRootSheetStack = state.routeNames.some(routeName => routeName.endsWith('Sheet'));
		return !isRootSheetStack && state.index > 0;
	});
	const backPressHandler = onBackPress ?? (hasStackScreenToGoBackTo ? navigation.goBack : undefined);
	const visibleBackPressHandler = showBackButton && isFocused ? backPressHandler : undefined;

	return <SheetLayout {...props} onBackPress={visibleBackPressHandler} />;
};

/** Sheet chrome without navigation: the back button shows only when onBackPress is set. */
export const SheetLayout = ({
	id,
	title: titleText,
	children,
	titleTestID,
	gradientType = 'none',
	contentStyle,
	scrollable = false,
	showBottomSafeAreaInset = true,
	headerRight,
	onBackPress: visibleBackPressHandler,
}: SheetLayoutProps): ReactElement => {
	const titleHeader = (
		<View style={styles.titleContainer}>
			{visibleBackPressHandler ? (
				<HeaderNavButton
					style={styles.navButton}
					testID={`${id}-back-button`}
					onPress={visibleBackPressHandler}
				>
					<ArrowLeft />
				</HeaderNavButton>
			) : (
				<HeaderNavButton style={styles.navButton} />
			)}

			<TextLgSb
				style={styles.title}
				testID={titleTestID ?? `${id}-title`}
				numberOfLines={1}
				ellipsizeMode="tail"
			>
				{titleText}
			</TextLgSb>

			<View style={styles.navButton}>{headerRight}</View>
		</View>
	);

	return (
		<LinearGradient colors={['#1D1D20', '#000000']}>
			{gradientType !== 'none' && (
				<RadialGradient style={styles.background} radius={0.7} colors={gradientColors[gradientType]} />
			)}

			<ThemedView style={styles.indicator} colorName="muted" />

			{scrollable ? (
				<ScrollView
					style={styles.scroll}
					contentContainerStyle={styles.scrollContent}
					keyboardShouldPersistTaps="handled"
					automaticallyAdjustKeyboardInsets
				>
					{titleHeader}
					<View style={[styles.scrollBody, contentStyle]}>
						{children}
						{showBottomSafeAreaInset && <SafeAreaInset edge="bottom" />}
					</View>
				</ScrollView>
			) : (
				<>
					{titleHeader}
					<View style={[styles.content, contentStyle]}>{children}</View>
					{showBottomSafeAreaInset && <SafeAreaInset edge="bottom" />}
				</>
			)}
		</LinearGradient>
	);
};

const Sheet = ({ id, children, ...screenProps }: SheetProps): ReactElement => {
	return (
		<SheetFrame>
			<SheetScreen id={id} {...screenProps}>
				{children}
			</SheetScreen>
		</SheetFrame>
	);
};

const styles = StyleSheet.create({
	frame: {
		// iOS fixed detents provide the content size with screens' synchronous updates.
		// Let that native size drive layout instead of calculating a second sheet height.
		...Platform.select({ ios: { flex: 1 }, default: { height: '100%' as const } }),
		backgroundColor: '#000000',
	},
	androidRoot: {
		flex: 1,
		justifyContent: 'flex-end',
	},
	backdrop: {
		...StyleSheet.absoluteFill,
		backgroundColor: 'rgba(0, 0, 0, 0.5)',
	},
	androidCard: {
		backgroundColor: '#000000',
		borderTopLeftRadius: 32,
		borderTopRightRadius: 32,
		overflow: 'hidden',
	},
	background: {
		...StyleSheet.absoluteFill,
		opacity: 0.2,
	},
	indicator: {
		alignSelf: 'center',
		width: 60,
		height: 6,
		marginTop: 16,
		marginBottom: 24,
		borderRadius: 3,
	},
	titleContainer: {
		flexDirection: 'row',
		justifyContent: 'space-between',
		alignItems: 'center',
		height: 24,
		paddingHorizontal: 16,
		marginBottom: 24,
	},
	title: {
		flex: 1,
		minWidth: 0,
		marginHorizontal: 8,
		textAlign: 'center',
	},
	navButton: {
		height: 24,
		width: 24,
		alignItems: 'center',
		justifyContent: 'center',
	},
	content: {
		flex: 1,
		paddingHorizontal: 24,
		overflow: 'hidden',
	},
	scroll: {
		flex: 1,
	},
	scrollContent: {
		flexGrow: 1,
	},
	scrollBody: {
		flex: 1,
		paddingHorizontal: 24,
	},
});

export default memo(Sheet);
