package core

import (
	"io"
	"strings"
	"testing"
	"time"
)

func TestNativeStreamMeterReportsRate(t *testing.T) {
	var meter nativeStreamMeter

	// 首次取样只做校准，没有可比较的区间，必须给 0 而不是把累计量当成速率。
	if got := meter.bytesPerSecond(); got != 0 {
		t.Fatalf("首次取样应返回 0，实际 %d", got)
	}

	meter.add(4096)
	meter.mu.Lock()
	meter.at = time.Now().Add(-2 * time.Second)
	meter.mu.Unlock()
	if got := meter.bytesPerSecond(); got < 1500 || got > 2600 {
		t.Fatalf("4096 字节 / 2 秒 速率异常：%d", got)
	}

	// 空闲一个窗口后应回落到 0，否则播放页会一直显示上次的网速。
	meter.mu.Lock()
	meter.at = time.Now().Add(-2 * time.Second)
	meter.mu.Unlock()
	if got := meter.bytesPerSecond(); got != 0 {
		t.Fatalf("空闲后应回落为 0，实际 %d", got)
	}
}

func TestNativeCountingReaderCountsForwardedBytes(t *testing.T) {
	var meter nativeStreamMeter
	reader := &nativeCountingReader{
		source: strings.NewReader("0123456789"),
		meter:  &meter,
	}
	written, err := io.Copy(io.Discard, reader)
	if err != nil {
		t.Fatalf("转发失败：%v", err)
	}
	if written != 10 {
		t.Fatalf("应转发 10 字节，实际 %d", written)
	}
	meter.mu.Lock()
	total := meter.total
	meter.mu.Unlock()
	if total != written {
		t.Fatalf("计量应等于转发量：total=%d written=%d", total, written)
	}
}
