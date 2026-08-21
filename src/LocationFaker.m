//
//  LocationFaker.m
//  AppWiper (MyAppWiper / AppWiperUI)
//
//  GPS 定位伪造计算逻辑
//
//  说明：
//  本文件 *不* 直接 hook CLLocationManager，仅负责伪造坐标的计算与状态管理。
//  实际的 CLLocationManager 拦截由 Hooks.m 完成；Hooks.m 在回调中调用本类提供
//  的 +fakeLocation / +fakeCoordinate 获取伪造后的坐标，从而实现对目标 App 的
//  定位欺骗。这样可以把「坐标计算」与「方法 hook」解耦，便于维护与测试。
//
//  AppWiper v2.08
//

#import "LocationFaker.h"

#pragma mark - 静态状态变量

// 是否正在伪造定位
static BOOL s_isFaking = NO;

// 伪造基准纬度
static double s_lat = 0.0;

// 伪造基准经度
static double s_lon = 0.0;

// 漂移半径（单位：公里 km）
// 伪造坐标会在以基准点为中心、该半径范围内做随机偏移，
// 避免每次返回完全相同的坐标而被风控识别。
static double s_radiusKm = 0.0;

#pragma mark - 内部工具函数

// 产生一个 [-100, 99] 的带符号随机整数，用于经纬度偏移计算。
// arc4random_uniform(200) 返回 [0,199]，减去 100 得到 [-100,99]。
// 使用 arc4random_uniform 保证线程安全且分布质量良好。
static int LocationFakerRandomRaw(void) {
    return (int)arc4random_uniform(200) - 100;
}

// 对一个经/纬度坐标施加随机漂移。
// 偏移公式（与设计文档一致）：
//     coord += (arc4random_uniform(200) - 100) / 1000000.0 * radiusKm
// 其中 raw ∈ [-100, 99]，radiusKm 为漂移半径（公里）。
// 地球上纬度 1 度约 111 公里，该系数将「公里级半径」换算为「度数级」
// 的微小扰动，使每次返回的坐标在基准点附近做小幅随机抖动。
static double LocationFakerApplyDrift(double coord, double radiusKm) {
    int raw = LocationFakerRandomRaw();
    double offset = ((double)raw / 1000000.0) * radiusKm;
    return coord + offset;
}

#pragma mark -

@implementation LocationFaker

#pragma mark - 对外接口（LocationFaker.h 中声明）

// 设置伪造基准坐标与漂移半径，并标记开始伪造。
+ (void)setupLocationFakerWithLat:(double)lat lon:(double)lon radiusKm:(double)radius {
    @synchronized (self) {
        s_lat = lat;
        s_lon = lon;
        // 半径不允许为负
        s_radiusKm = (radius < 0.0) ? 0.0 : radius;
        s_isFaking = YES;
    }
}

// 停止伪造，重置全部状态。
+ (void)stopFakingLocation {
    @synchronized (self) {
        s_isFaking = NO;
        s_lat = 0.0;
        s_lon = 0.0;
        s_radiusKm = 0.0;
    }
}

// 返回当前是否正在伪造定位。
+ (BOOL)isFakingLocation {
    @synchronized (self) {
        return s_isFaking;
    }
}

#pragma mark - 伪造坐标计算（供 Hooks.m 调用）

// 返回带随机漂移的伪造 CLLocation。
// altitude 固定 18.0 米，水平/垂直精度均为 5.0 米，时间戳为当前。
+ (CLLocation *)fakeLocation {
    @synchronized (self) {
        // 取出当前基准与半径的本地副本，避免长时间持锁
        double lat = s_lat;
        double lon = s_lon;
        double radius = s_radiusKm;

        // 在半径范围内分别对纬度、经度施加随机漂移
        double driftedLat = LocationFakerApplyDrift(lat, radius);
        double driftedLon = LocationFakerApplyDrift(lon, radius);

        // 纬度范围 [-90, 90]，经度范围 [-180, 180]，做一次钳制以保证合法
        if (driftedLat > 90.0) driftedLat = 90.0;
        if (driftedLat < -90.0) driftedLat = -90.0;
        if (driftedLon > 180.0) driftedLon = 180.0;
        if (driftedLon < -180.0) driftedLon = -180.0;

        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(driftedLat, driftedLon);

        CLLocation *location = [[CLLocation alloc] initWithCoordinate:coord
                                                              altitude:18.0
                                                    horizontalAccuracy:5.0
                                                      verticalAccuracy:5.0
                                                             timestamp:[NSDate date]];
        return location;
    }
}

// 返回带随机漂移的伪造坐标（结构体，性能开销更小）。
+ (CLLocationCoordinate2D)fakeCoordinate {
    @synchronized (self) {
        double lat = s_lat;
        double lon = s_lon;
        double radius = s_radiusKm;

        double driftedLat = LocationFakerApplyDrift(lat, radius);
        double driftedLon = LocationFakerApplyDrift(lon, radius);

        if (driftedLat > 90.0) driftedLat = 90.0;
        if (driftedLat < -90.0) driftedLat = -90.0;
        if (driftedLon > 180.0) driftedLon = 180.0;
        if (driftedLon < -180.0) driftedLon = -180.0;

        return CLLocationCoordinate2DMake(driftedLat, driftedLon);
    }
}

#pragma mark - 状态访问器（供调试 / Hooks.m 判断使用）

// 当前配置的基准纬度
+ (double)currentLat {
    @synchronized (self) {
        return s_lat;
    }
}

// 当前配置的基准经度
+ (double)currentLon {
    @synchronized (self) {
        return s_lon;
    }
}

// 当前配置的漂移半径（公里）
+ (double)currentRadiusKm {
    @synchronized (self) {
        return s_radiusKm;
    }
}

// 返回不带漂移的原始基准 CLLocation，供需要稳定坐标的场景使用。
+ (CLLocation *)rawLocation {
    @synchronized (self) {
        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(s_lat, s_lon);
        return [[CLLocation alloc] initWithCoordinate:coord
                                             altitude:18.0
                                   horizontalAccuracy:5.0
                                     verticalAccuracy:5.0
                                            timestamp:[NSDate date]];
    }
}

// 返回不带漂移的原始基准坐标。
+ (CLLocationCoordinate2D)rawCoordinate {
    @synchronized (self) {
        return CLLocationCoordinate2DMake(s_lat, s_lon);
    }
}

// 调试用：返回当前伪造状态的字符串描述。
+ (NSString *)debugDescription {
    @synchronized (self) {
        return [NSString stringWithFormat:
            @"<LocationFaker faking=%d lat=%.6f lon=%.6f radiusKm=%.2f>",
            s_isFaking, s_lat, s_lon, s_radiusKm];
    }
}

@end
