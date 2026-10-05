# Vardiya

Açık olan bütün Claude Code oturumlarınızı izometrik bir ofiste, masa başında çalışan karakterler olarak gösteren macOS uygulaması.

- Her proje bir oda; o projedeki her oturum ve alt ajan bir masa.
- Karakterin üstündeki balon o anki işi gösterir: okuyor, yazıyor, komut çalıştırıyor, iş dağıtıyor, onay bekliyor, emir bekliyor, bitti.
- Ana ajandan alt ajanlara kesikli iş aktarım çizgisi çekilir.
- Sağ panelde seçili çalışanın modeli, bağlam boyutu, token sayısı ve son işleri görünür.
- Menü çubuğunda kaç ajanın çalıştığı ve kaçının sizi beklediği yazar.

## Veri nereden geliyor

Claude Code'un ayarlarına dokunulmaz, hook kurulmaz. Uygulama yalnızca okur:

- `~/.claude/sessions/<pid>.json`: canlı oturum kaydı (çalışıyor/boşta)
- `~/.claude/projects/<proje>/<oturum>.jsonl`: oturum dökümü (araç çağrıları, token kullanımı, başlık)
- `~/.claude/projects/<proje>/<oturum>/subagents/`: alt ajan dökümleri

Dökümler artımlı okunur; her saniye yalnızca yeni satırlar işlenir.

## Derleme

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Vardiya.xcodeproj -scheme Vardiya -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Vardiya.app
```

İkonu yeniden üretmek için: `python3 scripts/make_icon.py` (Pillow gerekir).

## Lisans

© 2026 Batuhan Haymana
