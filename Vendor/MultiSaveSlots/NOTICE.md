# Vendored: Multi Save Slots

`Main.gd` 와 `SlotPanel.gd` 는 외부 모드 **"Multi Save Slots"** (id `multi-save-slots`,
modworkshop 56248) 에서 **수정 없이 그대로** 가져온 벤더본입니다. 원작자 저작권은
원작자에게 있으며, 이 코옵 모드는 친구 배포 편의를 위해 슬롯 세이브 기능을 자체 포함
(흡수)하기 위해 동봉합니다.

## 동작
- 게임에 standalone **Multi Save Slots** 모드(`/root/MultiSaveSlotsMain` autoload)가
  이미 있으면 → **그쪽에 양보**(이 벤더본은 인스턴스화하지 않음). 이중 실행 방지.
- 없으면 → `RTVCoop/Main.gd` 가 이 `Main.gd` 를 `/root/MultiSaveSlotsMain` 이라는
  같은 이름으로 인스턴스화 → 코옵 슬롯 세이브가 standalone 없이도 작동.
- 슬롯 데이터 위치(`user://MultiSaveSlots/slotN/`)는 standalone 과 동일 → 기존 슬롯 호환.

## 업데이트 방법
원본 mod 가 갱신되면 `Main.gd` / `SlotPanel.gd` 를 이 폴더에 다시 복사하면 됩니다
(수정본이 아니라 verbatim 이라 그대로 덮어쓰기 가능).
원본 경로(현재): `Downloads/_MultiSaveSlots/mods/MultiSaveSlots/`
