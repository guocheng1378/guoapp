package provider

import "testing"

func TestSanitizeTextDecodesEntitiesAndStripsTags(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"&nbsp;, &nbsp;地点——Seabrook社区&nbsp;僵尸（zombie）&amp;续作", ", 地点——Seabrook社区 僵尸（zombie）&续作"},
		{"<p>简介</p>", "简介"},
		{"&lt;b&gt;加粗&lt;/b&gt; 文本", "<b>加粗</b> 文本"},
		{"串&nbsp;&nbsp;多空格", "串 多空格"},
		{"  前后空格  ", "前后空格"},
		{"干净文本", "干净文本"},
		{"", ""},
		// 实体解出来后不应再出现字面量
		{"&#39;s &quot;引用&quot;", "'s \"引用\""},
	}
	for _, c := range cases {
		if got := SanitizeText(c.in); got != c.want {
			t.Fatalf("SanitizeText(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
