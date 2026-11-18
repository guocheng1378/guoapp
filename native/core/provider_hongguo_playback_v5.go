package core

// 红果播放 V5 签名（2026-11-17 从上游 Xanerix/guoapp 2.0.1+113 内嵌的
// bundled/hongguo 模块逐行移植；源注释标注 Derived from N3urda/hongguoTV
// Signer/AesV3/V5Constants and drpys 22261ad, GPL-3.0-only）。
//
// 背景：红果取流接口已从 /novel/player/video_model/v1/ 换成
// /novel/player/multi_video_model/player/v1，且播放请求改用 V5 签名
// （X-Khronos + X-Helios + X-Medusa），旧的 X-Gorgon/X-Argus/X-Ladon
// 组合会被网关判无效并回空包（「红果 App 接口未返回有效数据」）。

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/bits"
	"strconv"
	"strings"
)

const hongguoPlaybackV5MagicHex = "2d4b4fca49750d433fb5ae2c226dcc56"
const hongguoPlaybackV5SignKeyHex = "b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d"

// 1024 字节，按 variant(ts&3) 切成 4 个 256 字节 S 盒。
const hongguoPlaybackV5SboxHex = "" +
	"53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d" +
	"f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a" +
	"80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d" +
	"d12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912" +
	"38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65" +
	"b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe" +
	"1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8" +
	"94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc" +
	"d759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d" +
	"e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e" +
	"47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28" +
	"8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5" +
	"d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9" +
	"1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f" +
	"d830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168" +
	"1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e"

var hongguoPlaybackV5HashTable = [64]uint32{
	0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
	0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
	0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
	0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
	0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
	0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
	0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
	0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
}

func hongguoV5Magic() []byte {
	data, _ := hex.DecodeString(hongguoPlaybackV5MagicHex)
	return data
}

func hongguoV5SignKey() []byte {
	data, _ := hex.DecodeString(hongguoPlaybackV5SignKeyHex)
	return data
}

func hongguoV5Sbox() []byte {
	data, _ := hex.DecodeString(hongguoPlaybackV5SboxHex)
	return data
}

func hongguoV5Le32(value uint32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, value)
	return out
}

// hongguoV5IV 复刻 playbackV5IV：奇偶混洗的 32 位折叠，用来挑选 _rticket。
func hongguoV5IV(queryHash, bodyMd5 []byte, ts uint32) uint32 {
	value := uint32(0x20230928)
	for _, data := range [][]byte{queryHash, bodyMd5, hongguoV5Le32(ts)} {
		for index := 0; index < len(data); index++ {
			if index&1 == 0 {
				value = (value >> 4) ^ value ^ (value << 6) ^ uint32(data[index])
			} else {
				value = ^((value >> 7) ^ value ^ (uint32(data[index]) | (value << 12)))
			}
		}
	}
	return value
}

// hongguoV5Hash 复刻 playbackV5Hash（自定义 96 轮类 SHA256，输出 20 字节）。
func hongguoV5Hash(queryHash, bodyMd5 []byte, ts uint32) ([]byte, error) {
	if len(queryHash) != 32 || len(bodyMd5) != 16 {
		return nil, errors.New("V5 hash requires a 32-byte query hash and a 16-byte body hash")
	}
	if hongguoV5IV(queryHash, bodyMd5, ts)&15 != 12 {
		return nil, errors.New("Unsupported V5 hash branch")
	}
	const iv uint32 = 0x9d4a97c2
	count := int32(iv + ts)
	table := make([]uint32, len(hongguoPlaybackV5HashTable))
	rotate := uint((count + 1) & 255)
	for index, value := range hongguoPlaybackV5HashTable {
		table[index] = bits.RotateLeft32(value, -int(rotate))
	}
	shift := uint((count + 2) & 7)
	padding := make([]byte, 4)
	for index, value := range []uint32{0xfa, 0x45, 0x61, 0xd7} {
		padding[index] = byte(((value | (value << 8)) >> shift) & 0xff)
	}
	data := append([]byte{}, queryHash...)
	data = append(data, bodyMd5...)
	data = append(data, hongguoV5Le32(ts)...)
	data = append(data, padding...)
	data = append(data, 0, 0, 0, 0, 0, 0, 1, 0xa0)
	words := make([]uint32, 0, len(data)/4+112)
	for index := 0; index+3 < len(data); index += 4 {
		words = append(words, uint32(data[index])<<24|uint32(data[index+1])<<16|uint32(data[index+2])<<8|uint32(data[index+3]))
	}
	for index := 0; index < 112; index++ {
		x := words[index+1]
		y := words[index+14]
		sum := words[index] + words[index+9] +
			(bits.RotateLeft32(x, 14) ^ bits.RotateLeft32(x, 25) ^ (x >> 3)) +
			(bits.RotateLeft32(y, 13) ^ bits.RotateLeft32(y, 15) ^ (y >> 10))
		words = append(words, sum)
	}
	initial := make([]uint32, 8)
	for index, value := range []uint32{0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264} {
		initial[index] = bits.RotateLeft32(value, -int(count))
	}
	state := append([]uint32{}, initial...)
	for index := 0; index < 96; index++ {
		base := int32(iv+uint32(index)) & 127
		choose := ((state[4] ^ state[0]) & state[1]) ^ state[4]
		sigma1 := bits.RotateLeft32(state[1], 26) ^ bits.RotateLeft32(state[1], 21) ^ bits.RotateLeft32(state[1], 7)
		mixed := words[base] + choose + sigma1 + table[int32(iv+uint32(index))&63] + state[6]
		sigma0 := bits.RotateLeft32(state[3], 30) ^ bits.RotateLeft32(state[3], 19) ^ bits.RotateLeft32(state[3], 10)
		majority := (state[3] & state[5]) | ((state[3] | state[5]) & state[2])
		old := state[7]
		copy(state[1:], state[:7])
		state[0] = old
		state[7] = sigma0 + majority + mixed
		state[0] = old + mixed
	}
	digest := make([]byte, 32)
	for index := 0; index < 8; index++ {
		binary.BigEndian.PutUint32(digest[index*4:], state[index]+initial[index])
	}
	folded := make([]byte, 16)
	for index := 0; index < 16; index++ {
		folded[index] = digest[index] ^ digest[index+16]
	}
	check := uint32(0x20220420)
	for index := 0; index < 12; index++ {
		even := index&1 == 0
		var temp uint32
		if even {
			temp = (check >> 3) ^ check
		} else {
			temp = (check >> 5) ^ check
		}
		if even {
			check = (uint32(folded[index]) ^ (check << 7)) ^ temp
		} else {
			check = ^(uint32(folded[index]) | (check << 11)) ^ temp
		}
	}
	final := (check | 4) ^ 0x1000000
	final |= 0x20
	return append(folded, hongguoV5Le32(final)...), nil
}

func hongguoV5Xt(value byte) byte {
	if value&128 != 0 {
		return (value << 1) ^ 0x1b
	}
	return value << 1
}

// hongguoV5Carrier 复刻 playbackV5Carrier：带 S 盒/行置换/列混淆变体的块加密。
func hongguoV5Carrier(key, iv, source []byte, ts uint32) ([]byte, error) {
	if len(key) != 16 || len(iv) != 16 || len(source) < 248 {
		return nil, errors.New("V5 carrier requires 16-byte key/IV and at least 248 source bytes")
	}
	sbox := hongguoV5Sbox()
	variant := int(ts & 3)
	box := sbox[variant*256 : (variant+1)*256]
	rowsOrder := [4][4]int{{2, 0, 3, 1}, {1, 3, 2, 0}, {3, 2, 1, 0}, {2, 3, 1, 0}}[variant]
	orders := [4][16]int{
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7},
		{0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7},
		{0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7},
	}
	order := orders[variant]
	initial := [4]uint32{0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9}[variant]
	initialBytes := hongguoV5Le32(initial)
	expanded := make([]byte, 48)
	for index := 0; index < 16; index++ {
		expanded[index] = initialBytes[index&3] ^ key[index]
	}
	rounds := uint(8)
	for index := 4; index < 12; index++ {
		at := 4 * (index - 1)
		a, b, c, d := expanded[at], expanded[at+1], expanded[at+2], expanded[at+3]
		if index&3 == 0 {
			next := byte((initial>>(rounds&24))^uint32(box[b])) & 255
			b = box[c]
			c = box[d]
			d = box[a]
			a = next
		}
		rounds += 2
		expanded[at+4] = a ^ expanded[at-12]
		expanded[at+5] = b ^ expanded[at-11]
		expanded[at+6] = c ^ expanded[at-10]
		expanded[at+7] = d ^ expanded[at-9]
	}
	block := func(value []byte) []byte {
		rows := make([][]byte, 4)
		for index := 0; index < 4; index++ {
			rows[index] = append([]byte{}, value[index*4:index*4+4]...)
		}
		addCon := func(offset int) {
			for i := 0; i < 4; i++ {
				for j := 0; j < 4; j++ {
					rows[i][j] ^= expanded[(offset+i)*4+rowsOrder[j]]
				}
			}
		}
		addCon(0)
		for round := 1; round <= 2; round++ {
			for i := 0; i < 4; i++ {
				for j := 0; j < 4; j++ {
					rows[i][j] = box[rows[i][j]]
				}
			}
			before := make([][]byte, 4)
			for index := 0; index < 4; index++ {
				before[index] = append([]byte{}, rows[index]...)
			}
			reordered := make([][]byte, 4)
			for index := 0; index < 4; index++ {
				reordered[index] = before[rowsOrder[index]]
			}
			rows = reordered
			flat := make([]byte, 0, 16)
			for _, row := range rows {
				flat = append(flat, row...)
			}
			for index := 0; index < 16; index++ {
				rows[index/4][index%4] = flat[order[index]]
			}
			if round == 1 {
				mixedRows := make([][]byte, 4)
				for index := 0; index < 4; index++ {
					row := make([]byte, 4)
					for j := 0; j < 4; j++ {
						row[j] = rows[j][rowsOrder[index]]
					}
					mixedRows[index] = row
				}
				rows = mixedRows
				for index := 0; index < 4; index++ {
					mixed := rows[0][index] ^ rows[1][index] ^ rows[2][index] ^ rows[3][index]
					first := rows[0][index]
					rows[0][index] ^= mixed ^ hongguoV5Xt(rows[0][index]^rows[1][index])
					rows[1][index] ^= mixed ^ hongguoV5Xt(rows[1][index]^rows[2][index])
					rows[2][index] ^= mixed ^ hongguoV5Xt(rows[2][index]^rows[3][index])
					rows[3][index] ^= mixed ^ hongguoV5Xt(rows[3][index]^first)
				}
			}
			addCon(round * 4)
		}
		for i := 0; i < 4; i++ {
			for j := 0; j < 4; j++ {
				rows[i][j] ^= expanded[(4+i)*4+j]
			}
		}
		out := make([]byte, 0, 16)
		for _, row := range rows {
			out = append(out, row...)
		}
		return out
	}
	wire := [8]int{6, 5, 3, 4, 2, 7, 1, 0}
	compact := [8]int{1, 7, 3, 6, 2, 0, 4, 5}
	plaintext := make([]byte, 32)
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			plaintext[i] |= ((source[i*8+j] >> wire[j]) & 1) << compact[j]
		}
	}
	plaintext[31] = 1
	input := make([]byte, 16)
	for index := 0; index < 16; index++ {
		input[index] = plaintext[index] ^ iv[index]
	}
	first := block(input)
	for index := 0; index < 16; index++ {
		input[index] = plaintext[index+16] ^ first[index]
	}
	keyOut := append(first, block(input)...)
	out := make([]byte, 0, len(source)+1)
	out = append(out, keyOut[31])
	out = append(out, source...)
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			at := 1 + i*8 + j
			bit := (keyOut[i] >> compact[j]) & 1
			out[at] = (out[at] &^ (1 << wire[j])) | (bit << wire[j])
		}
	}
	return out, nil
}

// hongguoV5Proto 复刻 playbackV5Proto：最小 protobuf 编码器。
func hongguoV5Proto(fields [][2]any) []byte {
	out := make([]byte, 0, 256)
	for _, field := range fields {
		tag, _ := field[0].(int)
		switch value := field[1].(type) {
		case int:
			encoded := uint64(value) * 2
			if value < 0 {
				encoded = uint64(-value*2 - 1)
			}
			out = binary.AppendUvarint(out, uint64(tag*8))
			out = binary.AppendUvarint(out, encoded)
		case string:
			bytesValue := []byte(value)
			if len(bytesValue) != 0 {
				out = binary.AppendUvarint(out, uint64(tag*8+2))
				out = binary.AppendUvarint(out, uint64(len(bytesValue)))
				out = append(out, bytesValue...)
			}
		case []byte:
			if len(value) != 0 {
				out = binary.AppendUvarint(out, uint64(tag*8+2))
				out = binary.AppendUvarint(out, uint64(len(value)))
				out = append(out, value...)
			}
		}
	}
	return out
}

// hongguoV5Xmxor 复刻 playbackV5Xmxor：字节级混洗加密。
func hongguoV5Xmxor(data, key []byte) []byte {
	encoded := make([]byte, len(data))
	for index := 0; index < len(data); index++ {
		at := (index * 4) & 28
		d0, d1 := key[at], key[at+1]
		mixed := byte((bits.RotateLeft8(data[index], 4) + d0) & 255)
		mixed = ^mixed ^ d1
		mixed = bits.RotateLeft8(mixed, 3)
		mixed = (mixed + d1) & 255
		mixed ^= d0
		encoded[len(data)-index-1] = ^mixed
	}
	lastIndex := len(encoded) - 1
	last := encoded[lastIndex] ^ encoded[lastIndex-1]
	first := encoded[0]
	encoded[0] = (^last + first) & 255
	encoded[1] = ((encoded[0] ^ encoded[lastIndex] ^ 254) + encoded[1]) & 255
	encoded[2] = (encoded[2] + ((last - first) ^ bits.RotateLeft8(encoded[1], 3) ^ 2)) & 255
	for index := 0; index < len(encoded)-4; index++ {
		mixed := bits.RotateLeft8(encoded[index+2], 3) ^ encoded[index+1] ^ byte(index+3)
		encoded[index+3] = (^mixed + encoded[index+3]) & 255
	}
	encoded[lastIndex] ^= encoded[lastIndex-1]
	sum := 0
	for index := 1; index < len(encoded); index++ {
		sum += int(encoded[index])
	}
	encoded[0] = ((encoded[0] ^ encoded[1]) + byte(sum)) & 255
	return encoded
}

func hongguoV5RandomBytes(count int) []byte {
	buf := make([]byte, count)
	_, _ = hongguoCryptoRandRead(buf)
	return buf
}

func hongguoV5Base64URL(data []byte) string {
	encoded := base64.StdEncoding.EncodeToString(data)
	encoded = strings.ReplaceAll(encoded, "+", "-")
	encoded = strings.ReplaceAll(encoded, "/", "_")
	return strings.TrimRight(encoded, "=")
}

// hongguoV5Helios 复刻 playbackV5Helios（license 646637794 的 Ladon 变体）。
func hongguoV5Helios(ts uint32) string {
	prefix := hongguoV5RandomBytes(4)
	ascii := []byte(hex.EncodeToString(md5Sum(append(append([]byte{}, prefix...), []byte("8662")...))))
	left := binary.LittleEndian.Uint64(ascii)
	right := binary.LittleEndian.Uint64(ascii[8:])
	queue := []uint64{binary.LittleEndian.Uint64(ascii[16:]), binary.LittleEndian.Uint64(ascii[24:])}
	var keys [34]uint64
	for index := 0; index < 34; index++ {
		keys[index] = left
		mixed := (bits.RotateLeft64(right, -8) + left) ^ uint64(index)
		queue = append(queue, mixed)
		left = mixed ^ bits.RotateLeft64(left, 3)
		right = queue[0]
		queue = queue[1:]
	}
	data := hongguoCommentPad([]byte(strconv.FormatUint(uint64(ts), 10) + "-646637794-8662"))
	for offset := 0; offset < len(data); offset += 16 {
		a := binary.LittleEndian.Uint64(data[offset:])
		b := binary.LittleEndian.Uint64(data[offset+8:])
		for _, key := range keys {
			b = key ^ (a + bits.RotateLeft64(b, -8))
			a = b ^ bits.RotateLeft64(a, 3)
		}
		binary.LittleEndian.PutUint64(data[offset:], a)
		binary.LittleEndian.PutUint64(data[offset+8:], b)
	}
	return base64.StdEncoding.EncodeToString(append(append([]byte{}, prefix...), data...))
}
