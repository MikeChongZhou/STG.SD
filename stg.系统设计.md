# Screen Time Guardian 需求文档

1. 项目概述
Screen Time Guardian，简称 STG，是一个跨平台屏幕用时守护应用。应用目标是在 macOS、Windows、iOS/iPadOS、Android 上记录屏幕用时，提醒用户休息和切换姿势，并通过用户自己的私人云盘在多设备之间汇总和同步数据。
应用应以实际可用的桌面或移动端体验为目标，而不是只提供工程骨架。各平台功能、数据结构、同步机制、图标、主要界面和关键交互规则应尽量一致。
2.系统需求
1.性能需求：各app应该尽量短小精悍，尺寸小，运行快，占内存少，占cpu少，
2.减少功耗和流量，流程简短，数据精简。
3.可靠性，异常情况下应该能保证运行，并尽量保持数据一致性。云端操作失败时应自动重试（指数退避），离线期间的同步操作进入待同步队列，恢复网络后自动补传。
4.安全：本地数据库不加密；同步数据仅保存到用户自己授权的私人云盘，不使用同步码，也不进行应用层加密。云盘的访问凭据必须使用各平台的系统安全存储保存，不得写入数据库、日志或同步文件。
5.易用性：app 的设置，界面，报告，通知，应该容易理解，容易使用。
6.可测试性：各个逻辑节点的判断、数值和提示信息写入log，log容易导出；四个平台在确认导出成功后均清空当前日志。单个活动日志文件上限为1MB，超过上限时从最旧内容开始删除800KB，保留最新内容继续记录。数据库和全局数据也支持导出。
7.长使用期假设：这个app要假设会在用户设备上运行几年甚至几十年，不要把数据放在app内存，应该有内存和外存区分运用，甚至对于外存也要注意存储大小的控制
8. 各app 安装应该尽量顺滑，权限设置按序进行
9. 各app的各个界面和报告，应该美观，能看清，风格统一，如果当前屏幕显示不完整，应该提供左右和上下滑钮
10. 卸载清理：Windows卸载程序必须删除STG创建的开机启动注册表项、诊断文件和本机凭据；其他平台清理由操作系统卸载机制可删除的App容器数据。iOS没有可靠的卸载回调，不能承诺在卸载瞬间执行应用代码或删除系统保留的Keychain项目。

3. 界面需求
1.各平台界面保持一致，除了各平台自身独特的部分。
2.界面、对话框、通知、权限引导、错误信息和导出字段说明均本地化，首批必须支持英文、简体中文和西班牙语；找不到对应翻译时回退英文。设置中提供语言选择，顺序为“跟随系统（默认）”、English、中文、Spanish；选择明确语言时应用界面使用该语言，选择跟随系统时使用操作系统的App语言。各平台应使用正式资源体系（Apple `Localizable.strings`/String Catalog、Windows `.resx`、Android `strings.xml`），不得继续把主要用户文字散落硬编码在业务代码中。
3.超时或休息提醒的倒计时应按真实时间计算，即使应用后台、锁屏或屏幕关闭也应继续往前走。
4. 各平台应用图标、macOS菜单栏图标、Windows托盘图标及Android通知小图标应统一使用STG“盾牌 + STG字样”品牌体系；通知小图标按平台要求提供单色版本，不使用emoji或无关的系统占位图标。
5. 应用菜单关于窗口中应显示应用名、版本号、开发者、版权和简要使用说明，第三方开源声明，保留原作者的版权声明和License文本（如MIT、Apache 2.0）。四个平台均应提供可点击的第三方许可证链接；至少包括Swift的`https://www.swift.org/LICENSE.txt`（使用Swift的平台）和SQLite的`https://www.sqlite.org/copyright.html`，并列出各自实际打包的其他第三方组件。iOS和Android不得只显示不可点击的说明文字。
6. 关于窗口应增加使用说明：使用你的私人云盘同步多个设备以统计总屏幕使用时间；数据仅保存于本地和用户授权的私人云盘，不会上传给app开发者；请注意各个设备应使用同一个私人云盘；每使用屏幕20分钟提醒眼睛休息，每使用屏幕40分钟提醒姿势切换，每天各屏幕累计使用超过自定限额后提醒休息；iOS受系统能力限制，分钟点图及跨设备去重累计用时为估算值；app语言默认跟随系统，也可在设置中明确选择英文、简体中文或西班牙语。
7.主界面包括标题、四个子框和状态栏，标题显示Screen Time Guardian。报告含当日摘要（设备集今日去重累计用时、本机累计用时和Daily Limit）；Tracking子框必须读取最新一个完整周的数据，按Total Tokens显示排名前两位的模型及其主要数值，不得只显示入口说明；设置显示共性设置字段和值；关于显示版本、说明和隐私。状态栏显示最近一次同步类型、时间及上传下载状态。
3.1 macOS
- 应作为菜单栏应用运行，但是也可以显示主界面，主界面关闭、最小化时则退回菜单栏。
- 菜单应包含主界面、报告、设置、跟踪、关于、退出。
- 主界面的报告、跟踪、设置、关于四个子框均为按钮，进入与菜单栏对应项相同的窗口。
- 主界面设置摘要中，自动会议检测始终启用且手动会议模式未选择时显示`Meeting auto-detect: On`；用户在设置中选择手动会议模式后显示`Meeting Mode: On`，不得以`Meeting Mode: Off`误导用户认为会议检测已关闭。
3.2 Windows
- 应作为系统托盘应用运行。但是也可以显示主界面，主界面关闭、最小化时则退回托盘。
- 菜单应与 macOS 对齐：主界面、报告、设置、跟踪、关于、退出。
- 主界面设置摘要采用与macOS相同的会议状态规则：默认显示`Meeting auto-detect: On`，手动会议模式打开后显示`Meeting Mode: On`。
3.3 iOS/iPadOS
-应作为普通app运行
- iOS 超时后不得限制、屏蔽或阻止任何 App，只能按提醒规则提示用户。
3.4 Android
-应作为普通app运行
- 超时后不得限制、屏蔽或阻止任何 App，只能按提醒规则提示用户。
- Today、Report、Tracking、Settings等所有顶层页面必须应用状态栏、摄像头开孔和Display Cutout安全区，不得把标题、按钮或首行内容绘制到系统栏或摄像头下方。
- Settings项目顺序和分组应尽量与iOS保持一致；Android专有权限和倒计时项目可以作为对应分组的补充，不应打乱Daily Limit、私人云、屏幕使用权限、通知、提醒、语言和诊断的主要顺序。
4.数据方案
4.1. 数据库总体
4.1.1 使用sqlite 方案 或其他数据库方案，不要使用文本文件模式；
4.1.2 常驻app内存的要尽量简短，不要把数据库放入内存
4.1.3 历史详细数据不需要长期存储，需要考虑数据的删除或压缩方案
4.2. 全局数据
如下变量是app全局数据：V屏幕连续使用时间，V本设备累计用时，V设备集去重累计用时，V上次姿势切换时间，V上次护眼时间，V其他设备ID列表，V点图修改时间。

数据库和全局数据的初始化，参考6.2 app安装章节。
4.3.数据表
4.3.1 屏幕使用点图使用一张统一的点图表，字段包括 deviceID、UTC日期、点图（1440个二进制bit）、修改时间，主键为 deviceID+UTC日期。deviceID 为各设备ID；设备集汇总使用保留值 alldevices。alldevices 数据属于可重新计算的汇总数据，由各设备点图按位去重合并得到。
点图内部按UTC分钟索引，每行表示一个完整UTC自然日。报告按查看报告设备的当前系统时区重新切分自然日：一个本地自然日需要从相邻UTC日期的点图中截取并合并；夏令时切换日按该时区当天的实际分钟数处理，不强制视为1440分钟。报告时区不作为用户设置显示或同步。系统时钟本身发生偏差不属于时区转换能够修正的范围。
提醒逻辑和报告中的日、周、月、年边界均按当前设备的系统时区判断；改变系统时区只影响报告的切分和显示，不改变已经保存的UTC原始点图。
4.3.2 设备表，包含 数据编号，设备ID，设备名称，设备种类，主键为设备ID
本机的数据编号设置为1；
关于设备ID
- 每台设备应有稳定的 `device_id`。
- macOS：IOPlatformUUID；iOS/iPadOS：Keychain UUID；Windows：主板 UUID / BIOS GUID；Android：Android ID 派生 UUID
- 移动端的 `device_id` 应持久化到 Keychain/Keystore，在更换 Wi-Fi、IP 变化、应用重启、重装后保持不变。
4.3.3 设置表，包括设置修改时间、本机deviceID、设备名称、`daily_limit_minutes`、Daily Limit提醒关闭倒计时、护眼提醒关闭倒计时、姿势切换提醒关闭倒计时、系统启动时自动启动。设置表为单行记录，不设主键。所有平台面向用户的名称统一为“Daily Limit”及其本地化译文，不再显示“Daily Goal”。

4.3.4 设备同步状态表 `sync_state`，每个本机deviceID一行，至少包括：
- `device_id`（主键）
- `last_quick_upload_at`、`last_quick_bidirectional_at`、`last_incremental_sync_at`
- `last_statistics_at`、`last_weekly_action_at`、`last_yearly_action_at`
- `last_posture_at`、`last_eye_at`、`last_reminder_kind`、`bitmap_updated_at`
- `continuous_minutes`、`local_daily_minutes`、`aggregate_daily_minutes`、`state_local_date`

博客功能已取消，不建立或保留“上次博客刷新时间”。所有数据库时间戳统一使用Unix秒；日期字段使用明确的本地日期或UTC日期字符串，具体由字段语义决定，不得混用毫秒时间戳。

4.3.5 同步与维护辅助表：
- `pending_quick_upload`：`device_id`、`utc_date`、`queued_at`，主键为`device_id+utc_date`，保存离线待上传点图。
- `incremental_download_cursor`：`remote_device_id`、`latest_utc_date`、`updated_at`，主键为`remote_device_id`。
- `incremental_upload_cursor`：`sync_target`、`latest_utc_date`、`updated_at`，主键为`sync_target`。上传和下载都按游标日期（含该日）处理，不能每次无条件重传全部文件。
- `maintenance_state`：`action`、`completed_period`、`completed_at`、`updated_at`，记录完整周动作、年动作和归档步骤，主键为`action`，使中断后的动作可以幂等续跑。
- `statistics_state`：单行记录`last_statistics_at`、`dirty_from_date`、`updated_at`。点图或同步数据发生变化时，把`dirty_from_date`向前推进到最早受影响的报告日期。
- `archive_manifest`：`archive_id`、`kind`、`period_start`、`period_end`、`local_path`、`cloud_path`、`checksum`、`created_at`、`uploaded_at`、`status`，用于验证历史压缩包上传成功后再删除源数据。

4.3.6 统计表（周号采用ISO 8601标准）：
1. `daily_statistics`：`device_id`、`report_date`、`minutes`、`daily_limit_minutes`、`source_updated_at`、`calculated_at`、`estimated`；主键为`device_id+report_date`。
2. `weekly_statistics`：`device_id`、`iso_year`、`iso_week`、`period_start`、`period_end`、`average_daily_minutes`、`included_days`、`excluded_days`、`calculated_at`、`estimated`；主键为`device_id+iso_year+iso_week`。
3. `monthly_statistics`：`device_id`、`year`、`month`、`period_start`、`period_end`、`average_daily_minutes`、`included_days`、`excluded_days`、`calculated_at`、`estimated`；主键为`device_id+year+month`。
4. `yearly_statistics`：`device_id`、`year`、`period_start`、`period_end`、`average_daily_minutes`、`included_days`、`excluded_days`、`calculated_at`、`estimated`；主键为`device_id+year`。

`alldevices`也作为一个device_id写入上述统计表，数值来自各设备点图的按位去重结果。`estimated=1`表示该周期包含iOS估算数据。统计刷新从`dirty_from_date`或上次统计日期中较早者开始（含首日），重新计算所有相交的日、周、月和年；成功提交后更新统计游标及`last_statistics_at`。

跟踪数据表：
1. OpenRouter公共排名周表 `openrouter_weekly`：窗口开始UTC日期、窗口结束UTC日期、`model_permaslug`、Rank、Input Tokens、Output Tokens、Total Tokens、Input Price、Output Price、Estimated Revenue、可空`as_of`、官方缺失日期列表、完整状态、更新时间；主键为窗口开始日期+`model_permaslug`。所有价格和收入字段均为估算口径并保留原始可计算精度。
2. 本阶段不建立 OpenRouter 月表、年表或博客表。任意日期区间排名按公开接口即时查询；长期趋势使用周表及其年度归档。

4.4 同步

- 私人云 同步，各app向个人用户云端写各自的设备数据，下载其他设备的数据。

- 三种Provider必须使用同一套逻辑文件结构：iCloud使用iOS/macOS创建的`Screen Time Guardian/ScreenTimeGuardian/sync`目录；Windows只查找并使用这个现有App Library目录，不得另建同名普通Folder，找不到时提示用户先在iOS或macOS配置iCloud并完成一次同步。OneDrive以Microsoft Graph App Folder为逻辑根；Google Drive以隐藏`appDataFolder`为逻辑根。下文`sync/`和`history/`均指各Provider逻辑根下的目录。

- 极速上传同步模式，如果点图修改时间晚于上次快速上传同步时间，则上传本次记录操作修改过的本机UTC点图行；通常只有当前UTC日期一行，iOS补录窗口跨越UTC午夜时应同时上传相邻的两行。否则下一步；上次快速上传同步时间更新为当前时间并记录到对应数据表。

- 快速上下同步模式，只同步当前UTC日期点图数据；如果本次iOS补录跨越UTC午夜，则相邻且被修改的UTC日期也一并同步。本机点图只上传不下载，其他设备点图只下载不上传。下载其他设备对应UTC日期点图(按照设备id列表直接生成文件名去get；若设备id列表为空，则先get网盘sync目录下的文件名，根据文件名解析生成其他设备id列表，再据此下载)，如果点图修改时间 晚于上次快速上下同步时间，则上传本机点图数据，文件名包含设备id和UTC日期，文件内容为点图；
否则下一步；上次快速上下同步时间更新为当前时间并记录到对应数据表。

- 增量同步模式：iOS利用BGAppRefreshTask、打开App或App内触发时执行；其他平台在App启动、唤醒、屏保/锁屏、解锁、提醒发出后或用户手动同步时执行。不另设独立的周期同步定时器。本机数据只上传不下载，其他设备数据只下载不上传。和快速同步的区别，一是同步多个日期的点图数据，二是同步设备表，三是包含每周动作和每年动作。具体如下：
1.文件名规则设计：
sync/deviceid_bitmap_08102026.json，文件名中的日期固定表示UTC日期，本周每个设备每日一个文件，上周一个文件，上上周一个文件,周文件以deviceid_bitmap_w33.json 方式命名
sync/deviceid_setting.json，本机设置信息，即设置表
OpenRouter周数据只做年度归档，不做跨设备同步；
所有同步JSON文件中增加一个保留字段（如reserved），供将来扩展使用，暂不设计格式版本号。
2.同步：
2.1 如果设置修改时间晚于上次增量同步时间，上传本机设置信息；首次同步时先读取云端同一deviceID的已有设置和点图并合并，再上传本机版本，避免新安装产生的空状态覆盖同一设备的云端历史。
2.2 每次增量同步先读取并核对私人云`sync/`目录中的设备文件名，从文件名解析当前云端设备ID集合，与本地设备表及V其他设备ID列表比较；发现新设备时加入本地设备表和V其他设备ID列表，后续同步立即纳入该设备。上传使用`incremental_upload_cursor`：上次游标为Y时，只核对并上传UTC日期Y及之后的本机点图。下载为每个远端设备i分别使用`incremental_download_cursor`中的X(i)，只核对并下载X(i)及之后的点图和设置文件；游标日期本身必须重查，以捕获同日后续修改。每日文件处理窗口上限为14天，更早历史依赖周文件和`history/`。只有相应文件成功核对或传输后才推进该方向游标；一次同步全部完成后更新上次增量同步时间。
    •    根据下载下来的点图，更新本地点图表，刷新V设备集去重累计用时
    •    根据下载下来的其他设备的设置信息，更新本地设备表，刷新V其他设备ID列表
    •    根据下载下来的其他设备的设置信息，核对共性字段，针对不同的字段，汇总给出一个表格让用户确认，本地的字段请他确认是否按照云端的数据修改？确认后，如果本地字段和云端不同，设置表的设置修改时间更新为当前时间，设置表上传云端，以便其他设备对照修改。用户直接关闭该对话框视为取消，不修改本机设置。
2.3 如果周动作完成周期早于上一个完整周，则从未完成的最早周开始逐周执行：
2.3.1 从本机每日点图生成上周本机周点图文件并上传；校验成功后删除云端除本周之外的本机每日点图文件；保留上上周周点图在`sync/`，把更早的本机周点图移入`history/`。移动、上传和删除均须幂等，失败时不得提前标记完成。
2.3.2 刷新OpenRouter周数据；完成全部步骤后把该周写入`maintenance_state`并更新周动作完成时间。
2.4 如果年动作完成周期早于上一完整自然年，则逐年执行：把去年点图和相关统计数据生成带校验值的压缩归档并上传`history/`；确认归档完整可读后，删除`history/`中已被年度归档覆盖的去年周点图文件，并删除本地数据库中的去年原始点图。把去年OpenRouter周数据导出为年度归档并上传`history/`；确认成功后清理本地数据库中前年及更早、且已经归档的OpenRouter周数据。不存在OpenRouter月表、年表或博客数据。全部步骤完成后记录年动作完成周期和时间；中断时必须根据`archive_manifest`续跑，不能重复生成冲突文件或先删后传。
2.5 LLM 数据刷新：周动作中从周表已有的最新完整周之后开始，逐周调用OpenRouter公开API补齐到上一个完整UTC自然周。任意日期至今的Top 20只在用户打开相应视图后查询。历史初始化数据由发行包内预生成的统一SQLite模板提供。
5. 核心功能需求
5.1 设置
- 设置中应包含：

可修改共性设置：
  - 每日计划用时（Daily Limit），默认10小时0分。四个平台统一使用小时和分钟两个控件分别编辑，分钟以15分钟为步进。每周一推荐上周平均值的功能属于后续功能，本阶段不要求实现；将来实现时只能作为用户确认后的推荐值，绝不能自动覆盖。

 - 护眼提醒的关闭倒计时为a分钟，a默认1分钟，姿势切换提醒的关闭倒计时为b分钟，b默认2分钟，Daily Limit提醒的关闭倒计时为c分钟，c默认为3分钟。
  - iOS不显示上述三个倒计时设置，因为系统通知本身可被用户直接划掉，App无法强制执行通知关闭倒计时。
  - 系统启动时自动启动，带可选框。这个选项在ios 不可用，所以不显示。
  - 会议模式，带 可选框，默认关闭。
  - macOS和Windows不提供本地数据目录查看或修改入口。

共性设置修改时，更新设置修改时间为当前时间。

个性设置：
  - 同步设置：同步方案显示当前设置的私人云，旁边有设置按钮，点击后询问用户该 app会在哪些设备使用，给四个可选框，ios, mac, android, win, 把当前的os默认选上并不允许去选，如果设备只是ios和mac，那么默认使用icloud进行各设备用时数据的同步，进行相关设置；如果有android 或win，则询问是否会去中国，是的话使用onedrive，否则使用googe drive进行相关设置。
  - 未完成同步设置时必须处于单机模式，点击同步只能提示先配置，不得自动读取系统中碰巧可用的iCloud容器或显示历史导入设备。
  - OneDrive 应通过 Microsoft 账号授权和 Microsoft Graph App Folder（最小权限 `Files.ReadWrite.AppFolder`）同步；不得用本地目录选择框代替账号登录。访问令牌和刷新令牌保存在Keychain等系统安全存储。
  - macOS/iOS 设置页应明确选择 iCloud Drive、OneDrive 或 Google Drive。选择后立即进入账号连接：iCloud 使用系统 Apple Account 与私有 ubiquity container；OneDrive 使用 Microsoft 登录窗口和 Graph App Folder；Google Drive 使用 OAuth/PKCE 与 `appDataFolder`。三者都不得用本地目录选择框代替账号授权。iOS 不允许第三方应用内登录系统 Apple Account，未登录时应说明该限制并打开系统设置入口。
  - Windows同样提供iCloud Drive、OneDrive和Google Drive。iCloud只能绑定已经由iOS/macOS创建并同步过的STG App Library目录，不创建替代目录；OneDrive和Google Drive必须完成账号授权。
  - Android完整私人云流程支持OneDrive和Google Drive，不使用SAF或普通目录选择器。OneDrive采用Device Code登录，最小scope为`offline_access User.Read Files.ReadWrite.AppFolder`，文件只存入Microsoft Graph App Folder。Google Drive采用OAuth 2.0 Authorization Code + PKCE，使用Google OAuth Desktop client的loopback回调并只访问隐藏`appDataFolder`。
  - Android的Google client secret从构建机Git忽略的`android/local.properties`中的`STG_GOOGLE_CLIENT_SECRET`或CI/进程环境变量注入；缺失时给出可执行的配置提示。secret、access token、refresh token不得写入源码、版本库、数据库、同步文件或日志；运行时凭据使用Android Keystore保护。
  - 账号授权成功不等于配置完成。必须继续验证账号资料和云端读写权限，并成功完成第一次增量同步，才保存该Provider为已配置。任何一步失败都保持原有配置；原本未配置时继续单机模式。瞬时DNS、连接或超时错误最多重试5次，退避0.5、1、2、4秒；认证、权限或配置类HTTP错误不得盲目重试，应显示可操作原因。

  - ios 权限设置：通知设置，应显示通知、声音、悬浮窗 permanent 状态，并提供按钮前往ios setting进行相关设置；screen time 设置应显示 相关权限状态，并提供按钮进行相关设置；
- android 权限设置：通知设置，应显示通知、声音、悬浮窗、Usage Stats 权限状态，并提供按钮前往android 系统设置界面 进行相关设置；

- 共性设置表各终端保持相同，个性设置不入数据表，不上传，只保留在本机。

- 设置窗口统一提供 Save 和 Close。没有配置修改时Save置灰；有修改时恢复可用。Close在没有修改时直接关闭；有修改时询问是否保存。不要单独提供Cancel按钮。
5.2 屏幕用时记录
1.应用需要记录屏幕使用，原始点图按UTC自然日保存，粒度为分钟，每个UTC日期有1440个数据点、180个字节，默认全0。数据库使用统一的屏幕使用点图表，包含UTC日期、设备ID、点图和修改时间，具体参考数据方案章节。本地日报及其他报告按查看设备的当前系统时区从相邻UTC日点图中重组。

2.win/macbook/安卓 监控屏幕情况，启动后数据初始化后，启用循环1分钟定时器；超时核查；“在使用屏幕”指当前屏幕处于激活状态（非屏保、非待机、非锁屏）；
2.1. 在使用屏幕则在当前UTC日期对应的点图行中，将本机点图和设备集点图的当前UTC分钟点打1；如果该UTC日期数据还没有，则先创建该行，写入UTC日期并将点图设为0。V点图修改时间设置为当前时间并记录到数据库；
2.2 如果当前时间的上一时间点图为0，则V屏幕连续使用时间=1，否则+1；如果 V屏幕连续使用时间>=20， 
2.2.1 如果上次提醒为护眼提醒，V屏幕连续使用时间=0，根据点图计算 V设备集去重累计用时和V本设备累计用时；如果V设备集去重累计用时超过计划用时，设置 V上次姿势切换时间和 V上次护眼时间为当前时间，并记录到数据库；触发超时提醒，否则，如果距离V上次姿势切换时间>=37, 设置 V上次姿势切换时间和V上次护眼时间为当前时间，并记录到数据库；触发姿势切换提醒；上次提醒=姿势切换提醒；V屏幕连续使用时间 =0;
2.2.2 否则，根据本机点图计算 V设备集去重累计用时和V本设备累计用时；如果设备集去重累计用时超过计划用时，设置 V上次姿势切换时间和V上次护眼时间为当前时间并记录到数据库；触发超时提醒，否则，如果 距离上次护眼时间>=17, 设置 V上次护眼时间为当前时间并记录到数据库；触发护眼提醒；上次提醒=护眼提醒；V屏幕连续使用时间 =0;
注：37=40-3、17=20-3，预留3分钟余量以容忍系统计时抖动；桌面端按分钟记录，个别分钟丢失误差不超过1分钟，无需补录机制。
提醒日期按设备当前系统时区计算。跨本地午夜时，把“上一次提醒类型”重置为“姿势切换提醒（posture）”；因此新一天首次满足提醒条件时进入2.2.2并优先产生护眼提醒。该重置状态必须持久化，App或后台服务在午夜后首次启动时也执行同样校正。
2.3. 每次成功发出提醒后，发起一次可合并的增量同步；不得为此另建独立周期同步定时器。
2.4 另外，设备在开机、唤醒、锁屏和解锁时，也触发增量同步；在休眠、待机和关机时，则触发快速上传同步。
锁屏事件必须先请求增量同步；休眠、待机和关机事件必须在操作系统允许的短暂执行窗口内请求快速上传。生命周期回调不得无限阻塞系统关机；超时或离线时把受影响UTC日期写入`pending_quick_upload`，下次联网或唤醒后补传。锁屏、屏幕关闭或睡眠期间暂停桌面/Android的一分钟活动采样，不得靠后台定时器把这些分钟记录为屏幕使用。

3.IOS 实现比较特殊，走deviceactivity/screentime 预约定时器方式，流程如下：
App启动，在screen time 注册一系列阈值，间隔20分钟，定时器触发后，
注册规则：DeviceActivityEvent使用includesPastActivity=false，只累计本次startMonitoring之后的活动。generation使用App Group中持久化的单调递增整数（1、2、3……）；普通启动App时，如果监控策略版本、监控范围和已注册activity均未变化，不停止或重启monitoring，也不增加generation。首次配置、用户修改App/Domain选择、系统中的监控确实丢失或安装新版本需要迁移监控策略时才重新注册；策略迁移只执行一次；已分配的generation即使注册失败也不重复使用。
不得使用“注册后60秒内一律拒绝回调”或其他固定时间窗口过滤。回调是否有效只能由当前activity、generation、event、本地日期和已处理事件集合判定；有效的新回调即使发生在注册后60秒内也必须处理。
3.1. 发起快速上下同步；
3.2 打点与事件判定：
3.2.3
    每日事件去重：在App Group中保存本地日期、generation及当日已处理event；相同“本地日期+generation+event”的回调只处理一次，重复回调不进行同步、打点或提醒。跨本地午夜自动建立新的当日事件集合。
    到达时间保护：在App Group中按当前generation持久化本地当日上次有效系统回调的到达时间。设本次与上次有效回调到达时间之间完整经过x分钟；当日没有上次回调时，以“本次monitoring注册时间”和本地午夜中较晚者作为起点。N=min(x,20)。同一批或间隔不足1分钟的不同阈值回调N=0，不打点、不发提醒；跨本地午夜自动以本地午夜为起点。
    打点：V点图修改时间设置为当前时间并记录到数据库，将当前时间对应UTC点位及其前面的N-1个分钟点打1，并更新设备集点图；窗口跨UTC午夜时分别写入相邻两行。阈值回调必须串行完成快速同步、判断、打点、上传和通知，避免多个回调同时读取同一旧点图。触发阈值数值不再用于向前补点或将本机点图补到阈值。
    DeviceActivity触发阈值是当前monitoring注册后的累计量，点图统计是本地当日累计量，两者不得直接比较；触发阈值只用于识别事件及决定护眼/姿势提醒类型，不参与打点数量计算。
注：20分钟阈值事件说明累计使用量到达了相应阈值，但具体使用区间与打点位置可能偏移，这是DeviceActivity机制的固有限制，系统不提供阈值到达的精确时刻，只能以回调到达时间近似。因此iOS点图、本机统计及跨设备去重统计均为估算值，不能声明总量完全不受影响；相关报告应使用“估算”标识。
3.3 计算V设备集去重累计用时，如果V设备集去重累计用时超过计划用时，触发当日计划超时提醒，设置 V上次姿势切换时间和V上次护眼时间为当前时间并记录到数据库；
3.4 否则，如果距离V上次护眼时间<23，并且距离V上次姿势切换时间>=37, 触发姿势切换提醒，设置 V上次姿势切换时间和V上次护眼时间为当前时间并记录到数据库；
3.5 否则，触发护眼提醒；设置V上次护眼时间为当前时间并记录到数据库；
3.6 另外，ios设备在BGAppRefreshTask，用户打开app，或用户启动同步时，触发增量同步；

全局变量是保存在App group全局，screentime要能够访问。

另外，ios 主app和 screentime extention中的代码要注意数据库写冲突的问题；因写冲突或时序造成的短暂数据误差可以接受，数据会持续刷新修正。

5.3 提醒
- 护眼提醒每 20分钟触发。Title: Time for an Eye Break
Body: Look at something 20 feet away for 20 seconds.

- 姿势切换间隔始终按护眼间隔的 2 倍计算，40 分钟。Title: Stand Up & Stretch
Body: Stand/walk around for 4 minutes and rest your eyes.

- 当日计划超时提醒，Title: Daily Limit Reached
Body: You’ve used your screen for xh ym today. Time to walk around for 5-min and rest your eyes.

- 非会议模式时提醒使用高重要性有声通知通道；会议模式时提醒使用静音通道。

- “关闭倒计时”语义：提醒弹出对话框后，其关闭按钮在对应倒计时（护眼a分钟、姿势切换b分钟、Daily Limit c分钟）结束前不出现，倒计时结束后才允许用户关闭。
- WIN/MAC/Android 普通模式下，提醒弹窗应有倒计时，倒计时结束后才能关闭。IOS 无法实现就算了。

- 会议模式是唯一允许立即关闭提醒的状态。会议模式开启时，提示文案固定为“会议模式：可以立即关闭”；会议模式关闭时，不得显示会议模式文案。会议模式有两个地方来判断，一个是设置里可以开启会议模式，另一个是提醒时判断当前有无会议/通话在进行中，进行中则打开会议模式。

- 会议模式下只显示提醒，不播放提醒声音；非会议模式下，移动端提醒应在用户已授权的前提下播放声音。
5.4 日报
- 本应用本机计时数据和同步来的其它设备数据都应进入同一报告体系。所有报告按查看设备的当前系统时区统计；报告包含iOS数据时，应清楚标明点图和跨设备去重结果为估算值。
- 报告应支持导出CSV到系统分享页或用户选择的位置；不提供复制报告功能。四个平台均不得保留可见的Copy按钮或不可达的复制事件处理代码。
- 进入报告界面，默认呈现当前日报，
- 进入报告界面时不要求等待正在进行的同步；应立即启动可合并的统计表增量刷新任务，针对`dirty_from_date`或上次统计日期之后的受影响数据进行汇总计算，获得各日、各周、各月、各年的各设备平均日用时及设备集去重平均用时并写入统计表。刷新成功后更新报告并把上次统计时间设置为当前Unix秒；若同步稍后写入更早日期，则通过`dirty_from_date`在下一次刷新重新计算。
-比如上一计算日是 7/10/2026，当前为 7/25/2026，则本次计算核算 7/10~7/25 的日数据，28/29/30周数据，7月数据，2026年数据；核算数据存入统计数据表，上一计算日设置为当日。上一计算日当天也重新核算（区间含首尾）；与计算区间相交的周/月/年均整体重新计算。
- 在核算周、月和年平均值时，只处理已经结束的本地自然日，单设备按实际用时计算（包含已记录的零用时日）；仅所有设备合计排除低于该日所保存`daily_limit_minutes`的60%的异常日。例如Daily Limit为10小时，2小时、2小时、10小时、10小时、10小时、10小时、10小时中的前两日被排除，平均值为10小时。无有效统计日时显示“—”，不绘制为零值；历史汇总从保留的日报记录重算。`included_days`和`excluded_days`必须同时保存，避免平均数失去解释依据；日报原始分钟数仍保留，不因排除算法而改写。

- 报告窗口应支持按日期查看日报。
- 日报应显示当天去重后的总用时，以及各设备用时；本周、上周、本月、上月和本年汇总去重后的平均日用时。
- 日报中的其它设备必须显示同步设置文件中的设备名称，不得以deviceID或deviceID前缀代替；历史数据缺少设备设置文件时显示通用名称“Other device”。
- macOS日报顶部应与iOS一致显示当日总结（所有设备、本机、Daily Limit），并提供明确的立即同步按钮和同步状态。
- 日报应列出当天各设备bitmap以及汇总bitmap。iOS/Android使用动态三小时区段，macOS/Windows使用动态六小时区段；只显示包含活动的区段，没有活动的设备保留同样宽度但缩短高度。小时标签清晰可读，分钟以紧凑点图显示。宽度不足时才提供横向滚动。
- 日报明细应使用表格或等价的对齐布局展示，列宽稳定、文本不挤在一起。

5.5 多日报
- 报告窗口提供三个折线图周期：灵活选择开始与结束日期的Multiple Days、当前Year by Week、多年Years by Month。
- 多日报由日/周/月统计表驱动，不在每次显示时重新全量扫描原始点图。
- 每台设备及alldevices各显示一条折线，以日期、ISO周或月份为X轴，以相应周期的平均日用时为Y轴，并显示图例。
- Multiple Days显示所选区间的汇总去重平均日用时；Year by Week读取周统计表，显示各ISO周的平均日用时；Years by Month必须直接读取月统计表，按自然月显示该月平均日用时，不得用周平均值、月内各周平均值或周表近似月值。
- 图表按屏幕大小缩放，字体必须清晰；宽度确实不足时提供横向滚动，内容过长时提供纵向滚动。
- 多日报支持导出CSV，不提供表格视图、设备筛选或复制功能。
5.6 OpenRouter 公共模型使用量排名跟踪
- 周趋势横轴使用完整 ISO 周号 `YYYY-Www`（例如 `2026-W40`），跨年周使用 ISO week-year。
- 实时数据源为 OpenRouter 排名页使用的公开聚合 API（`/api/frontend/v1/rankings/models` 与 `/api/frontend/v1/stats/model-activity`）；不要求用户登录或输入 API key，不读取个人账户 activity。
- 发行包的历史初始化种子使用官方 `GET /api/v1/datasets/rankings-daily` 在构建阶段下载，自 2025-01-01 起按完成的 UTC 自然周聚合。下载所用 API key 仅存在于构建环境，不得写入源码、种子或 App。该历史接口只发布 `total_tokens`，因此历史Input Tokens、Output Tokens和Estimated Revenue必须显示为不可用，不得按比例臆测；与已有更详细周记录冲突时保留已有记录。
- 周表保留`as_of`、官方缺失日期和完整状态字段，运行期接口明确提供时应保存。发行包内历史seed不强制补录官方缺失日期或在界面标记“不完整”；seed的`as_of`允许为NULL/空值，缺失日期可为空列表。不得仅凭未知状态编造具体缺失日期。
- `total_tokens` 为 OpenRouter 官方公共排名口径，即 prompt tokens 与 completion tokens 之和。
- 每行同时显示Input Tokens、Output Tokens、Total Tokens、OpenRouter公开的实际支付加权Input Price、实际支付加权Output Price和Estimated Revenue。价格来自公开`effective-pricing`接口，按实际token流量加权并包含缓存及Provider折扣，统一显示为USD/1M tokens；`Estimated Revenue = Input Tokens / 1,000,000 × Input Price + Output Tokens / 1,000,000 × Output Price`。它不得伪装成OpenRouter实际财务收入；App后续保存每次周动作取得的价格观测值，历史覆盖范围随运行时间增长。
- 跟踪窗口默认显示Weekly Trends；Top 10模型应随用户选择的指标重新排名。用户点击Top 20 Since Date后才查询所选开始日期至最近完成UTC日期的Top 20。移动端同样提供这两个视图。
- 所有公开排名展示均应包含归因：`Source: OpenRouter (openrouter.ai/rankings), as of {as_of}.`；seed的`as_of`为空时显示`as of unavailable`或等义本地化文字，不得显示空白占位。
5.6.1 本周跟踪窗口
- 显示上一个完整UTC自然周（上周一至上周日）的公共模型 total token Top 20，不使用 trailing 7 days。
- 应优先读取本周本地数据。
- 本地数据不存在时，应从 OpenRouter 公开排名及模型日活动 API 获取数据，按 `model_permaslug` 汇总窗口内 prompt tokens 与 completion tokens，降序取前20名并保存本地；同值时按 `model_permaslug` 升序，保证排序稳定。
- 表格字段为Rank、Model、Input Tokens、Output Tokens、Total Tokens、Input Price、Output Price、Estimated Revenue；四个平台必须使用同一列名，桌面端使用列宽稳定、可横向滚动的对齐表格。
- Estimated Revenue在界面中四舍五入为整数美元，不显示小数位，并使用千分位分隔符；CSV仍保留可计算的原始数值并使用`Estimated Revenue`列名。
- 表格列标题应支持点击排序。
- 同一列重复点击时，应在升序和降序之间切换。
- 某列第一次点击按从大到小排列，第二次点击按从小到大排列；无价格值固定排在有值数据之后。
- 排序逻辑应按字段真实类型排序：数字列按数字排序，文本列按文本排序，不能把数字当字符串排序。
- 跟踪表格横向滚动、排序和关闭按钮不能互相阻塞，点击多列排序后仍应能横向滚动并关闭页面。
- 桌面端至少支持导出包含全部显示字段、统计区间和当前排序结果的CSV；不提供复制功能。

5.6.2 Weekly Trends
读取本地OpenRouter周表，以所选指标对当前最近完整周重新排名并取Top 10，每个模型一条折线，展示已有各周数据。可选指标为表格中的任一数值列；收入指标在所有界面和导出中统一标注为Estimated Revenue。移动端图例必须置于折线图下方，不能覆盖折线、坐标轴或彼此堆叠。竖屏和横屏的X轴均至少显示关键周标签：第一周、最后一周，以及区间内的年份边界；不足三个关键点时补一个中间点。标签使用紧凑的两位年份加ISO周格式（如`25W33`、`26W01`、`26W25`），不得被裁切为只有年份前几位。

5.6.3 Top 20 Since Date
开始日期默认七天前。用户点击后按包含首尾日期的UTC自然日区间查询公共模型total token Top 20；区间只允许包含已经完成的UTC日期，其余字段、排序、价格、收入估算和桌面端导出要求与5.6.1相同。

5.7 目标博客更新跟踪
本阶段取消，不在各App中显示入口或占位内容；后续版本另行设计和实现。

5.8 诊断与数据导出
- 四个平台的Export Test Log统一只放在Settings，不在About或菜单栏重复提供。导出内容包含生命周期、权限、监控注册/系统回调、generation、同步模式与游标、文件上传下载、统计刷新、数据库路径或逻辑位置以及错误码，但必须脱敏，不记录token、secret、授权码或完整账号凭据。
- 日志使用滚动文件：活动文件最大1MB，超过时删除最旧800KB并保留最新约200KB继续写入。成功导出副本后立即清空当前活动日志；用户取消分享或导出失败时不得清空。
- 提供“Export Database and Global State”，导出SQLite数据库副本、非敏感全局状态、schema版本、设备/同步游标和归档清单，可打包为单个归档文件。导出前执行一致性快照，不得包含Keychain、Credential Manager、Android Keystore中的凭据或OAuth client secret。
- CSV报告和Tracking导出只导出相应业务数据；数据库/全局状态导出是独立诊断功能。所有包含Revenue的界面和文件统一使用`Estimated Revenue`名称并说明它不是OpenRouter实际财务收入。
6. 构建与部署
6.1 版本构建
- 每次修改，版本号向前进一步，基础版本1.0.0, 下一个版本1.0.1。
- 当前四个平台对齐的产品版本为1.1.9；Windows用户可见版本显示为`1.1.9`，不得显示为`1.1.9.0`。
- Android最低支持版本为Android 9（API 28）。
- Windows 发布包应优先使用 framework-dependent 模式，以缩小目标程序体积。
- Windows 目标机器缺少 .NET Desktop Runtime 时，应由 .NET apphost 检测并提示缺失运行库和 Microsoft 安装链接；文档中也应明确提供安装链接。

6.2 app 安装
6.2.1 App 安装时需要创建数据库，并对如下表进行初始化：
1.创建4.3规定的全部表和索引。同步状态表中，上次快速上传、快速上下、增量同步、姿势切换、护眼和点图修改时间初始化为当前本地日0时对应的Unix秒；周动作完成周期初始化为本周之前，年动作完成周期初始化为今年之前，使首次维护可以幂等补齐；`statistics_state.dirty_from_date`初始化为最早可统计日期，`last_statistics_at`初始化为0。不得通过伪造“已完成”时间跳过首次统计或维护。
2.设备表中写入本机信息：设备名称从系统获得，设备种类从系统判断，DeviceID如下：
  - macOS：IOPlatformUUID，- iOS/iPadOS：Keychain UUID
  - Windows：主板 UUID / BIOS GUID; - Android：Android ID 派生 UUID
设备表修改时间设置为当前时间。
3.设置表中写入`daily_limit_minutes=600`，护眼提醒关闭倒计时为1分钟，姿势切换提醒关闭倒计时为2分钟，Daily Limit提醒关闭倒计时为3分钟；`launch_at_login`在用户完成首次引导选择前默认为false，随后按用户选择保存。设置表修改时间设为当前Unix秒；Daily Limit在各平台均使用小时和分钟分别编辑，分钟按15分钟步进。
4.创建统一的屏幕使用点图表。不得仅因安装、打开报告或同步而自动为没有活动的设备/日期写入空点图；只有首次真实记录、收到远端文件或明确需要持久化数据时才创建点图行，避免空行遮蔽云端同一设备ID的历史数据。
5.发行包内的统一SQLite模板只预置OpenRouter历史数据和schema；安装时复制模板后再初始化本机设备、设置、同步和统计状态。四个平台的表结构、字段类型及时间单位必须一致。


6.2.2 app进行相关权限设置
- iOS首次设置依次完成：允许通知、引导将通知样式改为Persistent、授权Screen Time、选择需要记录的App和Domain。不得接受Category；检测到Category时提示并返回选择器。每一步只有Back或当前步骤的设置按钮，成功后自动进入下一步，不额外显示Continue。设置未完成时退出或取消，不得进入未配置主界面；再次启动必须从未完成步骤继续。
- Android首次设置使用与iOS一致的单步骤卡片风格，依次完成通知、悬浮窗、Usage Access等运行所需权限；每一步的主按钮直接执行授权并在成功后进入下一步，不另设Continue。必要权限未完成时不能绕过进入主界面。权限完成后进入完整私人云设置，用户可明确选择暂不连接并以单机模式完成。
- Windows/macOS首次设置采用相同引导风格：第一步说明私人云用于汇总多设备数据并询问是否立即连接，选择连接时必须跑完账号授权和首次同步；第二步说明会议模式行为及系统登录启动，再询问是否随系统登录启动。用户可选择暂不连接私人云，以单机模式完成设置。

6.2.3 app进行相关同步设置
提示当前处于单机模式，并询问是否现在连接私人云。用户选择连接后，询问STG将在哪些设备使用，显示iOS、macOS、Android、Windows四项；当前平台默认选中且不可取消。仅有iOS和macOS时推荐iCloud；包含Android或Windows时继续询问是否需要在中国大陆使用，需要时推荐OneDrive，否则推荐Google Drive。推荐结果可由用户改选，但实际可选项必须符合各平台能力。

选择Provider后必须完整执行账号授权、权限验证和第一次增量同步，而不是只保存Provider名称。iCloud需验证统一App Library容器可用；OneDrive需验证Graph App Folder；Google Drive需验证隐藏`appDataFolder`。成功后才将同步状态标为已配置。用户明确选择稍后设置时可继续单机模式；授权失败、网络失败或首次同步失败时不得留下半配置状态。
6.2.4 设置完成后，已连接私人云则启动增量同步；单机模式不发起云同步。
6.3 App 启动
App启动时进行全局数据初始化：
V屏幕连续使用时间和初始化为0；
V设备集去重累计用时从已有UTC点图重组当前设备系统时区下的当日数据后计算得到；没有点图时按0计算但不创建空行；
V本设备累计用时从已有UTC点图重组当前设备系统时区下的当日数据后计算得到；没有点图时按0计算但不创建空行；
V点图修改时间，V上次姿势切换时间 和 V上次护眼时间 数值从同步表获取；
V其他设备ID列表从设备表获取，排除本设备；

macOS、Windows和Android只设置屏幕活动采样所需的一分钟定时器，并在锁屏、屏幕关闭、休眠或待机时暂停；各平台均不设置独立循环同步定时器。iOS不使用一分钟活动采样定时器。

完成上述初始化后，启动增量同步；

6.4 ios app从后台到前台

启动增量同步；
