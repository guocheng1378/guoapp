package provider

import (
	"context"
	"testing"
)

func TestCanonicalRecognizesAliasesAndPreservesUnknownInput(t *testing.T) {
	cases := map[string]string{
		"星芽":              SourceYaguo,
		"七猫":              SourceMaoguo,
		"huangguo":        SourceHuangguoAI,
		"huangguoai.com":  SourceHuangguoAI,
		"www.yeguodj.com": SourceYeguo,
		"360":             Source360ZY,
		"cloudfront":      SourceCloudFront,
		"真果·鉴":            SourceDongpiandi,
	}
	for input, want := range cases {
		if got := Canonical(input); got != want {
			t.Fatalf("canonical(%q) = %q, want %q", input, got, want)
		}
	}
	if got := Canonical("UnknownName"); got != "UnknownName" {
		t.Fatalf("unknown source must keep its input, got %q", got)
	}
	if got := Canonical(""); got != "" {
		t.Fatalf("empty source must stay empty, got %q", got)
	}
}

func TestForHostResolvesExactAndSuffixRules(t *testing.T) {
	cases := map[string]string{
		"api-store.qmplaylet.com": SourceMaoguo,
		"u.shytkjgs.com":          SourceYaguo,
		"huangguo.video":          "",
		"door.ediayikma.cc":       SourceHuangguoAI,
		"node.agdkczeyx.cc":       SourceHuangguoAI,
		"line1.buxefaex.cc":       SourceYeguo,
		"mirror.fzchosdi.cc":      SourceYeguo,
		"adviser.awlaxemk.cc":     SourceYeguo,
		"dsf23.vuenadqi.cc":       SourceYeguo,
		"line.ocdjlxow.cc":        SourceYeguo,
		"caiji.moduapi.cc":        SourceModu,
		"dash-agdkczeyx.cc":       "",
		"none.example.com":        "",
	}
	for host, want := range cases {
		if got := ForHost(host); got != want {
			t.Fatalf("ForHost(%q) = %q, want %q", host, got, want)
		}
	}
}

func TestEveryRegisteredSourceOwnsIdentity(t *testing.T) {
	if got := len(All()); got != len(sourceEntries) {
		t.Fatalf("registry holds %d providers, want %d", got, len(sourceEntries))
	}
	seen := map[string]bool{}
	for _, p := range All() {
		spec := p.Spec()
		if spec.ID == "" || seen[spec.ID] {
			t.Fatalf("duplicate or empty source id %q", spec.ID)
		}
		seen[spec.ID] = true
		if Canonical(spec.ID) != spec.ID {
			t.Fatalf("source %q is not canonical", spec.ID)
		}
		if spec.Name == "" || spec.Base == "" {
			t.Fatalf("source %q misses name or base", spec.ID)
		}
		if spec.Category != CategoryShortDrama && spec.Category != CategoryVideo && spec.Category != CategoryAdult {
			t.Fatalf("source %q has no content category", spec.ID)
		}
		if spec.Family != FamilyDuanju && spec.Family != FamilyHuangguo {
			t.Fatalf("source %q has no family", spec.ID)
		}
	}
}

func TestContentCategoriesSplitShortDramaFromVideo(t *testing.T) {
	shortDrama := []string{SourceHongguo, SourceHuangdou, SourceHuangju, SourceHuangguoAI, SourceYeguo,
		SourceYaguo, SourceMaoguo, SourceFanguo, SourceHeguo, SourceXingguo,
		SourceHuaguo, SourceWangguo, SourceFaguo, SourceWuguo}
	video := []string{SourceCloudFront, SourceYingshigongchang, Source360ZY, SourceModu,
		SourceDytt, SourceShandian, SourceHongniu, SourceNiuniuZY, SourceWsyzy, SourceSorani, SourceDongpiandi}
	for _, id := range shortDrama {
		if spec, _ := SpecOf(id); spec.Category != CategoryShortDrama {
			t.Fatalf("%s must be a short drama source, got %q", id, spec.Category)
		}
	}
	for _, id := range video {
		if spec, _ := SpecOf(id); spec.Category != CategoryVideo {
			t.Fatalf("%s must be a video source, got %q", id, spec.Category)
		}
	}
}

func TestFamiliesKeepDuanjuRegistrySeparate(t *testing.T) {
	for _, id := range []string{SourceYaguo, SourceNiuniuZY, SourceSorani, SourceDongpiandi} {
		if !DuanjuSource(id) {
			t.Fatalf("%s must belong to the duanju family", id)
		}
	}
	if DuanjuSource(SourceHongguo) || DuanjuSource(SourceHuangdou) {
		t.Fatal("huangguo family leaked into the duanju registry")
	}
	if DuanjuSource("unknown") {
		t.Fatal("unknown source must not belong to any family")
	}
}

func TestAvailableFollowsBuildVariant(t *testing.T) {
	Configure(Config{AllSources: false})
	if !Available(SourceHongguo) {
		t.Fatal("hongguo must stay available in the default build")
	}
	if Available(SourceHuangdou) || Available(SourceYaguo) {
		t.Fatal("all-sources entries must stay hidden in the default build")
	}
	Configure(Config{AllSources: true})
	if !Available(SourceHuangdou) || !Available(SourceWuguo) || !Available(SourceSorani) {
		t.Fatal("all-sources build must expose every entry")
	}
	if Available("unknown-source") {
		t.Fatal("unregistered source must never be available")
	}
	Configure(Config{AllSources: false})
}

type overrideProvider struct {
	spec Spec
}

func (p overrideProvider) Spec() Spec { return p.spec }

type cataloguerStub struct{}

func (cataloguerStub) Spec() Spec { return Spec{ID: SourceYaguo} }
func (cataloguerStub) Categories(context.Context, Host) ([]CatalogCategory, error) {
	return nil, nil
}
func (cataloguerStub) CatalogPage(context.Context, Host, int, string, string) ([]Drama, bool, error) {
	return nil, false, nil
}

func TestRegisterOverridesAndRestores(t *testing.T) {
	builtin, found := SpecOf(SourceYaguo)
	if !found {
		t.Fatal("builtin yaguo spec is missing")
	}
	Register(overrideProvider{spec: builtin})
	if _, ok := Get(SourceYaguo); !ok {
		t.Fatal("override registration was rejected")
	}
	if _, ok := SpecOf(SourceYaguo); !ok {
		t.Fatal("spec lookup lost the override")
	}
	Register(specProvider{spec: builtin})
	restored, ok := Get(SourceYaguo)
	if !ok {
		t.Fatal("builtin provider was not restored")
	}
	if _, addressed := restored.(Cataloguer); addressed {
		t.Fatal("spec-only provider must not advertise capabilities")
	}
	var _ Cataloguer = cataloguerStub{}
}
