真果鉴 v0.2.96+2258 发布说明

本次为榜单/目录、真果·鉴（dongpiandi）、播放器与追剧体验的一轮集中修复与优化（构建自 2258 工作树，含此前 4 轮审计的全部改动）。

【榜单与目录】
· 红果榜单季数/集数显示修正：不再把 vid 分片误算成集数（Episodes=0 清理、去掉 len(EpisodeIDs) 误赋值）
· 所有源排序/筛选跨源归一：热度、评分按各源最大值归一后再混合排序，不再被单源量纲带偏
· 分组去重：同名异写合并（归一化名称），移除硬编码分组；目录会话 key 纳入 group.id + 原始分类，sort 命中不再回退基础缓存
· 分类去重与浮动区/年份过滤：纯数字内容池隐藏双内容 tab，源上报短剧优先于本地短剧

【真果·鉴（dongpiandi）】
· 进入/切集卡顿大幅优化：详情懒解析只解首集（其余仅保留 ID/PageURL）、死链缓存快起播（过滤同源死线）、换线转入后台（routes 新 action），backfill 上限 48→8、存活探测 3s→1s
· 倍速缓存按 LRU 回收：key=线路ID+去参 URL，超限淘汰最久未用
· PlaybackPlan.withRoutes：选路面板打开时预填线路

【播放器】
· 新增切线路面板（playbackRoutes），切换/刷新线路更顺手
· 修复进度误判「从头播完」：完成 tolerance 取 duration*0.05 并夹在 2–10s，进度写入跳过 seek 后 1s 与越界
· 边下边看时，正在播放的线路不再被后台任务挤占

【追剧 / 收藏】
· 集数自修复：加 profileEpoch 守卫 + 400ms 节流（测试态跳过）+ 脏值过滤
· 更新计数按 FollowState.hasUpdates 差量；列表按「有更新」再按观看时间排序

【交互与性能】
· 电视搜索键盘收起：_pop 先 unfocus 再 Navigator.pop
· 雾面顶栏：单层 BackdropFilter（无 shader 时）、RouteTransitionSignal.reversing 时跳过 backdrop；fogFab 复用同一 ImageFilter
· 下载汇总定时器：测试态（Motion.inTest）跳过 periodic
· 二级页改用 ListView.builder

如更新后某源异常，请在设置中反馈或联系 QQ：963484350。
