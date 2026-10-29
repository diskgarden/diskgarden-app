# Localization

DiskGarden ships in 18 languages: English (source), Spanish, Chinese (Simplified), Chinese (Traditional),
French, German, Italian, Japanese, Korean, Polish, Portuguese (Brazil), Portuguese (Portugal), Arabic,
Russian, Turkish, Vietnamese, Swedish and Ukrainian.

## Where things live
- `App/Localizable.xcstrings`: all UI text, with plural variants (`%lld …` keys) per CLDR category.
- `App/InfoPlist.xcstrings`: the Finder (Apple Events) permission text. The app name is not translated.
- `App/Localization.swift`: formatting that isn't a plain string: size units and decimal separator (installed into
  `ByteSize` at launch), locale-aware percentages (`74 %`, `%74`), and volume descriptions ("encrypted startup disk").

## Adding or changing text
- SwiftUI literals (`Text("…")`, `Button("…")`, `Toggle`, `Label`, `.help`) are extracted automatically. Anything built
  as a Swift `String` (menu items, alerts, notices, model-provided labels) must use `String(localized:comment:)`.
- Write whole sentences with placeholders (`Text("You've freed up \(sizeText).")`), never `Text + Text` fragments of a
  sentence, and never pick a `String` with a ternary inside `Text(...)` (that bypasses localization).
- Brand names and numbers: `Text(verbatim:)`.
- New keys show up in the catalog after building in Xcode or running
  `xcodebuild -exportLocalizations -project DiskGarden.xcodeproj -localizationPath /tmp/loc -exportLanguage en`.
  Then add translations for every language (plural keys need every CLDR category of the language).

## Terminology (keep consistent)
The Waste bin is deliberately a different word from the macOS Trash in every language:

| Language | Waste bin | macOS Trash |
|---|---|---|
| es | Compostera | Papelera |
| pt-BR | Caçamba | Lixo |
| pt-PT | Compostor | Lixo |
| fr | Bac à déchets | Corbeille |
| it | Bidone | Cestino |
| de | Abfalleimer | Papierkorb |
| sv | Komposten | Papperskorgen |
| pl | Kompostownik | Kosz |
| tr | Kompost Kutusu | Çöp Sepeti |
| ru | Мусорный бак | Корзина |
| uk | Смітник | Кошик |
| ar | حاوية النفايات | سلة المهملات |
| zh-Hans | 清理篮 | 废纸篓 |
| zh-Hant | 清理籃 | 垃圾桶 |
| ja | 処分かご | ゴミ箱 |
| ko | 폐기함 | 휴지통 |
| vi | Giỏ chờ xóa | Thùng rác |

## Right-to-left (Arabic)
The content view gets its layout direction from the app's localization (see `MainWindow`). The sunburst is a
picture and always lays out left to right (only its labels follow the text direction), sizes render as one
left-to-right token ("385.5 غ.بايت"), and the brand sits opposite the window buttons.
