# Grassfield.Ui public API changelog

`ui/Grassfield/Ui/qmldir` lists the types that the shell and the apps import (`import Grassfield.Ui`). This file is its
changelog. It is append-only and machine-checked by `tests/ci/ui_api.py` (`just check-contracts`).

Rule: a type added to, renamed in or removed from the qmldir gets a line in the block below in the same commit.

- `add <Name> [singleton]`: the type is public. A rename is `remove <Old> -> <New>` plus `add <New>`.
- `remove <Name> [-> <Replacement>]`: the type is gone; the replacement, when there is one, must be public.
- Lines are never edited or deleted, only appended. A removed name is not added again under the same name.

The test fails when the set `add` minus `remove` differs from the qmldir (names and the `singleton` flag), when a
`remove` names a type that was never added, or when a replacement is not public. Why: Segmented became SegmentedControl
without a line and broke Settings' MousePage; a qmldir edit now cannot pass without this file.

```ui-api
add Tokens singleton
add Appearance singleton
add Material
add Icon
add MenuItem
add MenuSeparator
add PopupMenu
add Slider
add Toggle
add Tooltip
add Button
add LinkText
add TextCursor
add JsonSafety
add SwatchRow
add TintedIcon
add IconEffect
add Accent
add IconModes
add FolderStyle
add FolderPlate singleton
add FolderEffect
add FolderIcon
add PointerSize
add PointerColors
add WallpaperConfig
add GrassfieldArtwork
add MenuPlace
add IconShape singleton
add IconTile
add IconShapePrewarm
add AutoAppearance
add NotificationPrefs
add DisplayName
```
