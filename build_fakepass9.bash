#!/usr/bin/env bash
# ============================================================================
# build_fakepass9.sh (全内置自包含版)
# 一键生成并编译 iPhone 6s / 6s Plus (iOS 9.0 - 9.1) 防白苹果伪锁屏密码插件 FakePass9
#
# 使用方法 (在安装了 Theos 的 Mac 终端中运行)：
#   chmod +x build_fakepass9.sh && ./build_fakepass9.sh
#
# 编译完成后会在 ./FakePass9/packages/ 目录下生成可安装的 .deb 安装包。
# ============================================================================

set -e

PROJECT_DIR="./FakePass9"
mkdir -p "$PROJECT_DIR"

echo "[1/4] 正在生成 Theos 工程配置文件 (Makefile, control, FakePass9.plist)..."

cat << 'EOF_MAKEFILE' > "$PROJECT_DIR/Makefile"
TARGET := iphone:clang:latest:9.0
ARCHS := armv7 arm64
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FakePass9
FakePass9_FILES = Tweak.xm
FakePass9_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FakePass9_FRAMEWORKS = UIKit Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
EOF_MAKEFILE

cat << 'EOF_CONTROL' > "$PROJECT_DIR/control"
Package: com.legacy.fakepass9
Name: FakePass9 (6s iOS 9.0/9.1 防白苹果密码锁)
Depends: mobilesubstrate (>= 0.9.5000), firmware (>= 9.0), firmware (<< 10.0)
Version: 1.0.0
Architecture: iphoneos-arm
Description: 专为 iPhone 6s / 6s Plus (iOS 9.0-9.1 + 12.00.00 基带) 打造的原生级伪锁屏密码插件。拦截系统密码设置并保存在应用层，不触发底层 SEP / AppleKeyStore 加密，彻底解决设置密码后开机白苹果无限重启问题。
Maintainer: Legacy iOS Maintain Team
Author: Legacy iOS Maintain Team (Based on FakePass MIT)
Section: Tweaks
EOF_CONTROL

cat << 'EOF_PLIST' > "$PROJECT_DIR/FakePass9.plist"
{
    Filter = {
        Bundles = (
            "com.apple.springboard",
            "com.apple.Preferences"
        );
    };
}
EOF_PLIST

echo "[2/4] 正在写入 FakePass9 核心源码 ($PROJECT_DIR/Tweak.xm)..."
cat << 'EOF_TWEAK_XM' > "$PROJECT_DIR/Tweak.xm"
// ============================================================================
// FakePass9_Tweak.xm
// 专为 iPhone 6s / 6s Plus (A9) iOS 9.0 - 9.1 (12.00.00 基带) 定制的原生级伪锁屏密码插件
//
// 核心原理与设计目标：
// 1. 彻底阻断白苹果重启死循环 (BLoD)：
//    拦截系统“设置 -> Touch ID 与密码”中的 MCProfileConnection 密码写入请求，
//    绝不调用底层 SEP / AppleKeyStore 加密 /private/var 分区，使系统在硬件与内核层
//    始终保持“未设密码 (No Passcode / Class D)”状态，从根源消除 iOS 9.0/9.1 开机
//    BeforeFirstUnlock 阶段因 12.00.00 基带与 SEP 密钥袋冲突引发的白苹果无限重启。
// 2. 100% 原生 iOS 9 锁屏数字密码体验：
//    Hook SpringBoard 与 SpringBoardFoundation 的锁屏状态机 (SBLockScreenManager、
//    SBDeviceLockController、SBFMobileKeyBag、SBFUserAuthenticationController)，
//    在锁屏滑动时调出系统原装 4 位 / 6 位 / 自定义数字或字母密码键盘。
// 3. 零第三方库依赖 (移除原版 FakePass 的 iOS 14+ libSandy 依赖)：
//    采用原子级 NSDictionary 文件读写 + Darwin 跨进程通知同步，完美兼容 iOS 9.0 - 9.3.5
//    (Pangu9 / kok3shi9 越狱环境)。
// 4. 安全防误抹机保护：
//    内置输错 6 次起读秒停用逻辑，并强制拦截输错 10 次触发的 SBDataReset 抹掉所有内容，
//    防止因误触抹机导致 Pangu9 越狱丢失或掉激活。
//
// 开源致谢：基于 alexia / lunaynx 的 FakePass (MIT License) 架构面向 iOS 9 深度重构。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <notify.h>
#include <spawn.h>
#include <sys/stat.h>

extern char **environ;

#define FAKEPASS9_PREFS_PATH @"/var/mobile/Library/Preferences/com.legacy.fakepass9.plist"
#define FAKEPASS9_NOTIFY_NAME "com.legacy.fakepass9.prefsChanged"

// ----------------------------------------------------------------------------
// iOS 9 私有框架接口声明 (SpringBoard / SpringBoardFoundation / Preferences)
// ----------------------------------------------------------------------------

@interface MCPasscodeManager : NSObject
- (BOOL)isPasscodeSet;
@end

@interface MCProfileConnection : NSObject
+ (instancetype)sharedConnection;
- (BOOL)isPasscodeSet;
- (BOOL)changePasscodeFrom:(NSString *)oldPasscode to:(NSString *)newPasscode outError:(NSError **)outError;
- (BOOL)unlockDeviceWithPasscode:(NSString *)passcode outError:(NSError **)outError;
- (id)effectiveValueForSetting:(NSString *)setting;
- (void)setValue:(id)value forSetting:(NSString *)setting passcode:(NSString *)passcode;
@end

@interface DevicePINController : UIViewController
- (int)pinLength;
- (BOOL)isNumericPIN;
- (BOOL)simplePIN;
@end

@interface DevicePINPane : UIView
- (void)slideToNewPasscodeField:(BOOL)fixedLength
               requiresKeyboard:(BOOL)requiresKeyboard
                    numericOnly:(BOOL)numericOnly
                     transition:(BOOL)transition
             showsOptionsButton:(BOOL)showsOptionsButton;
@end

@interface SBFDeviceLockOutController : NSObject
- (BOOL)isPermanentlyBlocked;
- (BOOL)isTemporarilyBlocked;
- (void)temporaryBlockStatusChanged;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
- (void)lockUIFromSource:(int)source withOptions:(id)options;
- (void)unlockUIFromSource:(int)source withOptions:(id)options;
- (BOOL)attemptUnlockWithPasscode:(NSString *)passcode;
- (void)lockScreenViewControllerRequestsUnlock;
- (SBFDeviceLockOutController *)_lockOutController;
@end

@interface SBDeviceLockController : NSObject
+ (instancetype)sharedController;
- (BOOL)isPasscodeLocked;
- (BOOL)isPasscodeLockedCached;
- (BOOL)isPasscodeLockedOrBlocked;
- (BOOL)deviceHasPasscodeSet;
- (BOOL)isBlocked;
- (BOOL)_temporarilyBlocked;
- (BOOL)attemptDeviceUnlockWithPassword:(NSString *)password appRequested:(BOOL)requested;
@end

@interface SBFDeviceLockController : NSObject
- (BOOL)isPasscodeLocked;
- (BOOL)isPasscodeLockedCached;
- (BOOL)isPasscodeLockedOrBlocked;
- (BOOL)deviceHasPasscodeSet;
- (BOOL)attemptDeviceUnlockWithPassword:(NSString *)password appRequested:(BOOL)requested;
@end

@interface SBFMobileKeyBag : NSObject
+ (instancetype)sharedInstance;
- (BOOL)hasPasscodeSet;
- (BOOL)unlockWithPasscode:(NSString *)passcode error:(NSError **)error;
@end

@interface SBFMobileKeyBagState : NSObject
- (NSInteger)lockState;
- (BOOL)isEffectivelyLocked;
@end

@interface SBFUserAuthenticationController : NSObject
- (BOOL)isAuthenticated;
- (BOOL)isAuthenticatedCached;
- (BOOL)hasPasscodeSet;
@end

// ----------------------------------------------------------------------------
// 全局状态变量
// ----------------------------------------------------------------------------

static NSMutableDictionary *gPrefs = nil;
static BOOL gIsUnlocked = NO;
static BOOL gCreatingPasscode = NO;
static NSTimeInterval gLastLockTime = 0;

// ----------------------------------------------------------------------------
// 工具函数：加盐 SHA-256 哈希、原子级配置读写、安全注销 (Respring)
// ----------------------------------------------------------------------------

static void loadPrefsFromDisk(void) {
    NSDictionary *diskDict = [NSDictionary dictionaryWithContentsOfFile:FAKEPASS9_PREFS_PATH];
    if (diskDict) {
        gPrefs = [diskDict mutableCopy];
    } else if (!gPrefs) {
        gPrefs = [[NSMutableDictionary alloc] init];
    }
    if ([gPrefs objectForKey:@"lockOnRespring"] == nil) {
        gPrefs[@"lockOnRespring"] = @YES;
    }
    if ([gPrefs objectForKey:@"maxGracePeriod"] == nil) {
        gPrefs[@"maxGracePeriod"] = @0;
    }
}

static void savePrefsToDisk(void) {
    if (!gPrefs) return;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:gPrefs
                                                                   format:NSPropertyListBinaryFormat_v1_0
                                                                  options:0
                                                                    error:nil];
    if (plistData) {
        [plistData writeToFile:FAKEPASS9_PREFS_PATH atomically:YES];
        chmod([FAKEPASS9_PREFS_PATH UTF8String], 0644);
    }
    notify_post(FAKEPASS9_NOTIFY_NAME);
}

static NSString *generateRandomSalt(void) {
    NSString * const chars = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    NSMutableString *salt = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 16; i++) {
        uint32_t idx = arc4random_uniform((uint32_t)[chars length]);
        [salt appendFormat:@"%C", [chars characterAtIndex:idx]];
    }
    return salt;
}

static NSString *computeSaltedHash(NSString *passcode, NSString *salt) {
    if (!passcode || !salt) return @"";
    NSString *combined = [NSString stringWithFormat:@"%@::FakePass9::%@", salt, passcode];
    const char *cstr = [combined UTF8String];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static void triggerRespring(void) {
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char * const *)args, environ);
}

static BOOL isFakePasscodeSet(void) {
    if (!gPrefs) loadPrefsFromDisk();
    NSString *hash = gPrefs[@"passcodeHash"];
    return (hash != nil && [hash length] > 0);
}

static BOOL verifyPasscodeString(NSString *inputPasscode) {
    if (!inputPasscode) return NO;
    loadPrefsFromDisk();
    NSString *savedHash = gPrefs[@"passcodeHash"];
    NSString *savedSalt = gPrefs[@"passcodeSalt"];
    if (!savedHash || !savedSalt || [savedHash length] == 0) return YES;
    NSString *candidateHash = computeSaltedHash(inputPasscode, savedSalt);
    return [candidateHash isEqualToString:savedHash];
}

// 计算当前是否处于多次输错密码后的读秒停用状态
static NSTimeInterval remainingLockoutSeconds(void) {
    if (!isFakePasscodeSet()) return 0;
    NSInteger failedAttempts = [gPrefs[@"failedAttempts"] integerValue];
    NSTimeInterval blockStart = [gPrefs[@"blockTime"] doubleValue];
    if (failedAttempts < 6 || blockStart <= 0) return 0;

    NSTimeInterval duration = 0;
    if (failedAttempts >= 9) {
        duration = 3600; // 60 分钟 (封顶，不触发抹机)
    } else if (failedAttempts == 8) {
        duration = 900;  // 15 分钟
    } else if (failedAttempts == 7) {
        duration = 300;  // 5 分钟
    } else if (failedAttempts == 6) {
        duration = 60;   // 1 分钟
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval rem = (blockStart + duration) - now;
    return (rem > 0) ? rem : 0;
}

static BOOL handlePasscodeUnlockAttempt(NSString *passcode) {
    if (remainingLockoutSeconds() > 0) {
        return NO;
    }
    if (verifyPasscodeString(passcode)) {
        gIsUnlocked = YES;
        [gPrefs removeObjectForKey:@"blockTime"];
        gPrefs[@"failedAttempts"] = @0;
        savePrefsToDisk();
        return YES;
    } else {
        NSInteger failed = [gPrefs[@"failedAttempts"] integerValue] + 1;
        gPrefs[@"failedAttempts"] = @(failed);
        if (failed >= 6) {
            gPrefs[@"blockTime"] = @([[NSDate date] timeIntervalSince1970]);
            SBLockScreenManager *lsMgr = [%c(SBLockScreenManager) sharedInstance];
            if ([lsMgr respondsToSelector:@selector(_lockOutController)]) {
                SBFDeviceLockOutController *lockOut = [lsMgr _lockOutController];
                if (lockOut && [lockOut respondsToSelector:@selector(temporaryBlockStatusChanged)]) {
                    [lockOut temporaryBlockStatusChanged];
                }
            }
        }
        savePrefsToDisk();
        return NO;
    }
}

// ----------------------------------------------------------------------------
// 1. 拦截“设置 -> Touch ID 与密码” (Preferences.app / ManagedConfiguration)
//    阻止密码写入真实 SEP / AppleKeyStore，将其安全转存至 FakePass9 配置
// ----------------------------------------------------------------------------

%hook MCPasscodeManager

- (BOOL)isPasscodeSet {
    return isFakePasscodeSet();
}

%end

%hook MCProfileConnection

- (BOOL)isPasscodeSet {
    return isFakePasscodeSet();
}

- (BOOL)changePasscodeFrom:(NSString *)oldPasscode to:(NSString *)newPasscode outError:(NSError **)outError {
    gCreatingPasscode = NO;
    loadPrefsFromDisk();

    // 校验旧密码
    if (oldPasscode.length > 0 && isFakePasscodeSet() && !verifyPasscodeString(oldPasscode)) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"com.legacy.fakepass9" code:-1 userInfo:nil];
        }
        return NO;
    }

    if (newPasscode && newPasscode.length > 0) {
        NSString *salt = generateRandomSalt();
        NSString *hash = computeSaltedHash(newPasscode, salt);
        gPrefs[@"passcodeSalt"] = salt;
        gPrefs[@"passcodeHash"] = hash;
        gPrefs[@"failedAttempts"] = @0;
        [gPrefs removeObjectForKey:@"blockTime"];

        // 识别密码类型：0 = 4位数字, 1 = 6位数字, 2 = 自定义长度数字, 3 = 字母数字混合
        NSInteger passcodeType = 3;
        NSRange numRange = [newPasscode rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch];
        if (numRange.location != NSNotFound) {
            if (newPasscode.length == 4) {
                passcodeType = 0;
            } else if (newPasscode.length == 6) {
                passcodeType = 1;
            } else {
                passcodeType = 2;
            }
        }
        gPrefs[@"passcodeType"] = @(passcodeType);
        savePrefsToDisk();

        // 首次开启密码时自动注销 SpringBoard 使锁屏状态机立即生效
        if (!oldPasscode || oldPasscode.length == 0) {
            triggerRespring();
        }
    } else {
        // 用户点击“关闭密码”
        [gPrefs removeObjectForKey:@"passcodeHash"];
        [gPrefs removeObjectForKey:@"passcodeSalt"];
        [gPrefs removeObjectForKey:@"passcodeType"];
        [gPrefs removeObjectForKey:@"blockTime"];
        gPrefs[@"failedAttempts"] = @0;
        savePrefsToDisk();
    }

    // 关键：直接返回 YES，绝不调用 %orig，从而彻底隔绝 SEP / AppleKeyStore 加密！
    return YES;
}

- (BOOL)unlockDeviceWithPasscode:(NSString *)passcode outError:(NSError **)outError {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return verifyPasscodeString(passcode);
}

- (id)effectiveValueForSetting:(NSString *)setting {
    if (isFakePasscodeSet() && [setting isEqualToString:@"maxGracePeriod"]) {
        loadPrefsFromDisk();
        if (gPrefs[@"maxGracePeriod"] != nil) {
            return gPrefs[@"maxGracePeriod"];
        }
    }
    return %orig;
}

- (void)setValue:(id)value forSetting:(NSString *)setting passcode:(NSString *)passcode {
    if ([setting isEqualToString:@"maxGracePeriod"]) {
        loadPrefsFromDisk();
        gPrefs[@"maxGracePeriod"] = @([value integerValue]);
        savePrefsToDisk();
    }
    if (!isFakePasscodeSet()) {
        %orig;
    }
}

%end

// 适配系统设置中密码输入框的位数与键盘样式 (4位 / 6位 / 自定义数字 / 字母)
%hook DevicePINController

- (int)pinLength {
    if (!isFakePasscodeSet() || gCreatingPasscode) {
        return %orig;
    }
    loadPrefsFromDisk();
    NSInteger type = [gPrefs[@"passcodeType"] integerValue];
    if (type == 0) return 4;
    if (type == 1) return 6;
    return %orig;
}

- (BOOL)isNumericPIN {
    if (!isFakePasscodeSet() || gCreatingPasscode) {
        return %orig;
    }
    loadPrefsFromDisk();
    return ([gPrefs[@"passcodeType"] integerValue] < 3);
}

- (BOOL)simplePIN {
    if (!isFakePasscodeSet() || gCreatingPasscode) {
        return %orig;
    }
    loadPrefsFromDisk();
    return ([gPrefs[@"passcodeType"] integerValue] < 2);
}

%end

%hook DevicePINPane

- (void)slideToNewPasscodeField:(BOOL)fixedLength
               requiresKeyboard:(BOOL)requiresKeyboard
                    numericOnly:(BOOL)numericOnly
                     transition:(BOOL)transition
             showsOptionsButton:(BOOL)showsOptionsButton {
    gCreatingPasscode = YES;
    %orig;
}

%end

// 在“设置 -> Touch ID 与密码”界面顶部显示“(FakePass9 防白苹果保护)”标识
%hook NSBundle

- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)tableName {
    NSString *origStr = %orig;
    if ([self.bundleIdentifier isEqualToString:@"com.apple.preferences-ui-framework"] &&
        [tableName isEqualToString:@"Passcode Lock"] &&
        [key isEqualToString:@"PASSCODE_ON"]) {
        return [NSString stringWithFormat:@"%@ (FakePass9 防白苹果保护)", origStr];
    }
    return origStr;
}

%end

// ----------------------------------------------------------------------------
// 2. 接管 iOS 9.0 / 9.1 SpringBoard 锁屏状态机与原生数字密码盘校验
// ----------------------------------------------------------------------------

%hook SBFMobileKeyBag

- (BOOL)hasPasscodeSet {
    if (isFakePasscodeSet()) return YES;
    return %orig;
}

- (BOOL)unlockWithPasscode:(NSString *)passcode error:(NSError **)error {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return handlePasscodeUnlockAttempt(passcode);
}

%end

%hook SBFMobileKeyBagState

- (NSInteger)lockState {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return gIsUnlocked ? 0 : 2;
}

- (BOOL)isEffectivelyLocked {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return !gIsUnlocked;
}

%end

%hook SBFUserAuthenticationController

- (BOOL)hasPasscodeSet {
    if (isFakePasscodeSet()) return YES;
    return %orig;
}

- (BOOL)isAuthenticated {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return gIsUnlocked;
}

- (BOOL)isAuthenticatedCached {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return gIsUnlocked;
}

%end

// 兼容 iOS 9.0 / 9.1 核心锁屏控制器 SBDeviceLockController 与 SBFDeviceLockController
%hook SBDeviceLockController

- (BOOL)deviceHasPasscodeSet {
    if (isFakePasscodeSet()) return YES;
    return %orig;
}

- (BOOL)isPasscodeLocked {
    if (!isFakePasscodeSet()) return %orig;
    return !gIsUnlocked;
}

- (BOOL)isPasscodeLockedCached {
    if (!isFakePasscodeSet()) return %orig;
    return !gIsUnlocked;
}

- (BOOL)isPasscodeLockedOrBlocked {
    if (!isFakePasscodeSet()) return %orig;
    return (!gIsUnlocked || remainingLockoutSeconds() > 0);
}

- (BOOL)isBlocked {
    if (!isFakePasscodeSet()) return %orig;
    return (remainingLockoutSeconds() > 0);
}

- (BOOL)_temporarilyBlocked {
    if (!isFakePasscodeSet()) return %orig;
    return (remainingLockoutSeconds() > 0);
}

- (BOOL)attemptDeviceUnlockWithPassword:(NSString *)password appRequested:(BOOL)requested {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return handlePasscodeUnlockAttempt(password);
}

%end

%hook SBFDeviceLockController

- (BOOL)deviceHasPasscodeSet {
    if (isFakePasscodeSet()) return YES;
    return %orig;
}

- (BOOL)isPasscodeLocked {
    if (!isFakePasscodeSet()) return %orig;
    return !gIsUnlocked;
}

- (BOOL)isPasscodeLockedCached {
    if (!isFakePasscodeSet()) return %orig;
    return !gIsUnlocked;
}

- (BOOL)isPasscodeLockedOrBlocked {
    if (!isFakePasscodeSet()) return %orig;
    return (!gIsUnlocked || remainingLockoutSeconds() > 0);
}

- (BOOL)attemptDeviceUnlockWithPassword:(NSString *)password appRequested:(BOOL)requested {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    return handlePasscodeUnlockAttempt(password);
}

%end

%hook SBLockScreenManager

- (BOOL)attemptUnlockWithPasscode:(NSString *)passcode {
    if (!isFakePasscodeSet()) {
        return %orig;
    }
    if (handlePasscodeUnlockAttempt(passcode)) {
        [self unlockUIFromSource:0 withOptions:nil];
        return YES;
    }
    return NO;
}

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    if (isFakePasscodeSet()) {
        gIsUnlocked = NO;
        gLastLockTime = [[NSDate date] timeIntervalSince1970];
    }
    %orig;
}

- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    if (isFakePasscodeSet() && !gIsUnlocked) {
        loadPrefsFromDisk();
        NSTimeInterval grace = [gPrefs[@"maxGracePeriod"] doubleValue];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (gLastLockTime > 0 && grace > 0 && (gLastLockTime + grace) > now) {
            gIsUnlocked = YES;
        }
    }
    %orig;
}

%end

// 拦截输错密码停用计时器与防误抹机保护
%hook SBFDeviceLockOutController

- (BOOL)isTemporarilyBlocked {
    if (!isFakePasscodeSet()) return %orig;
    return (remainingLockoutSeconds() > 0);
}

- (BOOL)isPermanentlyBlocked {
    // 强制返回 NO，严禁触发 iOS 9 的抹掉所有内容和设置 (防止破坏越狱与激活文件)
    if (isFakePasscodeSet()) return NO;
    return %orig;
}

%end

%hook SBFDeviceBlockTimer

- (NSString *)subtitleText {
    if (!isFakePasscodeSet()) return %orig;
    NSTimeInterval rem = remainingLockoutSeconds();
    if (rem <= 0) return %orig;
    NSInteger mins = (NSInteger)ceil(rem / 60.0);
    return [NSString stringWithFormat:@"请 %ld 分钟后再试", (long)mins];
}

%end

// 匹配锁屏密码键盘样式 (4位黑点 / 6位黑点 / 数字键盘 / 全键盘)
%hookf(NSInteger, SBUICurrentPasscodeStyleForUser) {
    if (!isFakePasscodeSet() || gCreatingPasscode) {
        return %orig;
    }
    loadPrefsFromDisk();
    return [gPrefs[@"passcodeType"] integerValue];
}

// ----------------------------------------------------------------------------
// 3. 构造函数：仅注入 SpringBoard 与 Preferences，并注册配置热重载通知
// ----------------------------------------------------------------------------

static void reloadPrefsNotificationCallback(CFNotificationCenterRef center,
                                            void *observer,
                                            CFStringRef name,
                                            const void *object,
                                            CFDictionaryRef userInfo) {
    loadPrefsFromDisk();
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID) return;
        if (![bundleID isEqualToString:@"com.apple.springboard"] &&
            ![bundleID isEqualToString:@"com.apple.Preferences"]) {
            return;
        }

        loadPrefsFromDisk();
        gIsUnlocked = !isFakePasscodeSet() || ![gPrefs[@"lockOnRespring"] boolValue];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            reloadPrefsNotificationCallback,
            CFSTR(FAKEPASS9_NOTIFY_NAME),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        void *sbUIServices = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardUIServices.framework/SpringBoardUIServices",
            RTLD_LAZY
        );
        void *sym = sbUIServices ? dlsym(sbUIServices, "SBUICurrentPasscodeStyleForUser") : NULL;
        if (sym) {
            %init(SBUICurrentPasscodeStyleForUser = sym);
        } else {
            %init;
        }
    }
}
EOF_TWEAK_XM

echo "[3/4] 检查本机 Theos 编译环境..."
if [ -z "$THEOS" ]; then
    if [ -d "/opt/theos" ]; then
        export THEOS="/opt/theos"
    elif [ -d "$HOME/theos" ]; then
        export THEOS="$HOME/theos"
    else
        echo "----------------------------------------------------------------"
        echo "工程全部源码与配置文件已生成至: $PROJECT_DIR/"
        echo "当前终端尚未设置 \$THEOS 环境变量。若你已在 Mac 上安装 Theos，请执行："
        echo "  export THEOS=~/theos   # 或你的 Theos 实际路径"
        echo "  cd FakePass9 && make package FINALPACKAGE=1"
        echo "----------------------------------------------------------------"
        exit 0
    fi
fi

echo "[4/4] 正在调用 Theos 编译打包 .deb ..."
cd "$PROJECT_DIR"
make clean
make package FINALPACKAGE=1

echo "================================================================"
echo "编译完成！生成的 .deb 安装包位于: $PROJECT_DIR/packages/"
echo ""
echo "【手机端安装与使用步骤】："
echo "  1. 确保 6s/6s+ (iOS 9.0/9.1) 当前处于“未设置系统锁屏密码”状态并已完成 Pangu9 越狱"
echo "  2. 通过爱思助手 / Filza / SCP 将生成的 .deb 安装包导入手机并安装："
echo "       dpkg -i com.legacy.fakepass9_*.deb && killall -9 SpringBoard"
echo "  3. 进入系统“设置 -> Touch ID 与密码 -> 打开密码”，正常设置 4 位或 6 位密码"
echo "     (界面顶部会显示“FakePass9 防白苹果保护”字样，代表已成功接管且未触发 SEP 加密)"
echo ""
echo "【应急清除密码方法】："
echo "  若忘记伪密码，开机时按住“音量+”进入 Safe Mode (安全模式)，或通过 SSH / 爱思助手删除："
echo "       /var/mobile/Library/Preferences/com.legacy.fakepass9.plist"
echo "  然后注销桌面即可无损清除密码，永不触发白苹果！"
echo "================================================================"