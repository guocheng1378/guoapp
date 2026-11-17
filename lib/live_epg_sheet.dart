import 'package:flutter/material.dart';

import 'glass.dart';
import 'live_models.dart';

/// 节目时钟标签（本地时间 HH:mm）。
String liveEpgClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// 「现在正在播」的一行描述：`正在播 · 新闻联播`；
/// 没有正在播的节目但有下一档时退化成 `22:00 电视剧`。
String? liveEpgBanner(LiveEpgChannel? channel, DateTime now) {
  if (channel == null) return null;
  final current = channel.now;
  if (current != null && current.title.isNotEmpty) {
    return '正在播 · ${current.title}';
  }
  final next = channel.next;
  if (next != null && next.title.isNotEmpty) {
    return '${liveEpgClock(next.start)} ${next.title}';
  }
  return null;
}

/// 频道节目单弹层：当日节目表，正在播的高亮并带进度条。
///
/// 无 EPG（未配置源 / 该台未匹配）时不弹层，由调用方给提示，避免空白面板。
Future<void> showLiveEpgSheet(
  BuildContext context, {
  required LiveEpgChannel channel,
}) {
  final now = DateTime.now();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(sheetContext).size.height * 0.72,
      ),
      child: GlassSurface(
        key: const Key('live-epg-sheet'),
        radius: 22,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        tint: GlassTint.sheet,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '今日节目单',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(
                        sheetContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (channel.now != null) _nowCard(sheetContext, channel.now!, now),
              const SizedBox(height: 6),
              Flexible(
                child: ListView.builder(
                  key: const Key('live-epg-program-list'),
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  itemCount: channel.programs.length,
                  itemBuilder: (context, index) {
                    final program = channel.programs[index];
                    return _programRow(context, program, now);
                  },
                ),
              ),
              if (channel.programs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      '该频道暂无节目单',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(
                          sheetContext,
                        ).colorScheme.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _nowCard(BuildContext context, LiveProgram program, DateTime now) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
    decoration: BoxDecoration(
      color: scheme.primary.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '正在播',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                program.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${liveEpgClock(program.start)}-${liveEpgClock(program.start.add(program.duration))}',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: program.progressAt(now),
            minHeight: 3,
            backgroundColor: scheme.onSurface.withValues(alpha: 0.10),
          ),
        ),
      ],
    ),
  );
}

Widget _programRow(BuildContext context, LiveProgram program, DateTime now) {
  final scheme = Theme.of(context).colorScheme;
  final onAir = program.isOnAir(now);
  final passed = program.start.add(program.duration).isBefore(now);
  final color = onAir
      ? scheme.onSurface
      : scheme.onSurface.withValues(alpha: passed ? 0.38 : 0.72);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Text(
            liveEpgClock(program.start),
            style: TextStyle(
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: onAir ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: onAir ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            program.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              color: color,
              fontWeight: onAir ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        if (onAir) ...[
          const SizedBox(width: 6),
          Text(
            '直播中',
            style: TextStyle(fontSize: 11, color: scheme.primary),
          ),
        ],
      ],
    ),
  );
}
