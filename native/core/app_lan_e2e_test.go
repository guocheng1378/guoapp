package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
)

func lanTestAccount(t *testing.T) string {
	t.Helper()
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(value)
}

func lanTestCall(t *testing.T, engine *nativeEngine, command string, lan map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(lan)
	if err != nil {
		t.Fatal(err)
	}
	value, err := engine.nativeLAN(context.Background(), command, raw)
	if err != nil {
		t.Fatalf("%s: %v", command, err)
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var output map[string]any
	if err := json.Unmarshal(encoded, &output); err != nil {
		t.Fatalf("%s: 解码失败 %v", command, err)
	}
	return output
}

// fakePeerChannel 模拟 Dart 侧的事件循环：poll → 处理 pair/status → respond。
type fakePeerChannel struct {
	engine      *nativeEngine
	gen         string
	config      map[string]any
	peerID      string
	peerPin     string
	polls       int
	events      int
	respond     int
	accepted    []bool
	eventBodies []map[string]any
	lastErr     error
}

func (c *fakePeerChannel) run(stop <-chan struct{}) {
	for {
		raw, _ := json.Marshal(map[string]any{"generation": c.gen})
		value, err := c.engine.nativeLAN(context.Background(), "poll", raw)
		if err != nil {
			c.lastErr = err
			return
		}
		c.polls++
		event, ok := value.(map[string]any)
		if !ok || event["event"] == nil {
			select {
			case <-stop:
				return
			default:
			}
			continue
		}
		c.events++
		eventRaw, err := json.Marshal(event["event"])
		if err != nil {
			c.lastErr = err
			return
		}
		var body map[string]any
		if json.Unmarshal(eventRaw, &body) != nil {
			c.lastErr = errors.New("事件解码失败")
			return
		}
		c.eventBodies = append(c.eventBodies, body)
		path, _ := body["path"].(string)
		payload, _ := body["payload"].(string)
		var request map[string]any
		_ = json.Unmarshal([]byte(payload), &request)
		response := map[string]any{}
		failure := ""
		switch path {
		case "pair":
			grant, err := c.engine.nativeLAN(context.Background(), "allow", func() []byte {
				raw, _ := json.Marshal(map[string]any{
					"generation": c.gen, "deviceId": c.peerID, "pin": c.peerPin,
				})
				return raw
			}())
			if err != nil {
				c.lastErr = err
				return
			}
			token := ""
			if grantMap, ok := grant.(map[string]string); ok {
				token = grantMap["token"]
			}
			response = map[string]any{
				"name": c.config["name"], "kind": c.config["kind"],
				"account": c.config["account"], "user": c.config["user"],
				"sources": c.config["sources"], "sourceOptions": c.config["sources"],
				"autoSync": c.config["autoSync"], "token": token,
			}
		case "status":
			response = map[string]any{
				"name": c.config["name"], "kind": c.config["kind"],
				"account": c.config["account"], "user": c.config["user"],
				"sources": c.config["sources"], "sourceOptions": c.config["sources"],
				"autoSync": c.config["autoSync"], "manual": false,
				"syncing": false, "playing": "", "hash": "0",
			}
		default:
			failure = "不支持此设备操作"
		}
		rawRespond, _ := json.Marshal(map[string]any{
			"generation": c.gen, "eventId": body["id"], "payload": response, "error": failure,
		})
		if replyValue, err := c.engine.nativeLAN(context.Background(), "respond", rawRespond); err != nil {
			c.lastErr = err
		} else {
			c.respond++
			replyMap, _ := replyValue.(map[string]bool)
			c.accepted = append(c.accepted, replyMap["accepted"])
		}
	}
}

// TestNativeLANEndToEnd 双端完整链路：start → allow → pair → status → probe。
func TestNativeLANEndToEnd(t *testing.T) {
	dirA, dirB := t.TempDir(), t.TempDir()
	engineA, err := newNativeEngine(dirA)
	if err != nil {
		t.Fatalf("engineA: %v", err)
	}
	engineB, err := newNativeEngine(dirB)
	if err != nil {
		t.Fatalf("engineB: %v", err)
	}
	configA := map[string]any{
		"name": "电脑A", "kind": "computer", "account": lanTestAccount(t),
		"sources": []string{}, "autoSync": true,
	}
	configB := map[string]any{
		"name": "手机B", "kind": "phone", "account": lanTestAccount(t),
		"sources": []string{}, "autoSync": true,
	}
	infoA := lanTestCall(t, engineA, "start", map[string]any{"config": configA})
	infoB := lanTestCall(t, engineB, "start", map[string]any{"config": configB})

	generationA, _ := infoA["generation"].(string)
	generationB, _ := infoB["generation"].(string)
	idA, _ := infoA["deviceId"].(string)
	idB, _ := infoB["deviceId"].(string)
	pinA, _ := infoA["pin"].(string)
	pinB, _ := infoB["pin"].(string)
	if generationA == "" || idA == "" || pinA == "" || generationB == "" || idB == "" || pinB == "" {
		t.Fatalf("start 返回不完整：A=%v B=%v", infoA, infoB)
	}
	if !nativeLANID.MatchString(idA) || !nativeLANPin.MatchString(pinA) {
		t.Fatalf("身份格式无效：id=%q pin=%q", idA, pinA)
	}
	addresses, _ := infoA["addresses"].([]any)
	if len(addresses) == 0 {
		t.Skip("本机无私有网段地址，跳过回环链路")
	}
	// 用回环地址连本机 server（nativeLANPrivate 接受 loopback）。
	port := int(infoA["port"].(float64))
	address := fmt.Sprintf("127.0.0.1:%d", port)

	// 模拟 A 的 Dart 事件循环（处理 B 发来的 pair/status）。
	stop := make(chan struct{})
	defer close(stop)
	channelA := &fakePeerChannel{engine: engineA, gen: generationA, config: configA, peerID: idB, peerPin: pinB}
	go channelA.run(stop)

	// B：allow → pair → status。
	grantB := lanTestCall(t, engineB, "allow", map[string]any{
		"generation": generationB, "deviceId": idA, "pin": pinA,
	})
	tokenB, _ := grantB["token"].(string)
	if tokenB == "" {
		t.Fatalf("allow 未返回 token：%v", grantB)
	}
	peerPayload := map[string]any{
		"deviceId": idB, "name": "手机B", "pin": pinB, "kind": "phone",
		"port": 0, "protocol": 1, "addresses": []any{},
	}
	for key, value := range configB {
		peerPayload[key] = value
	}
	peerPayload["returnToken"] = tokenB
	pairRaw, err := json.Marshal(map[string]any{
		"generation": generationB, "deviceId": idA, "pin": pinA, "address": address,
		"path": "pair", "requestId": lanTestAccount(t), "payload": peerPayload,
	})
	if err != nil {
		t.Fatal(err)
	}
	pairValue, pairErr := engineB.nativeLAN(context.Background(), "request", pairRaw)
	if pairErr != nil {
		for _, body := range channelA.eventBodies {
			encoded, _ := json.Marshal(body)
			t.Logf("事件原文：%s", encoded)
		}
		t.Fatalf("pair: %v（调试：polls=%d events=%d respond=%d accepted=%v lastErr=%v）",
			pairErr, channelA.polls, channelA.events, channelA.respond, channelA.accepted, channelA.lastErr)
	}
	pairEncoded, _ := json.Marshal(pairValue)
	var pairResult map[string]any
	_ = json.Unmarshal(pairEncoded, &pairResult)
	remoteToken, _ := pairResult["token"].(string)
	remoteAccount, _ := pairResult["account"].(string)
	if !nativeLANPin.MatchString(remoteToken) {
		t.Fatalf("pair 返回 token 无效：%v", pairResult)
	}
	if !nativeLANID.MatchString(remoteAccount) {
		t.Fatalf("pair 返回 account 无效：%v", pairResult)
	}

	// B 用 A 颁发的 token 调 status。
	statusResult := lanTestCall(t, engineB, "request", map[string]any{
		"generation": generationB, "deviceId": idA, "pin": pinA, "address": address,
		"path": "status", "requestId": lanTestAccount(t), "token": remoteToken,
		"payload": map[string]any{},
	})
	if statusResult["account"] != remoteAccount {
		t.Fatalf("status 返回的 account 与 pair 不一致：%v", statusResult)
	}

	// probe 通道（手动连接第一步）。
	probeResult := lanTestCall(t, engineB, "probe", map[string]any{
		"generation": generationB, "address": address, "requestId": lanTestAccount(t),
	})
	if probeResult["deviceId"] != idA {
		t.Fatalf("probe 返回身份不一致：%v", probeResult)
	}
}
