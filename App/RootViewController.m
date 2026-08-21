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
        
        // 文本输入框
        self.textField = [[UITextField alloc] init];
        self.textField.font = [UIFont systemFontOfSize:15];
        self.textField.textColor = [UIColor labelColor];
        self.textField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [self.contentView addSubview:self.textField];
        
        // 随机按钮
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
@property (nonatomic, strong) NSMutableArray<LSApplicationProxy *> *apps;
@property (nonatomic, strong) LSApplicationProxy *selectedApp;
@property (nonatomic, strong) NSMutableDictionary *params; // 存储所有参数

// 参数缓存
@property (nonatomic, copy) NSString *inputSSID;
@property (nonatomic, copy) NSString *inputBSSID;
@property (nonatomic, copy) NSString *inputLat;
@property (nonatomic, copy) NSString *inputLon;
@property (nonatomic, copy) NSString *inputRadius;
@property (nonatomic, copy) NSString *inputUA;
@property (nonatomic, assign) NSInteger selectedNetworkMode; // 0-6
@property (nonatomic, assign) BOOL bypassIAP;
@property (nonatomic, assign) BOOL jailbreakHide;
@property (nonatomic, assign) BOOL uaToggle;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"抹机伪装";
    self.apps = [NSMutableArray array];
    self.params = [NSMutableDictionary dictionary];
    
    // 默认参数
    self.selectedNetworkMode = 0;
    self.bypassIAP = NO;
    self.jailbreakHide = YES;
    self.uaToggle = YES;
    
    // 初始化随机默认值
    [self randomizeAllParams];
    
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
    
    [self loadApps];
}

#pragma mark - 加载已安装 App
- (void)loadApps {
    [self.apps removeAllObjects];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        id workspace = [workspaceClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        NSArray *all = [workspace performSelector:NSSelectorFromString(@"allInstalledApplications")];
        for (id app in all) {
            if ([[app valueForKey:@"applicationType"] isEqualToString:@"User"]) {
                [self.apps addObject:app];
            }
        }
    }
    // 按名称排序
    [self.apps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [a.localizedShortName compare:b.localizedShortName];
    }];
    [self.tableView reloadData];
}

#pragma mark - 随机生成所有参数
- (void)randomizeAllParams {
    // 随机 SSID
    self.inputSSID = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
    // 随机 BSSID
    self.inputBSSID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                       arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
                       arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
    // 随机经纬度（中国范围内）
    self.inputLat = [NSString stringWithFormat:@"%.4f", 21.0 + (double)arc4random()/UINT32_MAX * 18.0];
    self.inputLon = [NSString stringWithFormat:@"%.4f", 100.0 + (double)arc4random()/UINT32_MAX * 20.0];
    self.inputRadius = [NSString stringWithFormat:@"%.1f", 1.0 + (double)arc4random()/UINT32_MAX * 20.0];
    // 随机 UA
    NSArray *uaVersions = @[@"17.4", @"17.3", @"17.2", @"17.1", @"16.6", @"16.5", @"16.4", @"16.3"];
    NSString *ver = uaVersions[arc4random_uniform((uint32_t)uaVersions.count)];
    self.inputUA = [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                    [ver stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
    // 随机网络模式
    self.selectedNetworkMode = arc4random_uniform(7);
}

#pragma mark - TableView DataSource
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 6;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"📱 选择目标应用";
        case 1: return @"📶 网络模式";
        case 2: return @"📶 WiFi 伪装";
        case 3: return @"📍 定位伪装";
        case 4: return @"🔧 其他参数";
        case 5: return @"🚀 操作";
        default: return @"";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return self.apps.count > 0 ? self.apps.count + 1 : 1;
        case 1: return 7; // 7种网络模式
        case 2: return 2; // SSID + BSSID
        case 3: return 3; // 纬度 + 经度 + 半径
        case 4: return 3; // 内购拦截 + 越狱隐藏 + UA篡改
        case 5: return 2; // 一键抹机 + 随机生成全部
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell;
    
    switch (indexPath.section) {
        case 0: {
            // 应用列表
            if (indexPath.row == 0) {
                // 刷新按钮
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                cell.textLabel.text = @"🔄 刷新应用列表";
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                return cell;
            }
            LSApplicationProxy *app = self.apps[indexPath.row - 1];
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            cell.textLabel.text = app.localizedShortName ?: @"未知应用";
            cell.detailTextLabel.text = app.bundleIdentifier;
            cell.imageView.image = [UIImage _applicationIconImageForBundleIdentifier:app.bundleIdentifier format:2 scale:[UIScreen mainScreen].scale];
            cell.imageView.layer.cornerRadius = 8;
            cell.imageView.layer.masksToBounds = YES;
            if (self.selectedApp && [self.selectedApp.bundleIdentifier isEqualToString:app.bundleIdentifier]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            } else {
                cell.accessoryType = UITableViewCellAccessoryNone;
            }
            return cell;
        }
        case 1: {
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
        case 2: {
            // SSID + BSSID
            EditableCell *editableCell = [[EditableCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            editableCell.textField.placeholder = indexPath.row == 0 ? @"SSID (如 WiFi-7A3F)" : @"BSSID (如 aa:bb:cc:dd:ee:ff)";
            editableCell.textField.text = indexPath.row == 0 ? self.inputSSID : self.inputBSSID;
            editableCell.textField.tag = 100 + indexPath.row;
            editableCell.textField.delegate = self;
            __weak typeof(self) weakSelf = self;
            editableCell.randomAction = ^{
                if (indexPath.row == 0) {
                    weakSelf.inputSSID = [NSString stringWithFormat:@"WiFi-%04X", arc4random_uniform(0xFFFF)];
                    editableCell.textField.text = weakSelf.inputSSID;
                } else {
                    weakSelf.inputBSSID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256),
                                           arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
                    editableCell.textField.text = weakSelf.inputBSSID;
                }
            };
            return editableCell;
        }
        case 3: {
            // 定位参数
            NSArray *placeholders = @[@"纬度 (如 39.9042)", @"经度 (如 116.4074)", @"漂移半径 (km)"];
            NSArray *values = @[self.inputLat ?: @"39.9042", self.inputLon ?: @"116.4074", self.inputRadius ?: @"5.0"];
            EditableCell *editableCell = [[EditableCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            editableCell.textField.placeholder = placeholders[indexPath.row];
            editableCell.textField.text = values[indexPath.row];
            editableCell.textField.keyboardType = indexPath.row == 2 ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDecimalPad;
            editableCell.textField.tag = 200 + indexPath.row;
            editableCell.textField.delegate = self;
            __weak typeof(self) weakSelf = self;
            // 每个定位参数独立随机生成按钮
            editableCell.randomAction = ^{
                double lat = 21.0 + (double)arc4random()/UINT32_MAX * 18.0;
                double lon = 100.0 + (double)arc4random()/UINT32_MAX * 20.0;
                double radius = 1.0 + (double)arc4random()/UINT32_MAX * 20.0;
                if (indexPath.row == 0) {
                    weakSelf.inputLat = [NSString stringWithFormat:@"%.4f", lat];
                    editableCell.textField.text = weakSelf.inputLat;
                } else if (indexPath.row == 1) {
                    weakSelf.inputLon = [NSString stringWithFormat:@"%.4f", lon];
                    editableCell.textField.text = weakSelf.inputLon;
                } else {
                    weakSelf.inputRadius = [NSString stringWithFormat:@"%.1f", radius];
                    editableCell.textField.text = weakSelf.inputRadius;
                }
            };
            return editableCell;
        }
        case 4: {
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
                // UA 带随机按钮
                EditableCell *editableCell = [[EditableCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                editableCell.textField.placeholder = @"自定义 UA (留空使用默认)";
                editableCell.textField.text = self.inputUA;
                editableCell.textField.tag = 300;
                editableCell.textField.delegate = self;
                __weak typeof(self) weakSelf = self;
                editableCell.randomAction = ^{
                    NSArray *versions = @[@"17.4", @"17.3", @"17.2", @"17.1", @"16.6", @"16.5", @"16.4"];
                    NSString *ver = versions[arc4random_uniform((uint32_t)versions.count)];
                    weakSelf.inputUA = [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                                        [ver stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
                    editableCell.textField.text = weakSelf.inputUA;
                };
                return editableCell;
            }
        }
        case 5: {
            // 操作按钮
            if (indexPath.row == 0) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                cell.textLabel.text = @"🚀 一键抹机 (应用选中的 App)";
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
            if (indexPath.row == 0) {
                [self loadApps];
                return;
            }
            self.selectedApp = self.apps[indexPath.row - 1];
            [tableView reloadData];
            break;
        }
        case 1: {
            self.selectedNetworkMode = indexPath.row;
            [tableView reloadData];
            break;
        }
        case 4: {
            if (indexPath.row == 0) {
                self.bypassIAP = !self.bypassIAP;
                [tableView reloadData];
            } else if (indexPath.row == 1) {
                self.jailbreakHide = !self.jailbreakHide;
                [tableView reloadData];
            }
            break;
        }
        case 5: {
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

#pragma mark - 执行抹机
- (void)executeWipe {
    if (!self.selectedApp) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 提示" message:@"请先选择一个目标应用" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *bundleID = self.selectedApp.bundleIdentifier;
    
    // 构建配置
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithDictionary:GenerateCommercialSeedProfile()];
    config[@"WifiSSID"] = self.inputSSID ?: @"WiFi-0000";
    config[@"WifiBSSID"] = self.inputBSSID ?: @"00:00:00:00:00:00";
    config[@"LocationLat"] = @([self.inputLat doubleValue] ?: 39.9042);
    config[@"LocationLon"] = @([self.inputLon doubleValue] ?: 116.4074);
    config[@"LocationRadius"] = @([self.inputRadius doubleValue] ?: 5.0);
    if (self.inputUA.length > 0) config[@"UserAgent"] = self.inputUA;
    config[@"BypassIAP"] = @(self.bypassIAP);
    config[@"JailbreakHide"] = @(self.jailbreakHide);
    
    // 网络模式
    NSArray *netModes = @[@"normal", @"flight", @"nosim", @"mobile", @"unicom", @"telecom", @"broadnet"];
    config[@"NetworkMode"] = netModes[self.selectedNetworkMode];
    
    // 运营商对应
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
