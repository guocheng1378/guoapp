import 'dart:typed_data';

import 'package:duanju_app/fog_tint_sampler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fogTintFromRgba 纯函数', () {
    test('纯色图行带平均 → 亮度/饱和整形后的同色相浅色', () {
      // 全红：加权平均 = 红（同色像素权重一致）。
      final raw = Uint8List(16 * 4);
      for (var i = 0; i < 16; i++) {
        raw[i * 4] = 180; // R
        raw[i * 4 + 1] = 20; // G
        raw[i * 4 + 2] = 30; // B
        raw[i * 4 + 3] = 255;
      }
      final tint = fogTintFromRgba(raw, 4, 4);
      expect(tint, isNotNull);
      final hsl = HSLColor.fromColor(tint!);
      // 色相保留红系（~350°附近），饱和度封顶 0.55，亮度拉进浅色区。
      // 0.55 封顶经 HSL→RGB 整数往返读回会放大 ~+0.003（如 0.5529），
      // 断言留容差。
      expect(hsl.hue, inInclusiveRange(330, 360));
      expect(hsl.saturation, lessThanOrEqualTo(0.556));
      expect(hsl.lightness, inInclusiveRange(0.49, 0.92));
    });

    test('浓色像素主导色相（饱和度加权平均）', () {
      // 白底网格 + 1 个浓色像素：普通平均几乎无色感（首页「调到顶
      // 没效果」的真因），加权后浓色像素主导，tint 应偏红可感知。
      final raw = Uint8List(16 * 4);
      for (var i = 0; i < 16; i++) {
        raw[i * 4] = 255;
        raw[i * 4 + 1] = 255;
        raw[i * 4 + 2] = 255;
        raw[i * 4 + 3] = 255;
      }
      // 浓红必须落在默认带 [0, 0.25) 内（4×4 图即行 0，像素 0-3），
      // 否则不进采样、wsum=0 回落纯白（探针实锤的假失败）。
      const o = 3 * 4;
      raw[o] = 200; // 一格浓红海报 (200,30,40)
      raw[o + 1] = 30;
      raw[o + 2] = 40;
      final tint = fogTintFromRgba(raw, 4, 4);
      expect(tint, isNotNull);
      final hsl = HSLColor.fromColor(tint!);
      expect(hsl.hue, inInclusiveRange(340, 360), reason: '色相应被浓色主导');
      expect(hsl.saturation, greaterThan(0.35), reason: '饱和度应可感知');
    });

    test('行带裁剪：只平均指定区间行', () {
      // 4×4：上 2 行蓝、下 2 行黄。band [0.25, 0.75) → 取第 1..2 行
      //（0-indexed floor(1)=1 到 ceil(3)=3，即行 1、2）= 蓝+黄混合。
      final raw = Uint8List(16 * 4);
      for (var y = 0; y < 4; y++) {
        final isBlue = y < 2;
        for (var x = 0; x < 4; x++) {
          final o = (y * 4 + x) * 4;
          raw[o] = isBlue ? 0 : 220;
          raw[o + 1] = isBlue ? 80 : 200;
          raw[o + 2] = isBlue ? 255 : 40;
          raw[o + 3] = 255;
        }
      }
      final band = fogTintFromRgba(raw, 4, 4, bandStart: 0.25, bandEnd: 0.75);
      expect(band, isNotNull);
      // 行 1=蓝(0,80,255) 权重 255、行 2=黄(220,200,40) 权重 180，
      // 加权平均≈(91,130,166)，整形后亮度 0.5–0.92、饱和 ≤0.55
      //（往返容差同上）。
      final hsl = HSLColor.fromColor(band!);
      expect(hsl.lightness, inInclusiveRange(0.49, 0.92));
      expect(hsl.saturation, lessThanOrEqualTo(0.556));
    });

    test('字节不足/空尺寸返回 null（静默回落白色）', () {
      expect(fogTintFromRgba(Uint8List(4), 4, 4), isNull);
      expect(fogTintFromRgba(Uint8List(16 * 4), 0, 4), isNull);
      expect(fogTintFromRgba(Uint8List(16 * 4), 4, 0), isNull);
    });
  });

  group('FogTintSampler widget', () {
    testWidgets('测试环境默认禁用：直通 child、不采样', (tester) async {
      final tint = ValueNotifier<Color?>(null);
      await tester.pumpWidget(
        MaterialApp(
          home: FogTintSampler(
            tint: tint,
            child: const ColoredBox(color: Colors.red),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tint.value, isNull); // 未采样 → 雾面回落纯白
      tint.dispose();
    });
  });
}
