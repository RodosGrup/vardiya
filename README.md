# Vardiya

Açık olan bütün Claude Code oturumlarınızı izometrik bir ofiste, masa başında çalışan karakterler olarak gösteren macOS uygulaması.

- Her proje bir oda; o projedeki her oturum ve alt ajan bir masa.
- Karakterin üstündeki balon o anki işi gösterir: okuyor, yazıyor, komut çalıştırıyor, iş dağıtıyor, onay bekliyor, emir bekliyor, bitti.
- Ana ajandan alt ajanlara kesikli iş aktarım çizgisi çekilir.
- Sağ panelde seçili çalışanın modeli, bağlam boyutu, token sayısı ve son işleri görünür.
- Menü çubuğunda kaç ajanın çalıştığı ve kaçının sizi beklediği yazar.

## 3D ofis

RealityKit ile çizilen gerçek bir 3D sahne (üstteki "3D / Sade" seçimiyle 2D görünüme geçilebilir).

- Kenney'nin CC0 mobilya ve karakter paketleri; her ajan farklı bir karakter.
- Ajanlar yaptıkları işe göre poz alır: yazar, okur, komut çalışırken arkasına yaslanır, düşünürken eli çenesinde, onay beklerken el kaldırır.
- Uzun süre emir bekleyen ajan mola verir: kahve, sebil, kanepe, lavabo (tek kişilik, kapılı, içerisi sansürlü 😄); öğle arasında yemek masasına oturur. İş gelince koşarak masasına döner.
- Art arda 3 hata alan ajan ayağa kalkıp grev yapar.
- Mesajınız kapıdan çıkan ışıklı bir zarfla ajana uçar; yanıtı balonda görünür.
- Gün/gece döngüsü gerçek saate bağlı: gece avizeler yanar, çalışan masaların lambası açılır.
- Fareyle sürükleyerek döndürün, kaydırarak yakınlaştırın, ajana tıklayınca kamera ona gider.
- Detay panelinden seçili oturuma mesaj yazabilirsiniz; mesaj iTerm2 / Terminal sekmesine sizin yazmışsınız gibi gider (ilk kullanımda macOS otomasyon izni ister).

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

3D varlıkları yeniden üretmek için: `python3 scripts/build_assets.py`. Kenney paketlerini indirir, mobilyaları USDZ'ye çevirir, karakterleri eklem parçalarına ayırır ve animasyonları `animations.json`'a çıkarır. Yeni model eklediyseniz ardından `xcodegen generate` çalıştırın.

Debug derlemesinde test parametreleri:

- `-vardiyaHour 22.5`: ofis saatini değiştirir (gece, öğle arası).
- `-vardiyaFastBreaks YES`: molalar birkaç saniye içinde başlar.
- `-vardiyaSpot toilet|water|sofa|coffee|lunch`: mola yerini zorlar.
- `-vardiyaFocus 3`: kamerayı 3. ajana odaklar.

## Lisans

© 2026 Batuhan Haymana

3D modeller: [Kenney](https://kenney.nl) Mini Characters ve Furniture Kit, CC0 (`Vardiya/Resources/Models/LICENSE-kenney.txt`).
