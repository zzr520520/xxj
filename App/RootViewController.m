#import "RootViewController.h"
#import "../src/WiperHelper.h"
#import "../src/DeviceModels.h"
#import "../src/WiperSnapshotManager.h"
#import "../src/LocationFaker.h"
#import "../src/NetworkFaker.h"
#import <objc/runtime.h>

// ============================================================
// 私有 API 声明
// ============================================================
@interface UIImage (Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedShortName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

// ============================================================
// App 选择器（独立页面，带搜索）
// ============================================================
@interface AppPickerViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSMutableArray<LSApplicationProxy *> *allApps;
@property (nonatomic, strong) NSMutableArray<LSApplicationProxy *> *filteredApps;
@property (nonatomic, copy) void (^onSelected)(LSApplicationProxy *app);
@end

@implementation AppPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择目标应用";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.placeholder = @"搜索应用名称或 Bundle ID";
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.navigationItem.titleView = self.searchBar;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    self.allApps = [NSMutableArray array];
    self.filteredApps = [NSMutableArray array];
    [self loadApps];
}

- (void)loadApps {
    [self.allApps removeAllObjects];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        id workspace = [workspaceClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        NSArray *all = [workspace performSelector:NSSelectorFromString(@"allInstalledApplications")];
        for (id app in all) {
            if ([[app valueForKey:@"applicationType"] isEqualToString:@"User"]) {
                [self.allApps addObject:app];
            }
        }
    }
    [self.allApps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [a.localizedShortName compare:b.localizedShortName];
    }];
    [self filterApps:@""];
}

- (void)filterApps:(NSString *)keyword {
    [self.filteredApps removeAllObjects];
    if (keyword.length == 0) {
        [self.filteredApps addObjectsFromArray:self.allApps];
    } else {
        for (LSApplicationProxy *app in self.allApps) {
            NSString *name = app.localizedShortName ?: @"";
            NSString *bid = app.bundleIdentifier ?: @"";
            if ([name localizedCaseInsensitiveContainsString:keyword] ||
                [bid localizedCaseInsensitiveContainsString:keyword]) {
                [self.filteredApps addObject:app];
            }
        }
    }
    [self.tableView reloadData];
}

#pragma mark - SearchBar
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self filterApps:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark - TableView
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LSApplicationProxy *app = self.filteredApps[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = app.localizedShortName ?: @"未知应用";
    cell.detailTextLabel.text = app.bundleIdentifier;
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:app.bundleIdentifier format:2 scale:[UIScreen mainScreen].scale];
    if (icon) {
        cell.imageView.image = icon;
        cell.imageView.layer.cornerRadius = 8;
        cell.imageView.layer.masksToBounds = YES;
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LSApplicationProxy *app = self.filteredApps[indexPath.row];
    if (self.onSelected) {
        self.onSelected(app);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// ============================================================
// 设备型号选择器（独立页面）
// ============================================================
@interface DeviceModelPickerViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSString *> *allMachines;
@property (nonatomic, copy) NSString *selectedMachine;
@property (nonatomic, copy) void (^onSelected)(NSString *machine);
@end

@implementation DeviceModelPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择设备型号";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.allMachines = [DeviceModels allMachineIdentifiers];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.allMachines.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"📱 可选设备型号";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *machine = self.allMachines[indexPath.row];
    NSDictionary *info = [DeviceModels deviceInfoForMachine:machine];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = info[@"marketing_name"] ?: machine;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  •  %@  •  %@GB", machine, info[@"soc"] ?: @"?", info[@"physmem"] ? [NSString stringWithFormat:@"%.0f", [info[@"physmem"] doubleValue] / 1073741824.0] : @"?"];
    if (self.selectedMachine && [self.selectedMachine isEqualToString:machine]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *machine = self.allMachines[indexPath.row];
    self.selectedMachine = machine;
    if (self.onSelected) {
        self.onSelected(machine);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// ============================================================
// 可编辑的 TableView Cell（带随机按钮）
// ============================================================
@interface EditableCell : UITableViewCell
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UIButton *randomButton;
@property (nonatomic, copy) void (^randomAction)(void);
@end

@implementation EditableCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.textField = [[UITextField alloc] init];
        self.textField.font = [UIFont systemFontOfSize:15];
        self.textField.textColor = [UIColor labelColor];
        self.textField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [self.contentView addSubview:self.textField];

        self.randomButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.randomButton setTitle:@"🎲 随机" forState:UIControlStateNormal];
        self.randomButton.titleLabel.font = [UIFont systemFontOfSize:13];
        [self.randomButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        [self.contentView addSubview:self.randomButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat padding = 16;
    CGFloat btnWidth = 70;
    self.textField.frame = CGRectMake(padding, 8, self.contentView.bounds.size.width - padding - btnWidth - 20, 34);
    self.randomButton.frame = CGRectMake(self.contentView.bounds.size.width - btnWidth - padding, 8, btnWidth, 34);
}

- (void)setRandomAction:(void (^)(void))randomAction {
    _randomAction = randomAction;
    [self.randomButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    if (randomAction) {
        [self.randomButton addTarget:self action:@selector(triggerRandom) forControlEvents:UIControlEventTouchUpInside];
    }
}
- (void)triggerRandom {
    if (self.randomAction) self.randomAction();
}
@end

// ============================================================
// RootViewController 主实现
// ============================================================
@interface RootViewController () <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) LSApplicationProxy *selectedApp;
@property (nonatomic, copy) NSString *selectedMachine;
@property (nonatomic, strong) NSMutableDictionary *params;

// 参数缓存
@property (nonatomic, copy) NSString *inputSSID;
@property (nonatomic, copy) NSString *inputBSSID;
@property (nonatomic, copy) NSString *inputLat;
@property (nonatomic, copy) NSString *inputLon;
@property (nonatomic, copy) NSString *inputRadius;
@property (nonatomic, copy) NSString *inputUA;
@property (nonatomic, assign) NSInteger selectedNetworkMode;
@property (nonatomic, assign) BOOL bypassIAP;
@property (nonatomic, assign) BOOL jailbreakHide;
@property (nonatomic, assign) BOOL uaToggle;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"抹机伪装";
    self.params = [NSMutableDictionary dictionary];

    self.selectedNetworkMode = 0;
    self.bypassIAP = NO;
    self.jailbreakHide = YES;
    self.uaToggle = YES;

    // 默认设备型号（随机）
    NSArray *machines = [DeviceModels allMachineIdentifiers];
    self.selectedMachine = machines[arc4random_uniform((uint32_t)machines.count)];

    [self randomizeAllParams];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

#pragma mark - 随机生成所有参数
- (void)randomizeAllParams {
    self.inputSSID = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
    self.inputBSSID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                       arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
                       arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
    self.inputLat = [NSString stringWithFormat:@"%.4f", 21.0 + (double)arc4random()/UINT32_MAX * 18.0];
    self.inputLon = [NSString stringWithFormat:@"%.4f", 100.0 + (double)arc4random()/UINT32_MAX * 20.0];
    self.inputRadius = [NSString stringWithFormat:@"%.1f", 1.0 + (double)arc4random()/UINT32_MAX * 20.0];
    NSArray *uaVersions = @[@"17.4", @"17.3", @"17.2", @"17.1", @"16.6", @"16.5", @"16.4", @"16.3"];
    NSString *ver = uaVersions[arc4random_uniform((uint32_t)uaVersions.count)];
    self.inputUA = [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                    [ver stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
    self.selectedNetworkMode = arc4random_uniform(7);
    // 随机设备型号
    NSArray *machines = [DeviceModels allMachineIdentifiers];
    self.selectedMachine = machines[arc4random_uniform((uint32_t)machines.count)];
}

#pragma mark - TableView DataSource
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 7;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"📱 目标应用";
        case 1: return @"📱 设备型号";
        case 2: return @"📶 网络模式";
        case 3: return @"📶 WiFi 伪装";
        case 4: return @"📍 定位伪装";
        case 5: return @"🔧 其他参数";
        case 6: return @"🚀 操作";
        default: return @"";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;  // 单行入口
        case 1: return 1;  // 单行入口
        case 2: return 7;  // 7种网络模式
        case 3: return 2;  // SSID + BSSID
        case 4: return 3;  // 纬度 + 经度 + 半径
        case 5: return 3;  // 内购 + 越狱 + UA
        case 6: return 2;  // 抹机 + 随机全部
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell;

    switch (indexPath.section) {
        case 0: {
            // 目标应用 - 单行入口
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            if (self.selectedApp) {
                cell.textLabel.text = self.selectedApp.localizedShortName ?: @"未知";
                cell.detailTextLabel.text = self.selectedApp.bundleIdentifier;
            } else {
                cell.textLabel.text = @"点击选择应用";
                cell.detailTextLabel.text = @"未选择";
                cell.textLabel.textColor = [UIColor systemGrayColor];
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case 1: {
            // 设备型号 - 单行入口
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            NSDictionary *info = [DeviceModels deviceInfoForMachine:self.selectedMachine];
            cell.textLabel.text = info[@"marketing_name"] ?: self.selectedMachine;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", self.selectedMachine, info[@"soc"] ?: @"?"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case 2: {
            // 网络模式
            NSArray *modes = @[@"📶 正常", @"✈️ 飞行", @"📱 无卡", @"🟢 移动", @"🔵 联通", @"🟠 电信", @"📡 广电"];
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = modes[indexPath.row];
            if (indexPath.row == self.selectedNetworkMode) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            } else {
                cell.accessoryType = UITableViewCellAccessoryNone;
            }
            return cell;
        }
        case 3: {
            // SSID + BSSID
            EditableCell *editableCell = [[EditableCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            editableCell.textField.placeholder = indexPath.row == 0 ? @"SSID (如 WiFi-7A3F)" : @"BSSID (如 aa:bb:cc:dd:ee:ff)";
            editableCell.textField.text = indexPath.row == 0 ? self.inputSSID : self.inputBSSID;
            editableCell.textField.tag = 100 + indexPath.row;
            editableCell.textField.delegate = self;
            __weak typeof(self) weakSelf = self;
            __weak EditableCell *weakCell = editableCell;
            editableCell.randomAction = ^{
                if (indexPath.row == 0) {
                    weakSelf.inputSSID = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
                    weakCell.textField.text = weakSelf.inputSSID;
                } else {
                    weakSelf.inputBSSID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
                                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
                    weakCell.textField.text = weakSelf.inputBSSID;
                }
            };
            return editableCell;
        }
        case 4: {
            // 定位参数
            NSArray *placeholders = @[@"纬度 (如 39.9042)", @"经度 (如 116.4074)", @"漂移半径 (km)"];
            NSArray *values = @[self.inputLat ?: @"39.9042", self.inputLon ?: @"116.4074", self.inputRadius ?: @"5.0"];
            EditableCell *editableCell = [[EditableCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            editableCell.textField.placeholder = placeholders[indexPath.row];
            editableCell.textField.text = values[indexPath.row];
            editableCell.textField.keyboardType = UIKeyboardTypeDecimalPad;
            editableCell.textField.tag = 200 + indexPath.row;
            editableCell.textField.delegate = self;
            __weak typeof(self) weakSelf = self;
            __weak EditableCell *weakCell = editableCell;
            editableCell.randomAction = ^{
                double lat = 21.0 + (double)arc4random()/UINT32_MAX * 18.0;
                double lon = 100.0 + (double)arc4random()/UINT32_MAX * 20.0;
                double radius = 1.0 + (double)arc4random()/UINT32_MAX * 20.0;
                if (indexPath.row == 0) {
                    weakSelf.inputLat = [NSString stringWithFormat:@"%.4f", lat];
                    weakCell.textField.text = weakSelf.inputLat;
                } else if (indexPath.row == 1) {
                    weakSelf.inputLon = [NSString stringWithFormat:@"%.4f", lon];
                    weakCell.textField.text = weakSelf.inputLon;
                } else {
                    weakSelf.inputRadius = [NSString stringWithFormat:@"%.1f", radius];
                    weakCell.textField.text = weakSelf.inputRadius;
                }
            };
            return editableCell;
        }
        case 5: {
            // 其他参数
            if (indexPath.row == 0) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                cell.textLabel.text = self.bypassIAP ? @"✅ 内购拦截 (已开启)" : @"⛔ 内购拦截 (已关闭)";
                cell.textLabel.textColor = self.bypassIAP ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
                return cell;
            } else if (indexPath.row == 1) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                cell.textLabel.text = self.jailbreakHide ? @"✅ 越狱隐藏 (已开启)" : @"⛔ 越狱隐藏 (已关闭)";
                cell.textLabel.textColor = self.jailbreakHide ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
                return cell;
            } else {
                EditableCell *editableCell = [[EditableCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                editableCell.textField.placeholder = @"自定义 UA (留空使用默认)";
                editableCell.textField.text = self.inputUA;
                editableCell.textField.tag = 300;
                editableCell.textField.delegate = self;
                __weak typeof(self) weakSelf = self;
                __weak EditableCell *weakCell = editableCell;
                editableCell.randomAction = ^{
                    NSArray *versions = @[@"17.4", @"17.3", @"17.2", @"17.1", @"16.6", @"16.5", @"16.4"];
                    NSString *ver = versions[arc4random_uniform((uint32_t)versions.count)];
                    weakSelf.inputUA = [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                                        [ver stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
                    weakCell.textField.text = weakSelf.inputUA;
                };
                return editableCell;
            }
        }
        case 6: {
            // 操作按钮
            if (indexPath.row == 0) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                cell.textLabel.text = @"🚀 一键抹机";
                cell.textLabel.textColor = [UIColor systemRedColor];
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
                return cell;
            } else {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                cell.textLabel.text = @"🎲 随机生成全部参数";
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                return cell;
            }
        }
        default:
            return [[UITableViewCell alloc] init];
    }
}

#pragma mark - TableView Delegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case 0: {
            // 进入 App 选择页
            AppPickerViewController *picker = [[AppPickerViewController alloc] init];
            __weak typeof(self) weakSelf = self;
            picker.onSelected = ^(LSApplicationProxy *app) {
                weakSelf.selectedApp = app;
                [weakSelf.tableView reloadData];
            };
            [self.navigationController pushViewController:picker animated:YES];
            break;
        }
        case 1: {
            // 进入设备型号选择页
            DeviceModelPickerViewController *picker = [[DeviceModelPickerViewController alloc] init];
            picker.selectedMachine = self.selectedMachine;
            __weak typeof(self) weakSelf = self;
            picker.onSelected = ^(NSString *machine) {
                weakSelf.selectedMachine = machine;
                [weakSelf.tableView reloadData];
            };
            [self.navigationController pushViewController:picker animated:YES];
            break;
        }
        case 2: {
            self.selectedNetworkMode = indexPath.row;
            [tableView reloadData];
            break;
        }
        case 5: {
            if (indexPath.row == 0) {
                self.bypassIAP = !self.bypassIAP;
                [tableView reloadData];
            } else if (indexPath.row == 1) {
                self.jailbreakHide = !self.jailbreakHide;
                [tableView reloadData];
            }
            break;
        }
        case 6: {
            if (indexPath.row == 0) {
                [self executeWipe];
            } else {
                [self randomizeAllParams];
                [tableView reloadData];
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - UITextFieldDelegate
- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSInteger tag = textField.tag;
    if (tag >= 100 && tag < 200) {
        if (tag == 100) self.inputSSID = textField.text;
        else self.inputBSSID = textField.text;
    } else if (tag >= 200 && tag < 300) {
        if (tag == 200) self.inputLat = textField.text;
        else if (tag == 201) self.inputLon = textField.text;
        else if (tag == 202) self.inputRadius = textField.text;
    } else if (tag == 300) {
        self.inputUA = textField.text;
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - 生成随机设备配置
- (NSDictionary *)generateSeedProfile {
    NSString *machine = self.selectedMachine ?: @"iPhone15,2";
    NSDictionary *devInfo = [DeviceModels deviceInfoForMachine:machine];

    NSString *serial = [NSString stringWithFormat:@"F%@%@",
        [NSString stringWithFormat:@"%c", (unichar)('A' + arc4random_uniform(26))],
        [NSString stringWithFormat:@"%011u", arc4random_uniform(999999999)]];

    NSString *ecid = [NSString stringWithFormat:@"%016llX", (unsigned long long)arc4random() << 32 | arc4random()];

    NSString *wifiMAC = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
        arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
        arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];

    NSString *btMAC = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
        arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
        arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];

    return @{
        @"MachineModel": machine,
        @"DisplayName": devInfo[@"marketing_name"] ?: machine,
        @"DeviceName": devInfo[@"marketing_name"] ?: @"iPhone",
        @"ProductName": @"iPhone OS",
        @"ModelNumber": devInfo[@"hw_model"] ?: @"D73",
        @"HardwareModel": machine,
        @"SerialNumber": serial,
        @"ECID": ecid,
        @"UniqueDeviceID": [NSUUID UUID].UUIDString,
        @"WifiAddress": wifiMAC,
        @"BluetoothAddress": btMAC,
        @"ProductType": machine,
        @"BoardId": @(arc4random_uniform(20)),
        @"ChipId": @(arc4random_uniform(100)),
        @"SOC": devInfo[@"soc"] ?: @"A16",
        @"CPUCore": devInfo[@"cpu_cores"] ?: @(6),
        @"PhysMem": devInfo[@"physmem"] ?: @6442450944,
    };
}

#pragma mark - 执行抹机
- (void)executeWipe {
    if (!self.selectedApp) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 提示" message:@"请先选择一个目标应用" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *bundleID = self.selectedApp.bundleIdentifier;

    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithDictionary:[self generateSeedProfile]];
    config[@"WifiSSID"] = self.inputSSID ?: @"WiFi-0000";
    config[@"WifiBSSID"] = self.inputBSSID ?: @"00:00:00:00:00:00";
    config[@"LocationLat"] = @([self.inputLat doubleValue] ?: 39.9042);
    config[@"LocationLon"] = @([self.inputLon doubleValue] ?: 116.4074);
    config[@"LocationRadius"] = @([self.inputRadius doubleValue] ?: 5.0);
    if (self.inputUA.length > 0) config[@"UserAgent"] = self.inputUA;
    config[@"BypassIAP"] = @(self.bypassIAP);
    config[@"JailbreakHide"] = @(self.jailbreakHide);

    NSArray *netModes = @[@"normal", @"flight", @"nosim", @"mobile", @"unicom", @"telecom", @"broadnet"];
    config[@"NetworkMode"] = netModes[self.selectedNetworkMode];

    NSArray *carrierNames = @[@"中国移动", @"中国移动", @"", @"中国移动", @"中国联通", @"中国电信", @"中国广电"];
    NSArray *carrierMNCs = @[@"00", @"00", @"", @"00", @"01", @"03", @"15"];
    config[@"CarrierName"] = carrierNames[self.selectedNetworkMode];
    config[@"CarrierMNC"] = carrierMNCs[self.selectedNetworkMode];
    config[@"CarrierMCC"] = @"460";

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"正在抹除..." message:@"请稍候" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [WiperHelper performFullWipeForBundleID:bundleID];

        NSString *configPath = [WiperHelper getConfigPathForBundleID:bundleID];
        NSString *dir = [configPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [config writeToFile:configPath atomically:YES];

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                UIAlertController *done = [UIAlertController alertControllerWithTitle:@"✅ 抹机完成"
                    message:[NSString stringWithFormat:@"已应用身份: %@\n序列号: %@\n\n📌 请按顺序操作：\n1. 手动卸载目标 App\n2. 等待 30 秒\n3. 重新安装使用新账号登录", config[@"DisplayName"], config[@"SerialNumber"]]
                    preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:done animated:YES completion:nil];
            }];
        });
    });
}

@end
