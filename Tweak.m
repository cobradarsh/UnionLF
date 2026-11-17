/*
 * IWantTranslucent Lean: the context menus of iOS 16 without their blur and without separators,
 * and nothing else running anywhere.
 *
 * This file is a modified version of Tweak.m from IWantTranslucent 0.9.4 by Luki120
 *   https://github.com/Luki120/SmallTweaks/tree/main/SpringBoard/IWantTranslucent
 * (commit 9b5e4d09, kept unchanged in upstream/). What it does to the menus is the same; how it
 * gets there is not. README.md has the list of changes and what they were measured to save.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Private classes, declared only so that their selectors can be named. None is referenced as a
// symbol: every class is looked up by name when the library loads and skipped when it is missing.
@interface _UIContextMenuHeaderView : UICollectionReusableView
@property (nonatomic, strong) UIVisualEffectView *bgView;
- (double)_separatorHeight;
@end

@interface MRUNowPlayingContainerView : UIView
@property (nonatomic, strong) UIView *separatorView;
@end


#pragma mark - A view that cannot be shown

// Handed out in place of the separator of the AirPlay list's rows (see IWTInertSeparator).
// Whatever its new owner does with it (frame, colour, hidden = NO), it stays out of sight.
@interface IWantTranslucentInertView : UIView
@end

@implementation IWantTranslucentInertView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) [super setHidden:YES];
	return self;
}

- (void)setHidden:(BOOL)hidden {
	[super setHidden:YES];
}

@end


#pragma mark - Context menus

// The menu's background at half opacity. A blur view that is not fully opaque stops blurring,
// which is the whole trick: what is behind the menu shows through, dimmed and sharp. Runs once
// for each menu (and once for each submenu), when its list view is given its background.
static void (*IWTOrigSetBackgroundView)(id, SEL, UIView *);
static void IWTSetBackgroundView(id self, SEL _cmd, UIView *backgroundView) {
	IWTOrigSetBackgroundView(self, _cmd, backgroundView);
	backgroundView.alpha = 0.5;
}

// The thick bar between two groups of actions is a plain UICollectionReusableView, so it has no
// class of its own to hook. The original tweak therefore added -didMoveToWindow to
// UICollectionReusableView itself: every cell of every collection view in every app then asked
// UIDevice for the iOS version, parsed it and compared reuse identifiers, each time it entered
// or left a window. Here the menu's own list view, which is its collection view's delegate, is
// told when a supplementary view is about to be shown. Only menus ever reach this function.
static void (*IWTOrigWillDisplaySupplementary)(id, SEL, UICollectionView *, UICollectionReusableView *, NSString *, NSIndexPath *);
static void IWTWillDisplaySupplementary(id self, SEL _cmd, UICollectionView *collectionView, UICollectionReusableView *view,
                                        NSString *kind, NSIndexPath *indexPath) {
	if (IWTOrigWillDisplaySupplementary) IWTOrigWillDisplaySupplementary(self, _cmd, collectionView, view, kind, indexPath);
	if (![kind isEqualToString:@"kContextMenuSectionSeparator"]) return;
	view.hidden = YES;
	// On iOS 16.5 the bar is nothing but a background colour, given to it just before this call
	// (-[_UIContextMenuListView _dataSourceForCollectionView:], second block). A collection view
	// un-hides a view it takes back into use; without its colour the bar has nothing to show then.
	view.backgroundColor = nil;
}

// The hairline between two actions. The original took each one out of its collection view from
// inside -didMoveToWindow, which sends the collection view round its layout once more for every
// menu. Here the line stays where the collection view put it, hidden and with nothing in it to
// draw: the same picture, and the collection view's books stay right.
static void (*IWTOrigSeparatorDidMoveToWindow)(id, SEL);
static void IWTSeparatorDidMoveToWindow(UIView *self, SEL _cmd) {
	IWTOrigSeparatorDidMoveToWindow(self, _cmd);
	if (!self.window) return;
	self.hidden = YES;
	// "hidden" belongs to the layout attributes too and may be set back; an empty view cannot be seen either way
	self.backgroundColor = nil;
	for (UIView *subview in self.subviews) subview.hidden = YES;
}

// The title on top of a menu: no blur of its own behind it, no line under it.
static void (*IWTOrigHeaderDidMoveToWindow)(id, SEL);
static void IWTHeaderDidMoveToWindow(_UIContextMenuHeaderView *self, SEL _cmd) {
	IWTOrigHeaderDidMoveToWindow(self, _cmd);
	if (self.window) self.bgView.hidden = YES;
}

static double IWTNoSeparatorHeight(id self, SEL _cmd) {
	return 0;
}


#pragma mark - Control Centre

// The line in the expanded music module.
static void (*IWTOrigNowPlayingDidMoveToWindow)(id, SEL);
static void IWTNowPlayingDidMoveToWindow(MRUNowPlayingContainerView *self, SEL _cmd) {
	IWTOrigNowPlayingDidMoveToWindow(self, _cmd);
	[self.separatorView removeFromSuperview];
}

// The rows and headers of the AirPlay list reach their separator through this getter. The
// original answered with a brand-new UIView on every call, so each layout pass made and threw
// away a handful of views. Each row now keeps one view that cannot be shown and hands out that.
static const char IWTInertSeparatorKey = 0;
static UIView *IWTInertSeparator(id self, SEL _cmd) {
	UIView *view = objc_getAssociatedObject(self, &IWTInertSeparatorKey);
	if (!view) {
		view = [IWantTranslucentInertView new];
		objc_setAssociatedObject(self, &IWTInertSeparatorKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return view;
}


#pragma mark - Putting the functions in place

// Method type strings carry stack offsets ("v24@0:8@16"); only the types are compared.
static BOOL IWTSameTypes(const char *a, const char *b) {
	for (;;) {
		while (*a >= '0' && *a <= '9') a++;
		while (*b >= '0' && *b <= '9') b++;
		if (*a != *b) return NO;
		if (*a == '\0') return YES;
		a++;
		b++;
	}
}

// Makes `replacement` what -[cls sel] runs, with the Objective-C runtime alone: no hooking
// library is linked, so an app that loads no other tweak loads only this one small file.
// `original` receives what ran before (the class's own method, or the one it inherited) and is
// written first, so the replacement never runs without it. Nothing is changed, and NO returned,
// when the class or the method is missing or the method's types are not the expected ones.
static BOOL IWTInstall(Class cls, SEL sel, IMP replacement, const char *types, IMP *original) {
	if (!cls) return NO;
	Method method = class_getInstanceMethod(cls, sel);
	if (!method) return NO;
	const char *encoding = method_getTypeEncoding(method);
	if (!encoding || !IWTSameTypes(encoding, types)) return NO;
	if (original) *original = method_getImplementation(method);
	// adding succeeds only when the method was inherited; otherwise the class's own one is swapped
	if (!class_addMethod(cls, sel, replacement, encoding)) method_setImplementation(method, replacement);
	return YES;
}

__attribute__((constructor)) static void IWTLoad(void) {
	// One lookup by name for each class: objc_lookUpClass does not go looking for a class that is
	// not there, and nothing here asks UIDevice which iOS this is. A class or method that iOS 16
	// does not have is left alone.
	Class list = objc_lookUpClass("_UIContextMenuListView");
	if (list) {
		IWTInstall(list, @selector(setBackgroundView:), (IMP)IWTSetBackgroundView, "v@:@", (IMP *)&IWTOrigSetBackgroundView);

		SEL willDisplay = @selector(collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:);
		if (class_getInstanceMethod(list, willDisplay)) {
			IWTInstall(list, willDisplay, (IMP)IWTWillDisplaySupplementary, "v@:@@@@", (IMP *)&IWTOrigWillDisplaySupplementary);
		} else {
			class_addMethod(list, willDisplay, (IMP)IWTWillDisplaySupplementary, "v48@0:8@16@24@32@40");
		}
	}

	IWTInstall(objc_lookUpClass("_UIContextMenuReusableSeparatorView"), @selector(didMoveToWindow),
	           (IMP)IWTSeparatorDidMoveToWindow, "v@:", (IMP *)&IWTOrigSeparatorDidMoveToWindow);

	Class header = objc_lookUpClass("_UIContextMenuHeaderView");
	if (header) {
		if (class_getInstanceMethod(header, @selector(bgView))) {
			IWTInstall(header, @selector(didMoveToWindow), (IMP)IWTHeaderDidMoveToWindow, "v@:", (IMP *)&IWTOrigHeaderDidMoveToWindow);
		}
		IWTInstall(header, @selector(_separatorHeight), (IMP)IWTNoSeparatorHeight, "d@:", NULL);
	}

	// Control Centre's classes exist in SpringBoard and in the few services that show its panels.
	IWTInstall(objc_lookUpClass("CCUIMenuModuleItemView"), @selector(_separatorHeight), (IMP)IWTNoSeparatorHeight, "d@:", NULL);

	Class nowPlaying = objc_lookUpClass("MRUNowPlayingContainerView");
	if (nowPlaying && class_getInstanceMethod(nowPlaying, @selector(separatorView))) {
		IWTInstall(nowPlaying, @selector(didMoveToWindow), (IMP)IWTNowPlayingDidMoveToWindow, "v@:", (IMP *)&IWTOrigNowPlayingDidMoveToWindow);
	}
	IWTInstall(objc_lookUpClass("MRURoutingHeaderView"), @selector(separatorView), (IMP)IWTInertSeparator, "@@:", NULL);
	IWTInstall(objc_lookUpClass("MRURoutingTableViewCell"), @selector(separatorView), (IMP)IWTInertSeparator, "@@:", NULL);
}
