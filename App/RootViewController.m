//
//  RootViewController.m
//  AppWiperUI
//
//  AppWiper 桌面控制 App 主界面
//
//  功能模块：
//    1. 目标 App 选择区（BundleID 输入）
//    2. 设备机型选择区（36 款 iPhone，UIPickerView）
//    3. 网络模式选择区（7 段 UISegmentedControl + WiFi SSID/BSSID）
//    4. 定位伪造区（纬度 / 经度 / 漂移半径 Slider）
//    5. 其他参数区（内购拦截 / 越狱隐藏 / UA 篡改 / 自定义 UA）
//    6. 一键抹机按钮（红色）
//    7. 保存配置按钮（蓝色）
//    8. 快照管理区（保存 / 加载 / 删除）
//    9. 状态显示（tableFooterView）
//
//  全部 UI 均使用代码 + frame 布局，不依赖 storyboard。
//  编译选项：-fobjc-arc -I../src
//
//  AppWiper v2.08
//

#import "RootViewController.h"
#import "WiperHelper.h"
#import "WiperSnapshotManager.h"
#import "LocationFaker.h"
#import "NetworkFaker.h"
#import "DeviceModels.h"

#pragma mark - 常量

// 分区索引
static const NSInteger kSectionTargetApp   = 0;
static const NSInteger kSectionDeviceModel = 1;
static const NSInteger kSectionNetwork     = 2;
static const NSInteger kSectionLocation    = 3;
static const NSInteger kSectionOtherParams = 4;
static const NSInteger kSectionActions     = 5;
static const NSInteger kSectionSnapshots   = 6;

// 屏幕宽度
#define SCREEN_WIDTH  ([UIScreen mainScreen].bounds.size.width)

// 常用颜色
static UIColor *AWColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

#pragma mark - 抹机随机数据生成（序列号 / IDFA / IDFV）

// DeviceModels 类的 @interface 与 @implementation 均定义在 src/DeviceModels.h 中
// （完整的 iPhone 硬件参数矩阵，供 tweak 与本 App 共用），本文件不再重复实现该类，
// 以免在同一编译单元内产生重复的 @implementation。
// 此处仅提供抹机所需的随机序列号 / IDFA / IDFV 生成工具。

// 生成形如 C02XXXXXXXXX 的随机设备序列号。
static NSString *AWRandomSerialNumber(void) {
    static NSString *charset = @"0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    NSUInteger len = charset.length;
    NSMutableString *s = [NSMutableString stringWithString:@"C02"];
    for (NSInteger i = 0; i < 9; i++) {
        unichar c = [charset characterAtIndex:arc4random_uniform((uint32_t)len)];
        [s appendFormat:@"%C", c];
    }
    return s;
}

// 生成大写 UUID 字符串，用于 IDFA / IDFV。
static NSString *AWRandomUUIDUpper(void) {
    return [[[NSUUID UUID] UUIDString] uppercaseString];
}

#pragma mark - RootViewController

@interface RootViewController () <UITableViewDataSource,
                                    UITableViewDelegate,
                                    UIPickerViewDataSource,
                                    UIPickerViewDelegate,
                                    UITextFieldDelegate>
{
    UITableView *_tableView;
    NSArray *_sectionTitles;
    NSArray *_carrierOptions; // 与 UISegmentedControl 索引对齐的网络运营商参数

    // 目标 App
    UITextField *_bundleIDField;

    // 设备机型
    UIPickerView *_devicePicker;
    UILabel *_deviceInfoLabel;
    NSInteger _selectedModelIndex;
    NSArray<NSString *> *_machineIdentifiers; // 来自 [DeviceModels allMachineIdentifiers]

    // 网络模式
    UISegmentedControl *_netSegment;
    UITextField *_ssidField;
    UITextField *_bssidField;

    // 定位伪造
    UITextField *_latField;
    UITextField *_lonField;
    UISlider *_radiusSlider;
    UILabel *_radiusValueLabel;

    // 其他参数
    UISwitch *_iapSwitch;
    UISwitch *_jbHideSwitch;
    UISwitch *_uaSwitch;
    UITextField *_uaField;

    // 状态
    UILabel *_statusLabel;

    // 快照
    NSArray<NSString *> *_snapshots;
    NSString *_currentBundleID;
}
@end

@implementation RootViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"抹机伪装";
    self.view.backgroundColor = AWColor(242, 242, 247, 1.0);

    _selectedModelIndex = 0;
    _snapshots = @[];
    _machineIdentifiers = [DeviceModels allMachineIdentifiers] ?: @[];

    _sectionTitles = @[
        @"目标应用",
        @"设备机型",
        @"网络模式",
        @"定位伪造",
        @"其他参数",
        @"操作",
        @"快照管理",
    ];

    // 7 个网络模式：无卡 / 飞行 / 移动 / 联通 / 电信 / 广电 / WiFi
    _carrierOptions = @[
        @{@"name": @"无卡",     @"carrier": @"",         @"mcc": @"",   @"mnc": @"",   @"radio": @""},
        @{@"name": @"飞行模式", @"carrier": @"",         @"mcc": @"",   @"mnc": @"",   @"radio": @""},
        @{@"name": @"移动",     @"carrier": @"中国移动", @"mcc": @"460", @"mnc": @"00", @"radio": @"LTE"},
        @{@"name": @"联通",     @"carrier": @"中国联通", @"mcc": @"460", @"mnc": @"01", @"radio": @"LTE"},
        @{@"name": @"电信",     @"carrier": @"中国电信", @"mcc": @"460", @"mnc": @"11", @"radio": @"LTE"},
        @{@"name": @"广电",     @"carrier": @"中国广电", @"mcc": @"460", @"mnc": @"15", @"radio": @"LTE"},
        @{@"name": @"WiFi",     @"carrier": @"",         @"mcc": @"",   @"mnc": @"",   @"radio": @"WiFi"},
    ];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.allowsSelectionDuringEditing = YES;
    _tableView.backgroundColor = AWColor(242, 242, 247, 1.0);
    [self.view addSubview:_tableView];

    // 状态显示：作为 tableFooterView 固定在列表底部
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, SCREEN_WIDTH, 70)];
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:13];
    _statusLabel.textColor = [UIColor darkGrayColor];
    _statusLabel.text = @"状态: 就绪，请输入目标 App 的 BundleID";
    _tableView.tableFooterView = _statusLabel;

    // 导航栏刷新按钮：刷新快照列表
    UIBarButtonItem *reloadItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(refreshSnapshots)];
    self.navigationItem.rightBarButtonItem = reloadItem;

    [self refreshSnapshots];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 进入界面时刷新一次状态文本（updateStatus 会自动补 "状态：" 前缀）
    [self updateStatus:@"就绪，请输入目标 App 的 BundleID"];
}

#pragma mark - 辅助方法

// 当前生效的 BundleID（优先用已保存的，否则取输入框文本）
- (NSString *)currentBundleID {
    if (_currentBundleID.length) {
        return _currentBundleID;
    }
    NSString *t = [_bundleIDField.text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t ?: @"";
}

// 机型信息展示文本
- (NSString *)deviceInfoText {
    if (_selectedModelIndex < 0 || _selectedModelIndex >= (NSInteger)_machineIdentifiers.count) {
        return @"当前机型：未知";
    }
    NSString *machine = _machineIdentifiers[_selectedModelIndex];
    NSDictionary *info = [DeviceModels deviceInfoForMachine:machine];
    if (!info) {
        return [NSString stringWithFormat:@"当前机型：未知\nhw_machine：%@", machine];
    }
    NSString *name    = info[@"marketing_name"] ?: machine;
    NSString *soc     = info[@"soc"] ?: @"";
    NSNumber *physmem = info[@"physmem"];
    NSString *ram     = physmem ? [NSString stringWithFormat:@"%.0f GB", [physmem doubleValue] / 1073741824.0] : @"未知";
    NSString *display = [NSString stringWithFormat:@"%@×%@ @%.0fx",
                         info[@"pt_width"], info[@"pt_height"], [info[@"scale"] doubleValue]];
    NSString *fps     = [NSString stringWithFormat:@"%@Hz", info[@"max_fps"]];
    NSString *metal   = info[@"metal_family"] ?: @"";
    NSString *gpu     = info[@"gpu_name"] ?: @"";
    return [NSString stringWithFormat:
        @"当前机型：%@\nhw_machine：%@ | SoC：%@ | RAM：%@\n屏幕：%@ | %@\nMetal：%@ / GPU：%@\n（序列号 / IDFA / IDFV 在抹机或保存时随机生成）",
        name, machine, soc, ram, display, fps, metal, gpu];
}

// 仅 WiFi 模式下允许编辑 SSID / BSSID
- (void)updateWifiFieldState {
    if (!_netSegment) {
        return;
    }
    BOOL isWifi = (_netSegment.selectedSegmentIndex == 6);
    if (_ssidField) {
        _ssidField.enabled = isWifi;
        _ssidField.alpha = isWifi ? 1.0 : 0.45;
    }
    if (_bssidField) {
        _bssidField.enabled = isWifi;
        _bssidField.alpha = isWifi ? 1.0 : 0.45;
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sectionTitles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sectionTitles[section];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case kSectionTargetApp:   return 1;
        case kSectionDeviceModel: return 2;
        case kSectionNetwork:     return 3;
        case kSectionLocation:    return 3;
        case kSectionOtherParams: return 4;
        case kSectionActions:     return 2;
        case kSectionSnapshots:   return 1 + (NSInteger)_snapshots.count;
        default:                  return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case kSectionDeviceModel:
            // 机型信息行（多行） + UIPickerView(216) 行
            return indexPath.row == 0 ? 116.0 : 220.0;
        case kSectionNetwork:
            return 50.0;
        case kSectionLocation:
            return indexPath.row == 2 ? 70.0 : 50.0;
        case kSectionOtherParams:
            return indexPath.row == 3 ? 60.0 : 50.0; // 自定义 UA 输入框行稍高
        case kSectionActions:
            return 60.0; // 按钮
        case kSectionSnapshots:
            return 50.0;
        default:
            return 50.0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 快照数据行使用共享标识，内容随列表动态变化
    if (indexPath.section == kSectionSnapshots && indexPath.row >= 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"snapshot_cell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"snapshot_cell"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        NSInteger idx = indexPath.row - 1;
        if (idx < (NSInteger)_snapshots.count) {
            cell.textLabel.text = _snapshots[idx];
        }
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        return cell;
    }

    // 其余行：每行一个唯一标识，UI 只构建一次
    NSString *identifier = [NSString stringWithFormat:@"c_%ld_%ld",
                            (long)indexPath.section, (long)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.contentView.backgroundColor = [UIColor whiteColor];
        [self buildCell:cell forRowAtIndexPath:indexPath];
    }
    [self configureCell:cell forRowAtIndexPath:indexPath];
    return cell;
}

#pragma mark - 单元构建（首次创建时调用）

- (void)buildCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case kSectionTargetApp:   [self buildTargetAppCell:cell]; break;
        case kSectionDeviceModel: [self buildDeviceModelCell:cell row:indexPath.row]; break;
        case kSectionNetwork:     [self buildNetworkCell:cell row:indexPath.row]; break;
        case kSectionLocation:    [self buildLocationCell:cell row:indexPath.row]; break;
        case kSectionOtherParams: [self buildOtherParamsCell:cell row:indexPath.row]; break;
        case kSectionActions:     [self buildActionsCell:cell row:indexPath.row]; break;
        case kSectionSnapshots:   [self buildSnapshotsCell:cell row:indexPath.row]; break;
    }
}

// 单元动态内容刷新（每次可见时调用）
- (void)configureCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionDeviceModel && indexPath.row == 0) {
        _deviceInfoLabel.text = [self deviceInfoText];
    } else if (indexPath.section == kSectionNetwork && indexPath.row == 0) {
        [self updateWifiFieldState];
    } else if (indexPath.section == kSectionLocation && indexPath.row == 2) {
        _radiusValueLabel.text = [NSString stringWithFormat:@"%.1f km", _radiusSlider.value];
    }
}

#pragma mark - 目标应用分区

- (void)buildTargetAppCell:(UITableViewCell *)cell {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(15, 15, 78, 20)];
    l.text = @"BundleID";
    l.font = [UIFont systemFontOfSize:15];

    _bundleIDField = [[UITextField alloc] initWithFrame:CGRectMake(100, 10, SCREEN_WIDTH - 115, 30)];
    _bundleIDField.placeholder = @"com.target.app";
    _bundleIDField.borderStyle = UITextBorderStyleRoundedRect;
    _bundleIDField.font = [UIFont systemFontOfSize:14];
    _bundleIDField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _bundleIDField.autocorrectionType = UITextAutocorrectionTypeNo;
    _bundleIDField.keyboardType = UIKeyboardTypeASCIICapable;
    _bundleIDField.delegate = self;
    _bundleIDField.tag = 100;

    [cell.contentView addSubview:l];
    [cell.contentView addSubview:_bundleIDField];
}

#pragma mark - 设备机型分区

- (void)buildDeviceModelCell:(UITableViewCell *)cell row:(NSInteger)row {
    if (row == 0) {
        _deviceInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 6, SCREEN_WIDTH - 30, 104)];
        _deviceInfoLabel.numberOfLines = 0;
        _deviceInfoLabel.font = [UIFont systemFontOfSize:13];
        _deviceInfoLabel.textColor = [UIColor darkTextColor];
        _deviceInfoLabel.text = [self deviceInfoText];
        [cell.contentView addSubview:_deviceInfoLabel];
    } else {
        _devicePicker = [[UIPickerView alloc] initWithFrame:CGRectMake(0, 0, SCREEN_WIDTH, 216)];
        _devicePicker.dataSource = self;
        _devicePicker.delegate = self;
        _devicePicker.showsSelectionIndicator = YES;
        [_devicePicker selectRow:_selectedModelIndex inComponent:0 animated:NO];
        [cell.contentView addSubview:_devicePicker];
    }
}

#pragma mark - 网络模式分区

- (void)buildNetworkCell:(UITableViewCell *)cell row:(NSInteger)row {
    if (row == 0) {
        _netSegment = [[UISegmentedControl alloc]
            initWithItems:@[@"无卡", @"飞行", @"移动", @"联通", @"电信", @"广电", @"WiFi"]];
        _netSegment.frame = CGRectMake(15, 10, SCREEN_WIDTH - 30, 30);
        _netSegment.selectedSegmentIndex = 2;
        [_netSegment addTarget:self action:@selector(netSegmentChanged:)
                 forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:_netSegment];
    } else if (row == 1) {
        [self buildLabeledFieldCell:cell label:@"SSID" placeholder:@"WiFi 名称（可选）" fieldPtr:&_ssidField];
    } else {
        [self buildLabeledFieldCell:cell label:@"BSSID" placeholder:@"aa:bb:cc:dd:ee:ff（可选）" fieldPtr:&_bssidField];
    }
    [self updateWifiFieldState];
}

// 通用：标签 + 输入框 的网络行
- (void)buildLabeledFieldCell:(UITableViewCell *)cell
                       label:(NSString *)labelText
                  placeholder:(NSString *)placeholder
                    fieldPtr:(UITextField **)fieldPtr {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(15, 15, 70, 20)];
    l.text = labelText;
    l.font = [UIFont systemFontOfSize:15];

    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(90, 10, SCREEN_WIDTH - 105, 30)];
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:14];
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.delegate = self;

    [cell.contentView addSubview:l];
    [cell.contentView addSubview:f];
    if (fieldPtr) {
        *fieldPtr = f;
    }
}

#pragma mark - 定位伪造分区

- (void)buildLocationCell:(UITableViewCell *)cell row:(NSInteger)row {
    if (row == 0) {
        [self buildLabeledFieldCell:cell label:@"纬度" placeholder:@"如 39.9042" fieldPtr:&_latField];
        _latField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    } else if (row == 1) {
        [self buildLabeledFieldCell:cell label:@"经度" placeholder:@"如 116.4074" fieldPtr:&_lonField];
        _lonField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    } else {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(15, 24, 78, 20)];
        l.text = @"漂移半径";
        l.font = [UIFont systemFontOfSize:15];

        _radiusValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(SCREEN_WIDTH - 90, 24, 75, 20)];
        _radiusValueLabel.textAlignment = NSTextAlignmentRight;
        _radiusValueLabel.font = [UIFont systemFontOfSize:14];
        _radiusValueLabel.textColor = [UIColor grayColor];
        _radiusValueLabel.text = @"2.0 km";

        _radiusSlider = [[UISlider alloc] initWithFrame:CGRectMake(98, 28, SCREEN_WIDTH - 200, 30)];
        _radiusSlider.minimumValue = 0.0;
        _radiusSlider.maximumValue = 20.0;
        _radiusSlider.value = 2.0;
        [_radiusSlider addTarget:self action:@selector(radiusSliderChanged:)
                    forControlEvents:UIControlEventValueChanged];

        [cell.contentView addSubview:l];
        [cell.contentView addSubview:_radiusSlider];
        [cell.contentView addSubview:_radiusValueLabel];
    }
}

#pragma mark - 其他参数分区

- (void)buildOtherParamsCell:(UITableViewCell *)cell row:(NSInteger)row {
    switch (row) {
        case 0:
            [self addSwitchCell:cell title:@"内购拦截 (bypass_iap)" on:YES swPtr:&_iapSwitch];
            break;
        case 1:
            [self addSwitchCell:cell title:@"越狱隐藏" on:YES swPtr:&_jbHideSwitch];
            break;
        case 2:
            [self addSwitchCell:cell title:@"UA 篡改" on:NO swPtr:&_uaSwitch];
            break;
        default: {
            // 自定义 UA 输入框
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(15, 18, 80, 20)];
            l.text = @"自定义UA";
            l.font = [UIFont systemFontOfSize:15];

            _uaField = [[UITextField alloc] initWithFrame:CGRectMake(100, 13, SCREEN_WIDTH - 115, 30)];
            _uaField.placeholder = @"如 Mozilla/5.0 (iPhone; ...)";
            _uaField.borderStyle = UITextBorderStyleRoundedRect;
            _uaField.font = [UIFont systemFontOfSize:13];
            _uaField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            _uaField.autocorrectionType = UITextAutocorrectionTypeNo;
            _uaField.delegate = self;

            [cell.contentView addSubview:l];
            [cell.contentView addSubview:_uaField];
            break;
        }
    }
}

// 通用：标签 + 开关 的行
- (void)addSwitchCell:(UITableViewCell *)cell
               title:(NSString *)title
                  on:(BOOL)on
               swPtr:(UISwitch **)swPtr {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(15, 14, SCREEN_WIDTH - 95, 22)];
    l.text = title;
    l.font = [UIFont systemFontOfSize:15];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(SCREEN_WIDTH - 75, 9, 0, 0)];
    sw.on = on;

    [cell.contentView addSubview:l];
    [cell.contentView addSubview:sw];
    if (swPtr) {
        *swPtr = sw;
    }
}

#pragma mark - 操作分区

- (void)buildActionsCell:(UITableViewCell *)cell row:(NSInteger)row {
    if (row == 0) {
        // 一键抹机（红色大按钮）
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(15, 12, SCREEN_WIDTH - 30, 40);
        [btn setTitle:@"一键抹机" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = AWColor(216, 38, 38, 1.0);
        btn.layer.cornerRadius = 8;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [btn addTarget:self action:@selector(wipeAction) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:btn];
    } else {
        // 保存配置（蓝色按钮）
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(15, 12, SCREEN_WIDTH - 30, 40);
        [btn setTitle:@"保存配置" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = AWColor(26, 115, 232, 1.0);
        btn.layer.cornerRadius = 8;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [btn addTarget:self action:@selector(saveConfigAction) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:btn];
    }
}

#pragma mark - 快照管理分区

- (void)buildSnapshotsCell:(UITableViewCell *)cell row:(NSInteger)row {
    if (row == 0) {
        // 保存当前配置为快照（绿色按钮）
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(15, 10, SCREEN_WIDTH - 30, 36);
        [btn setTitle:@"保存当前配置为快照" forState:UIControlStateNormal];
        btn.backgroundColor = AWColor(52, 168, 83, 1.0);
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.layer.cornerRadius = 8;
        btn.titleLabel.font = [UIFont systemFontOfSize:15];
        [btn addTarget:self action:@selector(saveSnapshotAction) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:btn];
    }
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionSnapshots && indexPath.row >= 1) {
        NSInteger idx = indexPath.row - 1;
        if (idx < (NSInteger)_snapshots.count) {
            [self loadSnapshotNamed:_snapshots[idx]];
        }
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

// 仅快照数据行允许左滑删除
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return (indexPath.section == kSectionSnapshots && indexPath.row >= 1);
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionSnapshots && indexPath.row >= 1) {
        return UITableViewCellEditingStyleDelete;
    }
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }
    if (indexPath.section == kSectionSnapshots && indexPath.row >= 1) {
        NSInteger idx = indexPath.row - 1;
        if (idx < (NSInteger)_snapshots.count) {
            NSString *name = _snapshots[idx];
            [WiperSnapshotManager deleteSnapshot:name forBundleID:[self currentBundleID]];
            [self refreshSnapshots];
            [self updateStatus:[NSString stringWithFormat:@"已删除快照：%@", name]];
        }
    }
}

#pragma mark - UIPickerViewDataSource / Delegate

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return (NSInteger)_machineIdentifiers.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView
              titleForRow:(NSInteger)row
             forComponent:(NSInteger)component {
    if (row < 0 || row >= (NSInteger)_machineIdentifiers.count) {
        return @"";
    }
    NSString *machine = _machineIdentifiers[row];
    NSDictionary *info = [DeviceModels deviceInfoForMachine:machine];
    NSString *name = info[@"marketing_name"] ?: machine;
    return [NSString stringWithFormat:@"%@  (%@)", name, machine];
}

- (void)pickerView:(UIPickerView *)pickerView
      didSelectRow:(NSInteger)row
       inComponent:(NSInteger)component {
    _selectedModelIndex = row;
    _deviceInfoLabel.text = [self deviceInfoText];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// BundleID 输入变化时同步刷新快照列表
- (BOOL)textField:(UITextField *)textField
    shouldChangeCharactersInRange:(NSRange)range
    replacementString:(NSString *)string {
    if (textField == _bundleIDField) {
        // 异步刷新，等文本真正更新后
        dispatch_async(dispatch_get_main_queue(), ^{
            _currentBundleID = nil; // 强制重新读取输入框
            [self refreshSnapshots];
        });
    }
    return YES;
}

#pragma mark - 控件事件

- (void)netSegmentChanged:(UISegmentedControl *)segment {
    [self updateWifiFieldState];
    NSDictionary *carrier = _carrierOptions[segment.selectedSegmentIndex];
    [self updateStatus:[NSString stringWithFormat:@"网络模式：%@", carrier[@"name"]]];
}

- (void)radiusSliderChanged:(UISlider *)slider {
    _radiusValueLabel.text = [NSString stringWithFormat:@"%.1f km", slider.value];
}

#pragma mark - 一键抹机

- (void)wipeAction {
    NSString *bundleID = [[self currentBundleID]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (bundleID.length == 0) {
        [self showAlertWithTitle:@"提示" message:@"请输入目标 App 的 BundleID"];
        return;
    }
    _currentBundleID = bundleID;

    // 先把当前配置写入磁盘（抹机会读取该配置）
    NSDictionary *config = [self buildConfigDict];
    if (![self writeConfig:config forBundleID:bundleID]) {
        [self showAlertWithTitle:@"错误" message:@"配置写入失败，无法执行抹机"];
        return;
    }
    [self applyConfigToRuntime:config];
    [self updateStatus:@"正在执行抹机，请稍候……"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = [WiperHelper performFullWipeForBundleID:bundleID];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [self updateStatus:@"抹机完成"];
                [self showAlertWithTitle:@"完成"
                                  message:@"已为目标 App 执行完整抹机与伪装"];
                [self refreshSnapshots];
            } else {
                [self updateStatus:@"抹机失败"];
                [self showAlertWithTitle:@"失败" message:@"抹机操作未能完成，请检查配置"];
            }
        });
    });
}

#pragma mark - 保存配置

- (void)saveConfigAction {
    NSString *bundleID = [[self currentBundleID]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (bundleID.length == 0) {
        [self showAlertWithTitle:@"提示" message:@"请输入目标 App 的 BundleID"];
        return;
    }
    _currentBundleID = bundleID;

    NSDictionary *config = [self buildConfigDict];
    NSString *path = [WiperHelper getConfigPathForBundleID:bundleID];
    BOOL ok = [self writeConfig:config forBundleID:bundleID];
    if (ok) {
        [self applyConfigToRuntime:config];
        [self updateStatus:[NSString stringWithFormat:@"配置已保存：\n%@", path]];
    } else {
        [self updateStatus:@"配置保存失败"];
        [self showAlertWithTitle:@"错误" message:@"配置保存失败"];
    }
}

// 将配置字典写入 [WiperHelper getConfigPathForBundleID:]，必要时创建目录。
- (BOOL)writeConfig:(NSDictionary *)config forBundleID:(NSString *)bundleID {
    NSString *path = [WiperHelper getConfigPathForBundleID:bundleID];
    if (path.length == 0) {
        return NO;
    }
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (dir.length && ![fm fileExistsAtPath:dir]) {
        NSError *err = nil;
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
        if (err) {
            NSLog(@"[AppWiper] 创建配置目录失败: %@", err);
        }
    }
    return [config writeToFile:path atomically:YES];
}

// 汇总当前界面所有设置，构造配置字典。
- (NSDictionary *)buildConfigDict {
    NSString *bundleID = [self currentBundleID];

    // 选中的机型硬件标识（hw.machine），tweak 据此经 DeviceModels 解析完整参数
    NSString *hwMachine = @"";
    if (_selectedModelIndex >= 0 && _selectedModelIndex < (NSInteger)_machineIdentifiers.count) {
        hwMachine = _machineIdentifiers[_selectedModelIndex];
    }
    NSDictionary *carrier = _carrierOptions[(_netSegment ? _netSegment.selectedSegmentIndex : 0)];

    double lat = [_latField.text doubleValue];
    double lon = [_lonField.text doubleValue];
    double radius = _radiusSlider ? _radiusSlider.value : 0.0;

    return @{
        @"enabled":        @YES,
        @"bundle_id":      bundleID ?: @"",
        @"hw_machine":     hwMachine,
        @"serial_number":  AWRandomSerialNumber(),
        @"idfa":           AWRandomUUIDUpper(),
        @"idfv":           AWRandomUUIDUpper(),
        @"net_mode":       carrier[@"name"] ?: @"",
        @"carrier_name":   carrier[@"carrier"] ?: @"",
        @"mcc":            carrier[@"mcc"] ?: @"",
        @"mnc":            carrier[@"mnc"] ?: @"",
        @"radio_tech":     carrier[@"radio"] ?: @"",
        @"latitude":       @(lat),
        @"longitude":      @(lon),
        @"radius_km":      @(radius),
        @"bypass_iap":     @(_iapSwitch.on),
        @"jailbreak_hide": @(_jbHideSwitch.on),
        @"ua_tamper":      @(_uaSwitch.on),
        @"custom_ua":      _uaField.text ?: @"",
        @"wifi_ssid":      _ssidField.text ?: @"",
        @"wifi_bssid":     _bssidField.text ?: @"",
    };
}

// 将配置应用到运行时伪造模块（定位 + 网络）。
- (void)applyConfigToRuntime:(NSDictionary *)config {
    if (!config) {
        return;
    }
    // 定位伪造
    double lat = [config[@"latitude"] doubleValue];
    double lon = [config[@"longitude"] doubleValue];
    double radius = [config[@"radius_km"] doubleValue];
    if (lat != 0.0 || lon != 0.0) {
        [LocationFaker setupLocationFakerWithLat:lat lon:lon radiusKm:radius];
    } else {
        [LocationFaker stopFakingLocation];
    }
    // 网络伪造
    [NetworkFaker applyNetworkConfig:config];
}

#pragma mark - 快照管理

- (void)refreshSnapshots {
    NSString *bid = [self currentBundleID];
    if (bid.length) {
        _snapshots = [WiperSnapshotManager savedSnapshotsForBundleID:bid] ?: @[];
    } else {
        _snapshots = @[];
    }
    // 仅当表格已上屏时才刷新分区，避免与初次布局冲突
    if (_tableView.window) {
        NSIndexSet *set = [NSIndexSet indexSetWithIndex:kSectionSnapshots];
        [_tableView reloadSections:set withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (void)saveSnapshotAction {
    NSString *bundleID = [[self currentBundleID]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (bundleID.length == 0) {
        [self showAlertWithTitle:@"提示" message:@"请先输入目标 App 的 BundleID"];
        return;
    }
    _currentBundleID = bundleID;

    // 先把当前配置落盘，快照管理器会基于该配置生成快照
    NSDictionary *config = [self buildConfigDict];
    if (![self writeConfig:config forBundleID:bundleID]) {
        [self showAlertWithTitle:@"错误" message:@"配置写入失败，无法保存快照"];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"保存快照"
                         message:@"请输入快照名称"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"快照名称";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length == 0) {
            [self showAlertWithTitle:@"提示" message:@"快照名称不能为空"];
            return;
        }
        BOOL ok = [WiperSnapshotManager saveCurrentConfigAsSnapshot:name forBundleID:bundleID];
        [self refreshSnapshots];
        [self updateStatus:ok ? [NSString stringWithFormat:@"快照已保存：%@", name]
                              : @"快照保存失败"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loadSnapshotNamed:(NSString *)name {
    NSString *bid = [self currentBundleID];
    if (bid.length == 0) {
        [self showAlertWithTitle:@"提示" message:@"请先输入目标 App 的 BundleID"];
        return;
    }
    NSDictionary *snap = [WiperSnapshotManager loadSnapshot:name forBundleID:bid];
    if (!snap) {
        [self updateStatus:@"快照加载失败"];
        [self showAlertWithTitle:@"错误" message:@"无法读取该快照"];
        return;
    }
    [WiperSnapshotManager applySnapshot:name forBundleID:bid];
    [self applyConfigToRuntime:snap];
    [self updateStatus:[NSString stringWithFormat:@"已加载快照：%@", name]];
}

#pragma mark - 状态与弹窗

- (void)updateStatus:(NSString *)text {
    NSString *full = [NSString stringWithFormat:@"状态：%@", text ?: @""];
    _statusLabel.text = full;

    // 根据内容动态计算高度，重新设置 tableFooterView 以触发布局
    CGRect rect = [full boundingRectWithSize:CGSizeMake(SCREEN_WIDTH - 24, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName: _statusLabel.font}
                                     context:nil];
    CGFloat h = MAX(70.0, ceil(rect.size.height) + 24.0);
    _statusLabel.frame = CGRectMake(0, 0, SCREEN_WIDTH, h);
    // 重新赋值以让 UITableView 重新测量 footer 高度
    _tableView.tableFooterView = nil;
    _tableView.tableFooterView = _statusLabel;
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
