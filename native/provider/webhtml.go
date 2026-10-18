package provider

import (
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

var reEpisodeNumber = regexp.MustCompile(`(?i)(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))`)

// HTMLAttr 读取节点的指定属性值。
func HTMLAttr(node *html.Node, name string) string {
	if node != nil {
		for _, attribute := range node.Attr {
			if attribute.Key == name {
				return attribute.Val
			}
		}
	}
	return ""
}

// HTMLClass 判断节点是否带有指定 class。
func HTMLClass(node *html.Node, name string) bool {
	for _, value := range strings.Fields(HTMLAttr(node, "class")) {
		if value == name {
			return true
		}
	}
	return false
}

// HTMLNodes 深度优先收集满足条件的节点（后进先出遍历顺序与解析器约定一致）。
func HTMLNodes(root *html.Node, match func(*html.Node) bool) []*html.Node {
	var found []*html.Node
	if root == nil {
		return found
	}
	pending := []*html.Node{root}
	for len(pending) > 0 {
		node := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if match(node) {
			found = append(found, node)
		}
		for child := node.LastChild; child != nil; child = child.PrevSibling {
			pending = append(pending, child)
		}
	}
	return found
}

// HTMLFirstClass 依次查找第一个匹配任一 class 的节点。
func HTMLFirstClass(root *html.Node, names ...string) *html.Node {
	for _, name := range names {
		matches := HTMLNodes(root, func(node *html.Node) bool {
			return HTMLClass(node, name)
		})
		if len(matches) > 0 {
			return matches[0]
		}
	}
	return nil
}

// HTMLText 拼接节点内的可见文本（跳过 script/style）。
func HTMLText(root *html.Node) string {
	var text strings.Builder
	for _, node := range HTMLNodes(root, func(node *html.Node) bool {
		return node.Type == html.TextNode
	}) {
		if node.Parent != nil && (node.Parent.Data == "script" || node.Parent.Data == "style") {
			continue
		}
		text.WriteString(node.Data)
		text.WriteByte(' ')
	}
	return strings.Join(strings.Fields(text.String()), " ")
}

// Absolute 把页面里的相对链接补全为绝对地址。
func Absolute(base, reference string) string {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return ""
	}
	if strings.HasPrefix(reference, "//") {
		return "https:" + reference
	}
	address, err := url.Parse(reference)
	if err != nil {
		return ""
	}
	if address.IsAbs() {
		return address.String()
	}
	origin, err := url.Parse(strings.TrimRight(base, "/") + "/")
	if err != nil {
		return ""
	}
	return origin.ResolveReference(address).String()
}

// EpisodeNumber 从标题或序号文本里解析分集序数，解析不出时回退 fallback。
func EpisodeNumber(raw string, fallback int) int {
	raw = strings.TrimSpace(raw)
	if number := episodeIndex(raw, 0); number > 0 {
		return number
	}
	if number, err := strconv.Atoi(raw); err == nil && number > 0 {
		return number
	}
	if fallback > 0 {
		return fallback
	}
	return 1
}

func episodeIndex(text string, fallback int) int {
	if m := reEpisodeNumber.FindStringSubmatch(text); len(m) > 1 {
		for _, group := range m[1:] {
			if group == "" {
				continue
			}
			if n, err := strconv.Atoi(group); err == nil && n > 0 {
				return n
			}
		}
	}
	return fallback
}
