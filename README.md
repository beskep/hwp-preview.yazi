# hwp-preview.yazi

한컴오피스 한글 yazi 프리뷰.

hwp/hwpx 파일 내 저장된 PrvImage, PrvText를 불러오며, 첫 페이지만 볼 수 있습니다.
PATH에 `7z`이 등록되어 있어야 사용 가능합니다.

## Installation

```sh
ya pkg add beskep/hwp-preview
```

## Usage

### yazi.toml 설정 예시

```toml
[[plugin.prepend_preloaders]]
name = "*.{hwp,hwpx}"
run = "hwp-preview"

[[plugin.prepend_previewers]]
name = "*.{hwp,hwpx}"
run = "hwp-preview"
```

### init.lua 설정 (optional)

```lua
require('hwp-preview'):setup({
    -- 프리뷰 영역 이미지, 글 배치
    orientation = 'horizontal',
    -- 프리뷰 영역 이미지가 차지하는 최대 비율
    max_image_ratio = 0.75,
    -- 텍스트 줄바꿈 여부
    text_wrap = true,
})
```
